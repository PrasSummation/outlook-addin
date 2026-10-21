using namespace System.Net

# POST /api/remediate-corrupted-emails
# Body (scan): { "mode": "scan", "resumeIndex": <int, optional>, "resumeFileIndex": <int, optional> }
# Body (fix):  { "mode": "fix", "files": [ {driveId, itemId, fileName, project, emailsFolderId}, ... ] }
#
# TEMPORARY, one-off remediation helper for the "silent email-content corruption" bug (see
# EmailFilingSync.psm1/SyncEmails's own history) -- a message fetched via the old
# Invoke-RestMethod /$value call could come back as something other than a plain string or a
# strict [byte[]], and got silently stringified via PowerShell's default array-to-string join
# (each byte rendered as its decimal value, space-separated) instead of the real bytes. Confirmed
# live on an already-filed email (SUPER25060_Perth Town Hall Undercroft, dated 2026-10-20 -- ten
# days after the first, incomplete fix for this class of bug). SyncEmails/run.ps1's switch to
# Invoke-WebRequest (2026-10-21) is what stops NEW corruption; this finds (and, in "fix" mode,
# repairs) already-corrupted files already sitting in SharePoint. A full scan on 2026-10-21 found
# 2,936 corrupted files across 80 projects (~19% of everything ever filed) -- "fix" decodes each
# one back to its original bytes (the corruption is fully reversible) and overwrites it in place,
# but only after a sanity check confirms the decoded content actually looks like a real email;
# anything that fails either step is left untouched and reported, never guessed at.
#
# Remove this function (and its route) once remediation is confirmed complete -- it exists to use
# the Function App's own app-only Graph identity against both project libraries for a one-off
# job, which isn't something this app should carry around as permanent surface area.
#
# "scan" never writes anything. Resumable: each call processes project folders starting at
# resumeIndex/resumeFileIndex within a time budget (shortened to 45 seconds, 2026-10-21 -- this
# Consumption plan isn't reliable for long-running HTTP calls regardless of client-side timeout
# settings) and returns where to resume from, plus whatever it found in this chunk. The caller is
# responsible for merging results across calls -- this function is stateless by design (no blob/
# table state, nothing to clean up afterward beyond removing the function itself). "fix" takes a
# batch of files from a prior scan and actually overwrites them -- not resumable/chunked itself,
# so the caller should keep each batch small enough to finish well within the same time budget.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/EmailFilingSync/EmailFilingSync.psm1" -Force

function New-JsonResponse {
    param([Parameter(Mandatory)][int]$StatusCode, [Parameter(Mandatory)]$Body)
    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ "Content-Type" = "application/json" }
        Body       = ($Body | ConvertTo-Json -Depth 6)
    }
}

$mode = $Request.Body.mode
if ($mode -ne "scan" -and $mode -ne "fix") {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "mode must be 'scan' or 'fix'."
    })
    return
}

try {
    $token = Get-GraphAppToken
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = "Could not acquire a Graph token: $($_.Exception.Message)"
    })
    return
}

# "fix" mode: takes a list of files (as returned by a "scan" -- {driveId, itemId, fileName,
# project, emailsFolderId}) and actually remediates them. Added 2026-10-21 after the scan found
# 2,936 corrupted files across 80 projects -- too many to review individually, so this is
# deliberately conservative: it decodes and sanity-checks each file before ever overwriting
# anything, and reports a failure rather than guessing when either step doesn't check out.
if ($mode -eq "fix") {
    $files = $Request.Body.files
    if (-not $files -or $files.Count -eq 0) {
        Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
            error = "fix mode requires a non-empty 'files' array (as returned by a scan)."
        })
        return
    }

    # Reverses PowerShell's default array-to-string join: splits the corrupted text on
    # whitespace, parses each token as a byte value (0-255). A token that isn't a clean integer
    # in that range means this wasn't actually the known corruption pattern after all -- returns
    # $null rather than guessing, so the caller can report it as unresolved instead of writing
    # garbage back to SharePoint.
    function ConvertFrom-CorruptedBytes {
        param([Parameter(Mandatory)][string]$Text)
        $tokens = $Text -split '\s+' | Where-Object { $_ -ne '' }
        if ($tokens.Count -eq 0) { return $null }
        $bytes = New-Object byte[] $tokens.Count
        for ($k = 0; $k -lt $tokens.Count; $k++) {
            $n = 0
            if (-not [int]::TryParse($tokens[$k], [ref]$n) -or $n -lt 0 -or $n -gt 255) { return $null }
            $bytes[$k] = [byte]$n
        }
        return $bytes
    }

    # Sanity check before ever overwriting anything: a real email's first line always looks like
    # "Header-Name: value" (RFC 5322) -- printable ASCII, a colon, letters/hyphens before it.
    function Test-LooksLikeRealEmail {
        param([Parameter(Mandatory)][byte[]]$Bytes)
        if ($Bytes.Length -lt 10) { return $false }
        $prefixLen = [Math]::Min(500, $Bytes.Length)
        $prefix = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $prefixLen)
        $firstLine = ($prefix -split "`r`n|`n")[0]
        return $firstLine -match '^[A-Za-z][A-Za-z0-9\-]*:\s'
    }

    $fixResults = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        try {
            $resp = Invoke-WebRequest -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/drives/$($f.driveId)/items/$($f.itemId)/content" `
                -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
            # Same byte[]-vs-string uncertainty as everywhere else in this codebase -- the
            # corrupted file's content is plain ASCII digits/whitespace either way, so decoding
            # it to a string for ConvertFrom-CorruptedBytes to split is safe regardless of which
            # type Invoke-WebRequest actually handed back this time.
            $rawContent = $resp.Content
            $corruptedText = if ($rawContent -is [byte[]]) { [System.Text.Encoding]::ASCII.GetString($rawContent) } else { [string]$rawContent }

            $decoded = ConvertFrom-CorruptedBytes -Text $corruptedText
            if (-not $decoded) {
                $fixResults.Add([ordered]@{ project = $f.project; fileName = $f.fileName; status = "failed"; reason = "could not decode as the known corruption pattern" })
                continue
            }
            if (-not (Test-LooksLikeRealEmail -Bytes $decoded)) {
                $fixResults.Add([ordered]@{ project = $f.project; fileName = $f.fileName; status = "failed"; reason = "decoded content doesn't look like a real email -- left untouched" })
                continue
            }

            if ($decoded.Length -gt 4MB) {
                Send-GraphLargeFile -DriveId $f.driveId -ParentId $f.emailsFolderId -FileName $f.fileName -Bytes $decoded -Token $token | Out-Null
            } else {
                Invoke-RestMethod -Method Put `
                    -Uri "https://graph.microsoft.com/v1.0/drives/$($f.driveId)/items/$($f.itemId)/content" `
                    -Headers @{ Authorization = "Bearer $token" } -ContentType "message/rfc822" -Body $decoded -ErrorAction Stop | Out-Null
            }
            $fixResults.Add([ordered]@{ project = $f.project; fileName = $f.fileName; status = "fixed"; corruptedSizeBytes = $corruptedText.Length; fixedSizeBytes = $decoded.Length })
        } catch {
            $fixResults.Add([ordered]@{ project = $f.project; fileName = $f.fileName; status = "failed"; reason = $_.Exception.Message })
        }
    }

    $fixBody = [ordered]@{
        mode    = "fix"
        total   = $files.Count
        fixed   = @($fixResults | Where-Object { $_.status -eq "fixed" }).Count
        failed  = @($fixResults | Where-Object { $_.status -eq "failed" }).Count
        results = $fixResults
    }
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $fixBody)
    return
}

# Corruption signature: a real email's very first bytes are always a MIME header line
# ("X-Summation-Labels: ...", "Received: from...", "From: ..."), which is never just digits and
# whitespace. The corrupted form is ENTIRELY digits/whitespace throughout (each original byte
# rendered as its decimal value, space-separated) -- a short peek is enough to tell the two apart
# without downloading the whole file.
function Test-CorruptionSignature {
    param([Parameter(Mandatory)][byte[]]$Peek)
    if ($Peek.Length -eq 0) { return $false }
    $text = [System.Text.Encoding]::ASCII.GetString($Peek)
    return $text -match '^[0-9\s]+$'
}

$resumeIndex = 0
if ($Request.Body.resumeIndex) { $resumeIndex = [int]$Request.Body.resumeIndex }
$resumeFileIndex = 0
if ($Request.Body.resumeFileIndex) { $resumeFileIndex = [int]$Request.Body.resumeFileIndex }

$folderEntries = Get-ProjectFolderEntries -Token $token
# Shortened from 7 minutes to 45 seconds, 2026-10-21: a long-running HTTP call on this Consumption
# plan isn't reliable regardless of client-side timeout settings -- confirmed live, one call ran
# the full ~7 minutes and completed successfully, but a later identical call got cut off by what
# looks like a platform-level instance recycle around 1m41s into execution. Short, frequent,
# resumable calls sidestep the problem entirely rather than fighting the platform's own lifetime
# management for long-running Consumption-plan requests.
$deadline = (Get-Date).AddSeconds(45)
$scannedProjects = 0
$scannedFiles = 0
$corrupted = [System.Collections.Generic.List[object]]::new()
$peekErrors = [System.Collections.Generic.List[object]]::new()
$i = $resumeIndex
$doneAll = $true
$nextFileIndex = 0

for (; $i -lt $folderEntries.Count; $i++) {
    if ((Get-Date) -gt $deadline) { $doneAll = $false; break }
    $entry = $folderEntries[$i]
    $projectPath = "$($entry.BranchPath)/$($entry.Name)"

    $emailsFolder = Invoke-GraphGetOrNull -Token $token -Uri (
        "https://graph.microsoft.com/v1.0/drives/$($entry.DriveId)/root:/" +
        "$([uri]::EscapeDataString("$projectPath/Emails") -replace '%2F','/')"
    )
    if (-not $emailsFolder) { continue }
    $scannedProjects++

    $files = Get-GraphAllPages -Token $token -Uri (
        "https://graph.microsoft.com/v1.0/drives/$($entry.DriveId)/items/$($emailsFolder.id)/children" +
        "?`$select=id,name,size&`$top=200"
    )
    $emlFiles = @($files | Where-Object { $_.name -match '(?i)\.eml$' })

    # Checked per-file too, not just per-folder, added 2026-10-21: a single busy project's worth
    # of files can take well past the deadline before the outer loop's own check is reached again
    # -- confirmed live, one call overran a 45s deadline to 90s this way. A FILE-level resume
    # cursor (resumeFileIndex), added the same day, is what actually makes this safe: a project
    # with thousands of filed emails was found live to never advance past folder-level resuming
    # alone -- every resumed call restarted peeking that same folder from its first file, hit the
    # deadline at roughly the same position, and never got further. $startFileIndex only applies
    # to the FIRST folder processed this call (the one actually being resumed into); every folder
    # reached after that starts at its own file 0 as normal.
    $startFileIndex = if ($i -eq $resumeIndex) { $resumeFileIndex } else { 0 }
    $overran = $false
    for ($fi = $startFileIndex; $fi -lt $emlFiles.Count; $fi++) {
        if ((Get-Date) -gt $deadline) { $overran = $true; $nextFileIndex = $fi; break }
        $file = $emlFiles[$fi]
        $scannedFiles++
        try {
            $peekResp = Invoke-WebRequest -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/drives/$($entry.DriveId)/items/$($file.id)/content" `
                -Headers @{ Authorization = "Bearer $token"; Range = "bytes=0-199" } -ErrorAction Stop
            if (Test-CorruptionSignature -Peek $peekResp.Content) {
                $corrupted.Add([ordered]@{
                    source       = $entry.Source
                    project      = $entry.Name
                    projectPath  = $projectPath
                    fileName     = $file.name
                    sizeBytes    = $file.size
                    driveId      = $entry.DriveId
                    itemId       = $file.id
                    emailsFolderId = $emailsFolder.id
                })
            }
        } catch {
            $peekErrors.Add([ordered]@{ project = $entry.Name; fileName = $file.name; error = $_.Exception.Message })
        }
    }
    if ($overran) { $doneAll = $false; break }
}

$body = [ordered]@{
    mode                    = "scan"
    totalProjects           = $folderEntries.Count
    projectsScannedThisCall = $scannedProjects
    filesScannedThisCall    = $scannedFiles
    corruptedFoundThisCall  = $corrupted.Count
    corrupted               = $corrupted
    peekErrors              = $peekErrors
    done                    = $doneAll
    resumeIndex             = if ($doneAll) { $null } else { $i }
    resumeFileIndex         = if ($doneAll) { $null } else { $nextFileIndex }
}
Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $body)
