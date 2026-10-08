using namespace System.Net

# GET /api/reclassify-email-batch/{batchId}
# Returns the result of a reclassify batch (written by ReclassifyEmailBatch on completion).
# Same blob-polling shape as FileEmailBatchStatus, including why this is a plain authenticated
# GET rather than a declarative blob input binding -- see that function's own comment.

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
$blobUrl = "https://$storageAccount.blob.core.windows.net/file-email-batches/reclassify-$batchId.json?$sas"

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
