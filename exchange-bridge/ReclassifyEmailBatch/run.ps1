using namespace System.Net

# POST /api/reclassify-email-batch/{batchId}
# Body: { "graphAccessToken": "<caller's own Sites.Selected token>",
#         "indexAccessToken": "<caller's own EmailIndex.Access token>",
#         "indexBaseUrl": "https://summation-email-index.azurewebsites.net",
#         "targetProjectCode": "SUPER26000", "targetFolderName": "SUPER26000_SomeProject",
#         "targetDriveId": "...", "targetBranchPath": "Sustainability/Perth",
#         "targetLibrary": "Summation Hub - Active Projects" | "Summation Hub - Archieve Projects",
#         "items": [ { emailId, driveId, itemId, fileName, messageId, subject, fromName, fromEmail,
#                       to, cc, sentUtc, conversationId }, ... ] }
#
# Moves an already-filed email's .eml/.msg from wherever it's currently sitting in SharePoint
# into a different project's Emails folder -- Project Email Search's "Reclassify project"
# action (single email) and "Bulk reclassify" (multiselect). Same survive-disconnect shape as
# FileEmailBatch: once this HTTP request is received, Azure Functions keeps the invocation
# running to completion even if the caller's tab closes; the result is written to blob storage
# once, at completion, and the caller polls ReclassifyEmailBatchStatus to see it.
#
# graphAccessToken is the caller's own already-acquired Sites.Selected token (the same
# delegated permission Batch File Folder already uses to upload directly to SharePoint) --
# this never uses the bridge's own broader identity, only what the signed-in user already had
# permission to do themselves. Graph has no cross-folder "move" that's reliable across
# document libraries, so this always copies to the destination then deletes the original,
# which works the same whether the destination is the same library (Active/Archive) or not.
#
# indexAccessToken notifies email-index immediately after each move (POST /api/emails, the
# same call email-filing-sync already makes on every filing) so the email shows up under its
# new project right away rather than waiting for the next sync_timer pass. That call is
# best-effort: email-index's own delta scan will pick up the new file (and clean out the old,
# now-deleted one) within a few minutes regardless, so a failed notify here just means a short
# extra wait, not a lost email.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$batchId = $Request.Params.batchId
$graphAccessToken = $Request.Body.graphAccessToken
$indexAccessToken = $Request.Body.indexAccessToken
$indexBaseUrl = $Request.Body.indexBaseUrl
$targetProjectCode = $Request.Body.targetProjectCode
$targetFolderName = $Request.Body.targetFolderName
$targetDriveId = $Request.Body.targetDriveId
$targetBranchPath = $Request.Body.targetBranchPath
$targetLibrary = $Request.Body.targetLibrary
$items = $Request.Body.items

if (-not $batchId -or -not $graphAccessToken -or -not $targetProjectCode -or -not $targetFolderName `
        -or -not $targetDriveId -or -not $targetBranchPath -or -not $targetLibrary -or -not $items -or $items.Count -eq 0) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "batchId (route), graphAccessToken, targetProjectCode, targetFolderName, targetDriveId, " `
            + "targetBranchPath, targetLibrary, and a non-empty items array are all required."
    })
    return
}

$graphHeaders = @{ Authorization = "Bearer $graphAccessToken"; "Content-Type" = "application/json" }

function Get-OrCreateEmailsFolderId {
    param([string]$DriveId, [string]$ParentPath, [string]$Token)
    $childPath = "$ParentPath/Emails"
    try {
        $existing = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($childPath) -replace '%2F','/')" `
            -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
        return $existing.id
    } catch {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
    }
    $parent = Invoke-RestMethod -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($ParentPath) -replace '%2F','/')" `
        -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
    $body = @{ name = "Emails"; folder = @{}; "@microsoft.graph.conflictBehavior" = "fail" } | ConvertTo-Json
    try {
        $created = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($parent.id)/children" `
            -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } -Body $body -ErrorAction Stop
        return $created.id
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) {
            $reGet = Invoke-RestMethod -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($childPath) -replace '%2F','/')" `
                -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
            return $reGet.id
        }
        throw
    }
}

function Copy-ItemAndWait {
    # Graph's copy is always asynchronous: POST returns 202 + a Location header (a monitor
    # URL, no auth needed) to poll until it reports "completed", at which point it carries the
    # new item's id.
    param([string]$SourceDriveId, [string]$SourceItemId, [string]$DestDriveId, [string]$DestFolderId, [string]$Name, [string]$Token)
    $body = @{
        parentReference = @{ driveId = $DestDriveId; id = $DestFolderId }
        name = $Name
        "@microsoft.graph.conflictBehavior" = "rename"
    } | ConvertTo-Json
    $resp = Invoke-WebRequest -Method Post -Uri "https://graph.microsoft.com/v1.0/drives/$SourceDriveId/items/$SourceItemId/copy" `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } -Body $body -ErrorAction Stop
    $monitorUrl = $resp.Headers["Location"]
    if ($monitorUrl -is [array]) { $monitorUrl = $monitorUrl[0] }
    if (-not $monitorUrl) { throw "Graph didn't return a monitor URL for the copy." }

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $progress = Invoke-RestMethod -Method Get -Uri $monitorUrl -ErrorAction Stop
        if ($progress.status -eq "completed") { return $progress.resourceId }
        if ($progress.status -eq "failed") { throw "Graph copy failed: $($progress.error | ConvertTo-Json -Compress)" }
        Start-Sleep -Seconds 1
    }
    throw "Timed out waiting for the SharePoint copy to finish."
}

function Send-IndexNotify {
    # Best-effort, same as email-filing-sync's own Invoke-IndexApi -- the index's own delta
    # scan will pick this file up within a few minutes regardless (same tolerance that notify
    # call relies on), so this never throws into the caller's own move/delete result. A
    # transient failure (timeout/network/5xx) gets a couple of attempts with a short backoff; a
    # 4xx is a client error retrying can't fix, so it fails fast. Used to swallow every
    # failure with no trace at all -- now that both Function Apps are confirmed to actually
    # ship traces to Application Insights, an exhausted failure is surfaced via Write-Warning
    # instead of vanishing silently.
    #
    # Deliberately fewer attempts and a shorter timeout than email-filing-sync's own
    # Invoke-IndexApi (5 attempts, 15s each): this runs once per item inside a single
    # invocation's sequential foreach over up to RC_CHUNK_SIZE (20) items, against a 9-minute
    # function timeout (host.json). 5 attempts x 15s here would add up to ~100s per item if the
    # index were down -- across 20 items that alone blows the whole budget, and a mid-batch
    # timeout means BatchBlob never gets written at all (it's one output binding, written once
    # at the very end), so every item that genuinely succeeded before the timeout would report
    # as "not found" forever. 2 attempts x 8s keeps this call's worst case to ~18s/item.
    param($Item, [string]$NewItemId, [string]$WebUrl, [int64]$Size)
    if (-not $indexAccessToken -or -not $indexBaseUrl) { return }
    $relativePath = "$targetBranchPath/$targetFolderName/Emails/$($Item.fileName)"
    $payload = @{
        messageId      = $Item.messageId
        projectCode    = $targetProjectCode
        library        = $targetLibrary
        relativePath   = $relativePath
        fileName       = $Item.fileName
        labels         = @($targetProjectCode)
        subject        = $Item.subject
        fromName       = $Item.fromName
        fromEmail      = $Item.fromEmail
        to             = @($Item.to)
        cc             = @($Item.cc)
        sentUtc        = $Item.sentUtc
        conversationId = $Item.conversationId
        size           = $Size
        driveId        = $targetDriveId
        itemId         = $NewItemId
        webUrl         = $WebUrl
        filedVia       = "Reclassify"
    } | ConvertTo-Json -Depth 6

    $maxAttempts = 2
    $lastError = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Method Post -Uri "$indexBaseUrl/api/emails" `
                -Headers @{ Authorization = "Bearer $indexAccessToken"; "Content-Type" = "application/json" } `
                -Body $payload -TimeoutSec 8 -ErrorAction Stop | Out-Null
            return
        } catch {
            $lastError = $_
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500) {
                Write-Warning "ReclassifyEmailBatch: index notify POST $indexBaseUrl/api/emails returned $statusCode for batch $batchId / messageId $($Item.messageId) -- not retrying a client error. $($_.Exception.Message)"
                return
            }
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 2
            }
        }
    }
    Write-Warning "ReclassifyEmailBatch: index notify POST $indexBaseUrl/api/emails failed after $maxAttempts attempts for batch $batchId / messageId $($Item.messageId) -- $($lastError.Exception.Message)"
}

$emailsFolderId = $null
$results = @()
$succeeded = 0
$failed = 0

try {
    $emailsFolderId = Get-OrCreateEmailsFolderId -DriveId $targetDriveId -ParentPath "$targetBranchPath/$targetFolderName" -Token $graphAccessToken
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadGateway) -Body @{
        error = "Couldn't resolve or create the destination project's Emails folder: $($_.Exception.Message)"
    })
    return
}

foreach ($item in $items) {
    $status = $null
    $errorMessage = $null
    try {
        $newItemId = Copy-ItemAndWait -SourceDriveId $item.driveId -SourceItemId $item.itemId `
            -DestDriveId $targetDriveId -DestFolderId $emailsFolderId -Name $item.fileName -Token $graphAccessToken

        $newItem = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/drives/$targetDriveId/items/$($newItemId)?`$select=id,webUrl,size" `
            -Headers @{ Authorization = "Bearer $graphAccessToken" } -ErrorAction Stop

        Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/v1.0/drives/$($item.driveId)/items/$($item.itemId)" `
            -Headers @{ Authorization = "Bearer $graphAccessToken" } -ErrorAction Stop | Out-Null

        Send-IndexNotify -Item $item -NewItemId $newItem.id -WebUrl $newItem.webUrl -Size $newItem.size

        $status = "done"
        $succeeded++
    } catch {
        $status = "failed"
        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $graphError = ($_.ErrorDetails.Message | ConvertFrom-Json).error
                if ($graphError -and $graphError.code) { $errorMessage = "$($graphError.code): $($graphError.message)" }
            } catch { }
        }
        $failed++
    }
    $results += [ordered]@{
        emailId = $item.emailId
        subject = $item.subject
        status  = $status
        error   = $errorMessage
    }
}

$batchResult = [ordered]@{
    batchId           = $batchId
    targetProjectCode = $targetProjectCode
    total             = $items.Count
    succeeded         = $succeeded
    failed            = $failed
    status            = "done"
    completedAt       = (Get-Date).ToUniversalTime().ToString("o")
    items             = $results
}

Push-OutputBinding -Name BatchBlob -Value ($batchResult | ConvertTo-Json -Depth 6)
Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $batchResult)
