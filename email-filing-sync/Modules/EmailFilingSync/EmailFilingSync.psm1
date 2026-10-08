# Shared helpers for the Email Filing Sync Function App.
#
# This app has no signed-in user at all -- it's a timer trigger, not an HTTP-triggered
# bridge like exchange-bridge -- so every Graph call here uses one app-only token
# (client-credentials + certificate, "Summation Email Filing Sync" app registration,
# a THIRD app registration separate from both "Summation Outlook Add-in" and
# "Summation Exchange Bridge" -- see email-filing-sync/README.md for why). Mail calls
# therefore always go through /users/{upn}/... rather than /me/..., and must stay
# inside whichever mailboxes the Exchange Application Access Policy on that app
# actually allows -- Entra consent alone does not narrow this, the access policy does.

$ProjectCodePattern = '^([a-zA-Z]{5}\d{5})[_\s-]'
$ProjectMailboxPattern = '^[a-zA-Z]{5}\d{5}[_-].*@summation\.au$'

# Branch folder is not the same path in both libraries -- ported verbatim from
# taskpane.html's ACTIVE_BRANCH_PATH / ARCHIVE_BRANCH_PATH. Keep both in sync if
# that ever changes; there's no shared module between the add-in (JS) and this
# Function App (PowerShell) to enforce it automatically.
$ActiveBranchPath = @{
    SUPER = "Sustainability/Perth"
    SUADL = "Sustainability/Adelaide"
    ENPER = "Energy/Perth"
    ENADL = "Energy/Adelaide"
}
$ArchiveBranchPath = @{
    SUPER = "Sustainability/Perth"
    SUADL = "Sustainability/Archived_Adelaide"
    ENPER = "Energy/Perth"
    ENADL = "Energy/Adelaide"
}

$script:CachedToken = $null
$script:CachedTokenExpiresAt = [DateTime]::MinValue

function Get-GraphAppToken {
    # Cached for the lifetime of a warm instance, refreshed a minute before expiry.
    # A single sync run touches every staff mailbox plus both SharePoint libraries --
    # acquiring a fresh token per call would be dozens of extra round trips for no reason.
    #
    # -ForceRefresh: MSAL.PS persists its own token cache to disk by default, and that
    # disk location can survive a plain Functions-host restart (same underlying site
    # storage) even though $script:CachedToken itself is reset to $null in the new
    # process. Diagnosed 2026-10-06: after adding GroupMember.Read.All and redeploying,
    # runs kept reporting 0 staff mailboxes with no error at all, which only makes sense
    # if Invoke-RestMethod was silently using a stale, pre-consent token MSAL handed back
    # from its own disk cache. Forcing a refresh here trades one extra token request per
    # 5-minute run (cheap) for never silently running on stale permissions again.
    if ($script:CachedToken -and (Get-Date) -lt $script:CachedTokenExpiresAt) {
        return $script:CachedToken
    }

    Import-Module MSAL.PS -ErrorAction Stop
    $cert = Get-Item "Cert:\CurrentUser\My\$env:GRAPH_CERT_THUMBPRINT" -ErrorAction Stop
    $result = Get-MsalToken `
        -ClientId $env:GRAPH_APP_ID `
        -TenantId $env:GRAPH_TENANT_ID `
        -ClientCertificate $cert `
        -Scopes "https://graph.microsoft.com/.default" `
        -ForceRefresh

    $payload = $result.AccessToken.Split('.')[1]
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace('-','+').Replace('_','/'))) | ConvertFrom-Json
    Write-Host "EmailFilingSync: acquired token with roles [$($claims.roles -join ', ')], expires $($result.ExpiresOn)"

    $script:CachedToken = $result.AccessToken
    $script:CachedTokenExpiresAt = $result.ExpiresOn.UtcDateTime.AddMinutes(-1)
    return $script:CachedToken
}

function Invoke-GraphGetOrNull {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token)
    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-GraphAllPages {
    # Follows @odata.nextLink until exhausted -- same shape as taskpane.html's graphGetAll,
    # needed here for /users (staff list) and large mail-folder listings.
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token)
    $items = @()
    $next = $Uri
    while ($next) {
        $page = Invoke-RestMethod -Method Get -Uri $next -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
        if ($page.value) { $items += $page.value }
        $next = $page.'@odata.nextLink'
    }
    return $items
}

function Get-StaffMailboxes {
    # Reads the SAME "Summation Staff Mailboxes" group the Exchange Application Access
    # Policy is scoped to (STAFF_GROUP_ID app setting), rather than re-deriving "staff"
    # from a broad /users listing + regex-exclude the way the taskpane does -- reading the
    # exact group the access policy already trusts means there is no way for "who this
    # code thinks is staff" to drift from "whose mail Exchange actually lets it touch."
    #
    # Needs User.Read.All (app-only) as well as GroupMember.Read.All -- confirmed
    # 2026-10-06 that without it, Graph's /members response for a group returns every
    # selected property (displayName, mail, accountEnabled) as null for an app-only
    # caller, even though the identical call works for a delegated/signed-in caller
    # (who gets baseline directory-read for free). Only `id` survives that without
    # User.Read.All; the mail calls below would still work addressed by id alone, but
    # logging and the index's filedBy field want a real name/address.
    param([Parameter(Mandatory)][string]$Token)
    $groupId = $env:STAFF_GROUP_ID
    $uri = "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=displayName,mail,userPrincipalName,accountEnabled&`$top=999"
    $members = Get-GraphAllPages -Uri $uri -Token $Token
    return @($members | Where-Object { $_.accountEnabled -ne $false } |
        ForEach-Object { [pscustomobject]@{ Name = $_.displayName; Mail = ($_.mail ?? $_.userPrincipalName) } } |
        Where-Object { $_.Mail -and ($_.Mail -notmatch $ProjectMailboxPattern) })
}

function Get-ProjectFolderEntries {
    # Loads every project folder once per run (both libraries, all four branch combos),
    # the same approach taskpane.html's loadFeFolderNames() uses -- one invocation's worth
    # of emails can then be matched against this in memory instead of a Graph call per email.
    param([Parameter(Mandatory)][string]$Token)
    $entries = @()
    foreach ($combo in $ActiveBranchPath.Keys) {
        $path = $ActiveBranchPath[$combo]
        $data = Invoke-GraphGetOrNull -Uri "https://graph.microsoft.com/v1.0/drives/$env:ACTIVE_DRIVE_ID/root:/$([uri]::EscapeDataString($path) -replace '%2F','/'):/children?`$select=id,name,folder&`$top=999" -Token $Token
        if ($data -and $data.value) {
            foreach ($f in ($data.value | Where-Object { $_.folder -and $_.name -notmatch '(?i)template' })) {
                $entries += [pscustomobject]@{ Name = $f.name; Id = $f.id; DriveId = $env:ACTIVE_DRIVE_ID; BranchPath = $path; Source = "Active" }
            }
        }
    }
    foreach ($combo in $ArchiveBranchPath.Keys) {
        $path = $ArchiveBranchPath[$combo]
        $data = Invoke-GraphGetOrNull -Uri "https://graph.microsoft.com/v1.0/drives/$env:ARCHIVE_DRIVE_ID/root:/$([uri]::EscapeDataString($path) -replace '%2F','/'):/children?`$select=id,name,folder&`$top=999" -Token $Token
        if ($data -and $data.value) {
            foreach ($f in ($data.value | Where-Object { $_.folder -and $_.name -notmatch '(?i)template' })) {
                $entries += [pscustomobject]@{ Name = $f.name; Id = $f.id; DriveId = $env:ARCHIVE_DRIVE_ID; BranchPath = $path; Source = "Archive" }
            }
        }
    }
    return $entries
}

function Get-ProjectCode {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, $ProjectCodePattern)
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return $null
}

function Resolve-ProjectFolder {
    # categories can carry more than one project-shaped label; the folder the email is
    # ABOUT is whichever one the sync tool was told to file it to (categoryName, picked by
    # Resolve-FilingCategory below) -- this just finds that one project's folder.
    param(
        [Parameter(Mandatory)][string]$CategoryName,
        [Parameter(Mandatory)][array]$FolderEntries
    )
    $code = Get-ProjectCode -Text $CategoryName
    if (-not $code) { return $null }
    return $FolderEntries | Where-Object { (Get-ProjectCode -Text $_.Name) -eq $code } | Select-Object -First 1
}

function Resolve-FilingCategory {
    # An email can carry several categories (OnePageCRM, Filed, more than one project code
    # if it's genuinely relevant to two projects). This picks the one the sync tool should
    # file BY: the first category that parses as a project label (bare CODE or
    # CODE_Name/CODE-Name), same convention File Email already writes.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Categories)
    foreach ($c in $Categories) {
        if (Get-ProjectCode -Text $c) { return $c }
    }
    return $null
}

function Get-OrCreateChildFolder {
    # GET-then-create-on-404, tolerating a 409 from a concurrent creator by re-GETting --
    # same shape as complete-action.html's getOrCreateBranchFolder/createFolder pair.
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$ChildName,
        [Parameter(Mandatory)][string]$Token
    )
    $childPath = "$ParentPath/$ChildName"
    $existing = Invoke-GraphGetOrNull -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($childPath) -replace '%2F','/')" -Token $Token
    if ($existing) { return $existing.id }

    $parent = Invoke-GraphGetOrNull -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($ParentPath) -replace '%2F','/')" -Token $Token
    if (-not $parent) { throw "Project folder '$ParentPath' does not exist (drive $DriveId)." }

    try {
        $body = @{ name = $ChildName; folder = @{}; "@microsoft.graph.conflictBehavior" = "fail" } | ConvertTo-Json
        $created = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($parent.id)/children" `
            -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } -Body $body -ErrorAction Stop
        return $created.id
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) {
            $reGet = Invoke-GraphGetOrNull -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$([uri]::EscapeDataString($childPath) -replace '%2F','/')" -Token $Token
            if ($reGet) { return $reGet.id }
        }
        throw
    }
}

function Get-SanitizedNamePart {
    # Strips characters SharePoint/Windows disallow in file names, plus control
    # characters; trims a leading ~ and trailing dots/spaces (ported from the index
    # brief's "File name" rules).
    param([string]$Text)
    $clean = ($Text -replace '[\\/:\*\?"<>\|#%]', '') -replace '[\x00-\x1f]', ''
    $clean = $clean.TrimStart('~').Trim(' ', '.')
    return $clean
}

function New-EmailFileName {
    # "YYYY-MM-DD HHMM - {From name} - {Subject}.eml", RE:/FW: stripped, capped at 100
    # characters at a word boundary, with a 6-hex-char hash suffix appended on collision.
    param(
        [Parameter(Mandatory)][DateTime]$SentLocal,
        [Parameter(Mandatory)][string]$FromName,
        [Parameter(Mandatory)][string]$Subject,
        [string]$CollisionHashSuffix
    )
    $cleanSubject = $Subject -replace '(?i)^(re|fw|fwd):\s*', ''
    $cleanSubject = $cleanSubject -replace '(?i)^(re|fw|fwd):\s*', '' # strip a second stacked prefix, e.g. "RE: FW:"
    $stamp = $SentLocal.ToString("yyyy-MM-dd HHmm")
    $namePart = Get-SanitizedNamePart "$stamp - $(Get-SanitizedNamePart $FromName) - $(Get-SanitizedNamePart $cleanSubject)"

    if ($namePart.Length -gt 100) {
        $truncated = $namePart.Substring(0, 100)
        $lastSpace = $truncated.LastIndexOf(' ')
        if ($lastSpace -gt 50) { $truncated = $truncated.Substring(0, $lastSpace) }
        $namePart = $truncated
    }

    if ($CollisionHashSuffix) { $namePart = "$namePart [$CollisionHashSuffix]" }
    return "$namePart.eml"
}

function Get-MessageIdHashPrefix {
    param([Parameter(Mandatory)][string]$MessageId)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($MessageId))
        return (($bytes | Select-Object -First 3 | ForEach-Object { $_.ToString("x2") }) -join '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-Rfc2047EncodedWord {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -match '^[\x00-\x7f]*$') { return $Text }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $b64 = [Convert]::ToBase64String($bytes)
    return "=?utf-8?b?$b64?="
}

function Add-SummationLabelsHeader {
    # Prepends "X-Summation-Labels: <labels>\r\n" as the very first line of the raw MIME
    # bytes Graph returned, per the index brief -- written even when there are no labels
    # (an EMPTY header means "no labels"; a MISSING header means "labels unknown"), and
    # RFC-2047-encoded if any label contains non-ASCII (Outlook category names can).
    param(
        [Parameter(Mandatory)][byte[]]$MimeBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Labels
    )
    $encoded = ($Labels | ForEach-Object { Get-Rfc2047EncodedWord $_ }) -join ', '
    $headerLine = "X-Summation-Labels: $encoded`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerLine)
    $combined = New-Object byte[] ($headerBytes.Length + $MimeBytes.Length)
    [Array]::Copy($headerBytes, 0, $combined, 0, $headerBytes.Length)
    [Array]::Copy($MimeBytes, 0, $combined, $headerBytes.Length, $MimeBytes.Length)
    return $combined
}

function Get-LabelStatus {
    # match / mismatch / none, per the index brief's "Project and labels" table. "unknown"
    # is the index's own status for an email it received with no label information at all --
    # not applicable here, since the sync tool always knows the labels it's filing with.
    param(
        [Parameter(Mandatory)][string]$FolderProjectCode,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Labels
    )
    $labelCodes = $Labels | ForEach-Object { Get-ProjectCode -Text $_ } | Where-Object { $_ }
    if ($labelCodes.Count -eq 0) { return "none" }
    if ($labelCodes -contains $FolderProjectCode) { return "match" }
    return "mismatch"
}

function Get-OrCreateMailFolder {
    # App-only equivalent of taskpane.html's getOrCreateEmailsToFileFolderId -- used here
    # for the "Filed" destination folder (and defensively for "Emails to File" itself, in
    # case a mailbox somehow has the category convention but not yet the folder).
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Token
    )
    $filter = [uri]::EscapeDataString("displayName eq '$DisplayName'")
    $existing = Invoke-RestMethod -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/inbox/childFolders?`$filter=$filter" `
        -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
    if ($existing.value -and $existing.value.Count -gt 0) { return $existing.value[0].id }

    $body = @{ displayName = $DisplayName } | ConvertTo-Json
    $created = Invoke-RestMethod -Method Post `
        -Uri "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/inbox/childFolders" `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } -Body $body -ErrorAction Stop
    return $created.id
}

function Send-GraphLargeFile {
    # Graph's simple PUT upload (used for everything <=4MB) is hard-capped at 4MB --
    # anything bigger needs an upload session: create it, then PUT the file in
    # sequential byte-range chunks. Chunk size is a multiple of 320 KiB as Graph's docs
    # require for every chunk but the last. No arbitrary size ceiling here -- Graph
    # supports sessions well beyond anything a real email (even with attachments) will
    # ever reach, so this replaces the old ">4MB: skip" gap entirely rather than just
    # raising the threshold.
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$ParentId,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Token
    )
    $chunkSize = 10mb
    $total = $Bytes.Length

    $sessionBody = @{ item = @{ "@microsoft.graph.conflictBehavior" = "replace" } } | ConvertTo-Json
    $session = Invoke-RestMethod -Method Post `
        -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($ParentId):/$([uri]::EscapeDataString($FileName)):/createUploadSession" `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } -Body $sessionBody -ErrorAction Stop
    $uploadUrl = $session.uploadUrl

    $offset = 0
    $result = $null
    while ($offset -lt $total) {
        $length = [Math]::Min($chunkSize, $total - $offset)
        $chunk = New-Object byte[] $length
        [Array]::Copy($Bytes, $offset, $chunk, 0, $length)
        $rangeHeader = "bytes $offset-$($offset + $length - 1)/$total"

        $attempt = 0
        $uploaded = $false
        while (-not $uploaded) {
            $attempt++
            try {
                # No Authorization header here on purpose -- the upload session's own
                # uploadUrl is a pre-authorized, short-lived SAS-style URL; Graph's docs
                # say not to send a bearer token with it.
                $result = Invoke-RestMethod -Method Put -Uri $uploadUrl `
                    -Headers @{ "Content-Range" = $rangeHeader } `
                    -ContentType "application/octet-stream" `
                    -Body $chunk -ErrorAction Stop
                $uploaded = $true
            } catch {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        $offset += $length
    }
    return $result
}

function Invoke-IndexApi {
    # Best-effort only -- never throws, so a caller's own save never fails over this, per the
    # index brief's Must requirement ("never fail a save because the index is unreachable").
    # Used to silently swallow every failure on the historical reasoning that the configured
    # base URL was almost always http://127.0.0.1:8792 -- a loopback address on whichever
    # staff PC happened to be running the prototype indexer, essentially never reachable from
    # this cloud-hosted Function. That's no longer true (the index is now a real hosted
    # Function App), so a transient failure (timeout/network/5xx) is retried up to
    # $MaxAttempts times with a short backoff, and an exhausted failure is surfaced via
    # Write-Warning instead of vanishing. A 4xx is a client error retrying can never fix, so
    # it fails fast without burning through the remaining attempts.
    #
    # Returns a [pscustomobject]@{ Success; Data } rather than bare data-or-$null, so a caller
    # that wants to count notify failures (see SyncEmails/run.ps1's notifyFailed/
    # sentNotifyFailed totals) can tell "exhausted and gave up" apart from "nothing configured,
    # nothing attempted" -- both of which have Data = $null.
    param(
        [Parameter(Mandatory)][ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [int]$TimeoutSec = 5,
        [int]$MaxAttempts = 5
    )
    $baseUrl = $env:EMAIL_INDEX_BASE_URL
    if (-not $baseUrl) { return [pscustomobject]@{ Success = $true; Data = $null } }
    $uri = "$baseUrl$Path"
    $json = if ($Method -eq "Post") { $Body | ConvertTo-Json -Depth 6 } else { $null }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($Method -eq "Get") {
                $data = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
            } else {
                $data = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body $json -TimeoutSec $TimeoutSec -ErrorAction Stop
            }
            return [pscustomobject]@{ Success = $true; Data = $data }
        } catch {
            $lastError = $_
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500) {
                Write-Warning "EmailFilingSync: index API $Method $Path returned $statusCode -- not retrying a client error. $($_.Exception.Message)"
                return [pscustomobject]@{ Success = $false; Data = $null }
            }
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt)))
            }
        }
    }
    Write-Warning "EmailFilingSync: index API $Method $Path failed after $MaxAttempts attempts -- $($lastError.Exception.Message)"
    return [pscustomobject]@{ Success = $false; Data = $null }
}

Export-ModuleMember -Function `
    Get-GraphAppToken, Invoke-GraphGetOrNull, Get-GraphAllPages, Get-StaffMailboxes, `
    Get-ProjectFolderEntries, Get-ProjectCode, Resolve-ProjectFolder, Resolve-FilingCategory, `
    Get-OrCreateChildFolder, New-EmailFileName, Get-MessageIdHashPrefix, Add-SummationLabelsHeader, `
    Get-LabelStatus, Get-OrCreateMailFolder, Invoke-IndexApi, Send-GraphLargeFile
