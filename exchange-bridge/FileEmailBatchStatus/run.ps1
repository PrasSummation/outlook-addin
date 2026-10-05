using namespace System.Net

# GET /api/file-email-batch/{batchId}
# Returns the result of a File Email batch (written by FileEmailBatch on completion).
#
# Reads the blob via a plain authenticated GET using a read-only SAS token scoped to just the
# file-email-batches container (FILE_EMAIL_BATCH_STORAGE_ACCOUNT / FILE_EMAIL_BATCH_CONTAINER_SAS
# app settings), rather than a declarative blob input binding. A declarative input binding
# fails the entire function invocation outright if the blob doesn't exist yet (confirmed Azure
# Functions behavior) -- which would make "batch still running, nothing written yet" look
# identical to a real platform error. A plain REST GET lets this code tell the two apart and
# return a specific, clean response either way, instead of a generic failure.
#
# The blob already holds a complete, valid JSON document (written by FileEmailBatch), so its
# content is passed straight through as the response body rather than round-tripped through
# New-JsonResponse's ConvertTo-Json -- re-serializing an already-serialized JSON string would
# double-encode it.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$batchId = $Request.Params.batchId
if (-not $batchId) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "batchId is required in the route."
    })
    return
}

$storageAccount = $env:FILE_EMAIL_BATCH_STORAGE_ACCOUNT
$sas = $env:FILE_EMAIL_BATCH_CONTAINER_SAS
$blobUrl = "https://$storageAccount.blob.core.windows.net/file-email-batches/$batchId.json?$sas"

try {
    $response = Invoke-WebRequest -Method Get -Uri $blobUrl -ErrorAction Stop
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ "Content-Type" = "application/json" }
        Body       = $response.Content
    })
} catch {
    $statusCode = $null
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    if ($statusCode -eq 404) {
        Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::NotFound) -Body @{
            batchId = $batchId
            status  = "not_found"
            note    = "No result yet for this batch -- it may still be running, or the batchId may be wrong."
        })
    } else {
        Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
            error = $_.Exception.Message
        })
    }
}
