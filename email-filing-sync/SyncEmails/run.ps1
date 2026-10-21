# Timer trigger, every 5 minutes. Unattended -- there is no signed-in user, so every
# Graph call uses one app-only token and addresses mailboxes via /users/{upn}/... rather
# than /me/.... See email-filing-sync/README.md for the full design; this file is the
# orchestration, Modules/EmailFilingSync holds the reusable pieces.
#
# Per email: resolve its project from an Outlook category -> find that project's
# SharePoint folder -> get-or-create its "Emails" child folder -> skip if a duplicate
# (folder-name + Message-ID-hash check, since the index is usually unreachable from here
# -- see Invoke-IndexApi) -> otherwise fetch the raw .eml via Graph, stamp it with an
# X-Summation-Labels header, upload it, best-effort notify the index -> tag the original
# (Filed + bare project code) and move it into "Filed". SharePoint is the step that must
# succeed; an index-notify failure never blocks a save, per the index brief's own
# "never fail a save because the index is unreachable" requirement.

param($Timer)

Import-Module "$PSScriptRoot/../Modules/EmailFilingSync/EmailFilingSync.psm1" -Force

# A proactive size-based circuit breaker for the OutOfMemoryException incident (107 distinct real
# emails stuck retrying forever, confirmed via Application Insights, accumulating since
# 2026-10-07) was attempted here 2026-10-21 and reverted the same day: it depended on Graph's
# message `size` property, which this tenant's Graph resolver doesn't expose at all -- confirmed
# live, `$select=...,size` fails with "Could not find a property named 'size' on type
# 'Microsoft.OutlookServices.Message'" on EVERY message query in this tenant, not just the
# folder-scoped ones tried first. A HEAD request against /messages/{id}/$value (hoping for a
# Content-Length without downloading the body) also isn't supported (405). Switching to
# Invoke-WebRequest below avoids Invoke-RestMethod's own JSON/XML-oriented content-type sniffing
# (the direct cause of the 2026-10-08 corruption incident), but still needs the same explicit
# byte[]-vs-string branch the original code had -- confirmed live the same day that
# Invoke-WebRequest's .Content isn't reliably byte[] either on this runtime. A proper circuit
# breaker that doesn't depend on a property this tenant doesn't have (e.g. a retry-count tracked
# via categories, or summing attachment sizes some other way) is a deliberate follow-up, not yet
# built.

Write-Host "EmailFilingSync: run started $(Get-Date -Format o)"

try {
    $token = Get-GraphAppToken
    $staff = Get-StaffMailboxes -Token $token
    Write-Host "EmailFilingSync: $($staff.Count) staff mailboxes to check"

    $folderEntries = Get-ProjectFolderEntries -Token $token
    Write-Host "EmailFilingSync: $($folderEntries.Count) project folders loaded from SharePoint"
} catch {
    Write-Error "EmailFilingSync: could not complete run setup (token/staff list/folder list) -- aborting this run: $($_.Exception.Message)"
    return
}

$totals = [ordered]@{
    mailboxesChecked       = 0
    filed                  = 0
    alreadyFiled           = 0
    skippedNoCategory      = 0
    skippedNoProjectFolder = 0
    failed                 = 0
    notifyFailed           = 0
    sentFiled                  = 0
    sentAlreadyFiled           = 0
    sentSkippedNoProjectFolder = 0
    sentFailed                 = 0
    sentNotifyFailed            = 0
}

foreach ($user in $staff) {
    $totals.mailboxesChecked++
    $upn = $user.Mail

    # ---- Sent Items pass (File on Send) ----
    # Independent of the "Emails to File" staging pass below -- runs for every staff
    # mailbox every time, regardless of whether that mailbox has anything staged. A sent
    # reply/new email gets categorized (never staged/moved) by the taskpane's File on Send
    # dialog before it's sent, via Office.js categories.addAsync -- there's no "stage it
    # first" step possible for an outgoing message the way there is for Inbox mail. This
    # looks for recently-sent messages carrying a project category that aren't yet tagged
    # "Filed", and files them the same way as the pass below, but leaves them in place in
    # Sent Items rather than moving them -- nobody wants their own Sent folder emptied out
    # by automation the way Inbox staging is.
    try {
        $sentCutoff = (Get-Date).ToUniversalTime().AddHours(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $sentMessages = Get-GraphAllPages -Token $token -Uri (
            "https://graph.microsoft.com/v1.0/users/$upn/mailFolders/sentitems/messages" +
            "?`$filter=$([uri]::EscapeDataString("sentDateTime ge $sentCutoff"))" +
            "&`$select=id,subject,categories,internetMessageId,from,toRecipients,ccRecipients,sentDateTime,conversationId,hasAttachments" +
            "&`$top=50"
        )
        $sentMessages = @($sentMessages | Where-Object {
            (Resolve-FilingCategory -Categories @($_.categories)) -and (@($_.categories) -notcontains "Filed")
        })

        if ($sentMessages.Count -gt 0) {
            Write-Host "EmailFilingSync: '$upn' has $($sentMessages.Count) sent email(s) to file"
        }

        foreach ($msg in $sentMessages) {
            $label = "'$upn' (sent) / $($msg.subject)"
            try {
                $categoryName = Resolve-FilingCategory -Categories @($msg.categories)
                $folderEntry = Resolve-ProjectFolder -CategoryName $categoryName -FolderEntries $folderEntries
                if (-not $folderEntry) {
                    Write-Host "EmailFilingSync: SKIP (no matching project folder for '$categoryName') $label"
                    $totals.sentSkippedNoProjectFolder++
                    continue
                }
                $projectCode = Get-ProjectCode -Text $folderEntry.Name
                $projectPath = "$($folderEntry.BranchPath)/$($folderEntry.Name)"
                $emailsFolderId = Get-OrCreateChildFolder -DriveId $folderEntry.DriveId -ParentPath $projectPath -ChildName "Emails" -Token $token

                $sentUtc = [DateTime]::Parse($msg.sentDateTime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $fromName = if ($msg.from.emailAddress.name) { $msg.from.emailAddress.name } else { $msg.from.emailAddress.address }
                $baseName = New-EmailFileName -SentLocal $sentUtc -FromName $fromName -Subject $msg.subject

                $existingBase = Invoke-GraphGetOrNull -Token $token -Uri (
                    "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/root:/" +
                    "$([uri]::EscapeDataString("$projectPath/Emails/$baseName") -replace '%2F','/')"
                )
                $finalName = $baseName
                $isDuplicate = $false
                if ($existingBase) {
                    $hashSuffix = Get-MessageIdHashPrefix -MessageId $msg.internetMessageId
                    $hashedName = New-EmailFileName -SentLocal $sentUtc -FromName $fromName -Subject $msg.subject -CollisionHashSuffix $hashSuffix
                    $existingHashed = Invoke-GraphGetOrNull -Token $token -Uri (
                        "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/root:/" +
                        "$([uri]::EscapeDataString("$projectPath/Emails/$hashedName") -replace '%2F','/')"
                    )
                    $finalName = $hashedName
                    $isDuplicate = [bool]$existingHashed
                }

                $labelsAsFound = @($msg.categories)

                if (-not $isDuplicate) {
                    # Invoke-WebRequest instead of Invoke-RestMethod, added 2026-10-21 -- see the
                    # main pass below for the full story and the correction to this comment's
                    # original (wrong) claim that .Content is always byte[] here.
                    $rawContent = (Invoke-WebRequest -Method Get `
                        -Uri "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)/`$value" `
                        -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop).Content
                    $originalBytes = if ($rawContent -is [byte[]]) { $rawContent } else { [System.Text.Encoding]::GetEncoding(28591).GetBytes([string]$rawContent) }
                    $stampedBytes = Add-SummationLabelsHeader -MimeBytes $originalBytes -Labels $labelsAsFound

                    if ($stampedBytes.Length -gt 4MB) {
                        Send-GraphLargeFile -DriveId $folderEntry.DriveId -ParentId $emailsFolderId -FileName $finalName -Bytes $stampedBytes -Token $token | Out-Null
                    } else {
                        Invoke-RestMethod -Method Put `
                            -Uri "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/items/$($emailsFolderId):/$([uri]::EscapeDataString($finalName)):/content" `
                            -Headers @{ Authorization = "Bearer $token" } -ContentType "message/rfc822" -Body $stampedBytes -ErrorAction Stop | Out-Null
                    }

                    $library = if ($folderEntry.Source -eq "Active") { "Summation Hub - Active Projects" } else { "Summation Hub - Archieve Projects" }
                    $notifyBody = @{
                        messageId      = $msg.internetMessageId
                        projectCode    = $projectCode
                        library        = $library
                        relativePath   = "$projectPath/Emails/$finalName"
                        fileName       = $finalName
                        labels         = $labelsAsFound
                        subject        = $msg.subject
                        fromName       = $fromName
                        fromEmail      = $msg.from.emailAddress.address
                        to             = @($msg.toRecipients | ForEach-Object { @{ name = $_.emailAddress.name; email = $_.emailAddress.address } })
                        cc             = @($msg.ccRecipients | ForEach-Object { @{ name = $_.emailAddress.name; email = $_.emailAddress.address } })
                        sentUtc        = $msg.sentDateTime
                        conversationId = $msg.conversationId
                        size           = $stampedBytes.Length
                        filedBy        = $upn
                        filedVia       = "FileOnSend"
                    }
                    $notifyResult = Invoke-IndexApi -Method Post -Path "/api/emails" -Body $notifyBody
                    if (-not $notifyResult.Success) {
                        $totals.sentNotifyFailed++
                        # Durably queue the exact same payload rather than leaving this email to
                        # wait on sync_timer's much slower full-library backstop.
                        $queued = Invoke-IndexApi -Method Post -Path "/api/emails/pending" -Body $notifyBody -MaxAttempts 2
                        if (-not $queued.Success) {
                            Write-Warning "EmailFilingSync: notify AND pending-queue both failed for $finalName -- relying on sync_timer's backstop"
                        }
                    }

                    Write-Host "EmailFilingSync: FILED SENT ($($folderEntry.Source)/$projectCode) $label -> $finalName"
                    $totals.sentFiled++
                } else {
                    Write-Host "EmailFilingSync: ALREADY FILED (SENT, $projectCode) $label"
                    $totals.sentAlreadyFiled++
                }

                # Merge "Filed" into categories WITHOUT moving -- leave the sent item
                # exactly where the user put it (unlike the Inbox pass below, which moves
                # the original into a local "Filed" folder to declutter the inbox).
                #
                # Re-read categories now rather than reusing $labelsAsFound (captured back
                # when $messages was first listed, before the duplicate check, the .eml
                # download/upload and the index notify above -- all of which can take real
                # time per email). PATCHing that stale snapshot would silently discard any
                # category change (e.g. a filer tool still finishing its own categorize call)
                # that landed in between. 2026-10-13: suspected cause of reports of a
                # just-assigned project category disappearing.
                $currentCategories = (Invoke-GraphGetOrNull -Token $token -Uri (
                    "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)?`$select=categories"
                )).categories
                if ($null -eq $currentCategories) { $currentCategories = $labelsAsFound }
                $mergedCategories = @($currentCategories) + @("Filed") | Select-Object -Unique
                Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)" `
                    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
                    -Body (@{ categories = @($mergedCategories) } | ConvertTo-Json) -ErrorAction Stop | Out-Null

            } catch {
                $errorMessage = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    try {
                        $graphError = ($_.ErrorDetails.Message | ConvertFrom-Json).error
                        if ($graphError -and $graphError.code) { $errorMessage = "$($graphError.code): $($graphError.message)" }
                    } catch { }
                }
                Write-Error "EmailFilingSync: FAILED (sent) $label -- $errorMessage"
                $totals.sentFailed++
            }
        }
    } catch {
        Write-Error "EmailFilingSync: could not complete the Sent Items pass for '$upn': $($_.Exception.Message)"
        $totals.sentFailed++
    }

    try {
        $stagingFolder = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/users/$upn/mailFolders/inbox/childFolders?`$filter=$([uri]::EscapeDataString("displayName eq 'Emails to File'"))" `
            -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    } catch {
        Write-Error "EmailFilingSync: could not check '$upn' for an 'Emails to File' folder: $($_.Exception.Message)"
        $totals.failed++
        continue
    }
    if (-not $stagingFolder.value -or $stagingFolder.value.Count -eq 0) { continue }
    $stagingFolderId = $stagingFolder.value[0].id

    $messages = Get-GraphAllPages -Token $token -Uri (
        "https://graph.microsoft.com/v1.0/users/$upn/mailFolders/$stagingFolderId/messages" +
        "?`$select=id,subject,categories,internetMessageId,from,toRecipients,ccRecipients,sentDateTime,conversationId,conversationIndex,hasAttachments" +
        "&`$top=25"
    )
    if ($messages.Count -eq 0) { continue }
    Write-Host "EmailFilingSync: '$upn' has $($messages.Count) email(s) staged for filing"

    $filedFolderId = $null

    foreach ($msg in $messages) {
        $label = "'$upn' / $($msg.subject)"
        try {
            $categoryName = Resolve-FilingCategory -Categories @($msg.categories)
            if (-not $categoryName) {
                Write-Host "EmailFilingSync: SKIP (no project category) $label"
                $totals.skippedNoCategory++
                continue
            }

            $folderEntry = Resolve-ProjectFolder -CategoryName $categoryName -FolderEntries $folderEntries
            if (-not $folderEntry) {
                Write-Host "EmailFilingSync: SKIP (no matching project folder for '$categoryName') $label"
                $totals.skippedNoProjectFolder++
                continue
            }
            $projectCode = Get-ProjectCode -Text $folderEntry.Name
            $projectPath = "$($folderEntry.BranchPath)/$($folderEntry.Name)"

            $emailsFolderId = Get-OrCreateChildFolder -DriveId $folderEntry.DriveId -ParentPath $projectPath -ChildName "Emails" -Token $token

            # Naming uses sentDateTime as returned (UTC) rather than a true mailbox-local
            # time -- the index brief says the file name is for humans browsing the
            # folder only ("the index doesn't parse file names"), so an exact timezone
            # isn't worth the extra lookup here.
            $sentUtc = [DateTime]::Parse($msg.sentDateTime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $fromName = if ($msg.from.emailAddress.name) { $msg.from.emailAddress.name } else { $msg.from.emailAddress.address }
            $baseName = New-EmailFileName -SentLocal $sentUtc -FromName $fromName -Subject $msg.subject

            $existingBase = Invoke-GraphGetOrNull -Token $token -Uri (
                "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/root:/" +
                "$([uri]::EscapeDataString("$projectPath/Emails/$baseName") -replace '%2F','/')"
            )

            $finalName = $baseName
            $isDuplicate = $false
            if ($existingBase) {
                $hashSuffix = Get-MessageIdHashPrefix -MessageId $msg.internetMessageId
                $hashedName = New-EmailFileName -SentLocal $sentUtc -FromName $fromName -Subject $msg.subject -CollisionHashSuffix $hashSuffix
                $existingHashed = Invoke-GraphGetOrNull -Token $token -Uri (
                    "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/root:/" +
                    "$([uri]::EscapeDataString("$projectPath/Emails/$hashedName") -replace '%2F','/')"
                )
                $finalName = $hashedName
                $isDuplicate = [bool]$existingHashed
            }

            $labelsAsFound = @($msg.categories)

            if (-not $isDuplicate) {
                # Invoke-WebRequest instead of Invoke-RestMethod, added 2026-10-21: avoids
                # Invoke-RestMethod's own JSON/XML-oriented content-type sniffing, which caused
                # the 2026-10-08 corruption incident (one message, an Aconex auto-reply, came back
                # as a real byte[] instead of text; re-encoding that through GetBytes() -- which
                # has no byte[] overload -- silently coerced it to a string via PowerShell's
                # default array-to-string join, uploading that garbage as the "email"). CORRECTION
                # the same day: Invoke-WebRequest's own .Content is *not* reliably byte[] either on
                # this runtime -- confirmed live, a text-ish response came back as a plain string
                # and PowerShell's own [byte[]]-typed parameter binder on Add-SummationLabelsHeader
                # then tried (and failed loudly) to auto-coerce that string itself. Still explicitly
                # branching on the actual return type, same as the original fix, just applied here
                # instead -- there is no cmdlet in this runtime that reliably returns raw bytes
                # unconditionally, so the explicit check stays required regardless of which one is
                # used. (The avoided redundant string-copy this comment used to claim as a clean
                # memory win no longer applies when the string branch is taken, but Invoke-WebRequest
                # is still kept over Invoke-RestMethod for not attempting JSON/XML parsing at all.)
                $rawContent = (Invoke-WebRequest -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)/`$value" `
                    -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop).Content
                $originalBytes = if ($rawContent -is [byte[]]) { $rawContent } else { [System.Text.Encoding]::GetEncoding(28591).GetBytes([string]$rawContent) }
                $stampedBytes = Add-SummationLabelsHeader -MimeBytes $originalBytes -Labels $labelsAsFound

                if ($stampedBytes.Length -gt 4MB) {
                    Send-GraphLargeFile -DriveId $folderEntry.DriveId -ParentId $emailsFolderId -FileName $finalName -Bytes $stampedBytes -Token $token | Out-Null
                } else {
                    Invoke-RestMethod -Method Put `
                        -Uri "https://graph.microsoft.com/v1.0/drives/$($folderEntry.DriveId)/items/$($emailsFolderId):/$([uri]::EscapeDataString($finalName)):/content" `
                        -Headers @{ Authorization = "Bearer $token" } -ContentType "message/rfc822" -Body $stampedBytes -ErrorAction Stop | Out-Null
                }

                $library = if ($folderEntry.Source -eq "Active") { "Summation Hub - Active Projects" } else { "Summation Hub - Archieve Projects" }
                $notifyBody = @{
                    messageId    = $msg.internetMessageId
                    projectCode  = $projectCode
                    library      = $library
                    relativePath = "$projectPath/Emails/$finalName"
                    fileName     = $finalName
                    labels       = $labelsAsFound
                    subject      = $msg.subject
                    fromName     = $fromName
                    fromEmail    = $msg.from.emailAddress.address
                    to           = @($msg.toRecipients | ForEach-Object { @{ name = $_.emailAddress.name; email = $_.emailAddress.address } })
                    cc           = @($msg.ccRecipients | ForEach-Object { @{ name = $_.emailAddress.name; email = $_.emailAddress.address } })
                    sentUtc      = $msg.sentDateTime
                    conversationId = $msg.conversationId
                    size         = $stampedBytes.Length
                    filedBy      = $upn
                    filedVia     = "SyncTool"
                }
                $notifyResult = Invoke-IndexApi -Method Post -Path "/api/emails" -Body $notifyBody
                if (-not $notifyResult.Success) {
                    $totals.notifyFailed++
                    # Durably queue the exact same payload rather than leaving this email to
                    # wait on sync_timer's much slower full-library backstop.
                    $queued = Invoke-IndexApi -Method Post -Path "/api/emails/pending" -Body $notifyBody -MaxAttempts 2
                    if (-not $queued.Success) {
                        Write-Warning "EmailFilingSync: notify AND pending-queue both failed for $finalName -- relying on sync_timer's backstop"
                    }
                }

                Write-Host "EmailFilingSync: FILED ($($folderEntry.Source)/$projectCode) $label -> $finalName"
                $totals.filed++
            } else {
                Write-Host "EmailFilingSync: ALREADY FILED ($projectCode) $label"
                $totals.alreadyFiled++
            }

            # Leave whatever category the user actually assigned alone -- just add "Filed"
            # on top. This used to also strip any project-shaped category and replace it
            # with the bare project code (e.g. "SUPER26007_ProjectName" -> "SUPER26007"),
            # which silently rewrote the label the user picked; same merge as the Sent
            # Items pass above now.
            #
            # Re-read categories now rather than reusing $labelsAsFound (captured back when
            # $messages was first listed, before the duplicate check, the .eml download/
            # upload and the index notify above -- all of which can take real time per
            # email). PATCHing that stale snapshot would silently discard any category
            # change (e.g. a filer tool still finishing its own categorize call right as this
            # run started) that landed in between. 2026-10-13: suspected cause of reports of
            # a just-assigned project category disappearing after a Batch File Folder run.
            $currentCategories = (Invoke-GraphGetOrNull -Token $token -Uri (
                "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)?`$select=categories"
            )).categories
            if ($null -eq $currentCategories) { $currentCategories = $labelsAsFound }
            $mergedCategories = @($currentCategories) + @("Filed") | Select-Object -Unique
            Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)" `
                -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
                -Body (@{ categories = @($mergedCategories) } | ConvertTo-Json) -ErrorAction Stop | Out-Null

            if (-not $filedFolderId) {
                $filedFolderId = Get-OrCreateMailFolder -Upn $upn -DisplayName "Filed" -Token $token
            }
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/users/$upn/messages/$($msg.id)/move" `
                -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
                -Body (@{ destinationId = $filedFolderId } | ConvertTo-Json) -ErrorAction Stop | Out-Null

        } catch {
            $errorMessage = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try {
                    $graphError = ($_.ErrorDetails.Message | ConvertFrom-Json).error
                    if ($graphError -and $graphError.code) { $errorMessage = "$($graphError.code): $($graphError.message)" }
                } catch { }
            }
            Write-Error "EmailFilingSync: FAILED $label -- $errorMessage"
            $totals.failed++
        }
    }
}

Write-Host "EmailFilingSync: run complete. $($totals | ConvertTo-Json -Compress)"
