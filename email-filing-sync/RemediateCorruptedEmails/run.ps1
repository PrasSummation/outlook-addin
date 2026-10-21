using namespace System.Net

# POST /api/remediate-corrupted-emails
# Body: { "mode": "scan", "resumeIndex": <int, optional> }
#
# TEMPORARY, one-off remediation helper for the "silent email-content corruption" bug (see
# EmailFilingSync.psm1/SyncEmails's own history) -- a message fetched via the old
# Invoke-RestMethod /$value call could come back as something other than a plain string or a
# strict [byte[]], and got silently stringified via PowerShell's default array-to-string join
# (each byte rendered as its decimal value, space-separated) instead of the real bytes. Confirmed
# live on an already-filed email (SUPER25060_Perth Town Hall Undercroft, dated 2026-10-20 -- ten
# days after the first, incomplete fix for this class of bug). SyncEmails/run.ps1's switch to
# Invoke-WebRequest (2026-10-21) is what stops NEW corruption; this finds already-corrupted files
# already sitting in SharePoint. A "fix" mode that actually rewrites them is a deliberate follow-up,
# not built yet -- this function is scan-only so the full list of affected files can be reviewed
# before anything gets overwritten.
#
# Remove this function (and its route) once remediation is confirmed complete -- it exists to use
# the Function App's own app-only Graph identity against both project libraries for a one-off
# job, which isn't something this app should carry around as permanent surface area.
#
# This endpoint only ever reads. Resumable: each call processes project folders starting at
# resumeIndex within a time budget (leaving margin under host.json's 9-minute functionTimeout)
# and returns the next resumeIndex to continue from, plus whatever it found in this chunk. The
# caller is responsible for merging results across calls -- this function is stateless by design
# (no blob/table state, nothing to clean up afterward beyond removing the function itself).

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
if ($mode -ne "scan") {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "Only mode: 'scan' is implemented so far. A 'fix' mode is a deliberate follow-up once scan results have been reviewed."
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

$folderEntries = Get-ProjectFolderEntries -Token $token
$deadline = (Get-Date).AddMinutes(7)
$scannedProjects = 0
$scannedFiles = 0
$corrupted = [System.Collections.Generic.List[object]]::new()
$peekErrors = [System.Collections.Generic.List[object]]::new()
$i = $resumeIndex
$doneAll = $true

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
    foreach ($file in ($files | Where-Object { $_.name -match '(?i)\.eml$' })) {
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
}
Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $body)
