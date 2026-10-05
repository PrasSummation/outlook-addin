using namespace System.Net

# POST /api/file-email-batch/{batchId}
# Body: { "graphAccessToken": "<caller's own Mail.ReadWrite+MailboxSettings.ReadWrite token>",
#         "categoryName": "<project name>", "destinationFolderId": "<'Emails to File' folder id, or omit to only categorize>",
#         "items": [ { "restId": "<Graph message id>", "subject": "<for the result log only>" }, ... ] }
#
# Exists because File Email has to run its categorize+move loop inline in the taskpane -- it
# needs live Office.js access to the current selection, so it can't use the complete-action.html
# handoff pattern the other wizards use (that page has no Office.js context at all). That means
# closing the pane, or Outlook tearing down the pane on a selection change (the default
# behavior once SupportsMultiSelect is on, unless the pane is pinned), kills the loop mid-batch
# with no way to know what actually finished. This endpoint runs the exact same categorize+move
# Graph calls the taskpane was already doing itself, but server-side: once this HTTP request is
# received, Azure Functions keeps the invocation running to completion even if the caller
# disconnects first. The result is written to blob storage once, at completion (declarative
# output bindings only write once per invocation, not incrementally as the loop progresses), so
# the taskpane never has to stay alive to see the batch through -- it just polls
# GET /api/file-email-batch/{batchId} afterward.
#
# graphAccessToken is the caller's own already-acquired, narrowly-scoped token (exactly what it
# would have used to call Graph directly from the taskpane) -- this endpoint never uses the
# bridge's own broader Exchange-admin identity, only ever what the signed-in user already had
# permission to do themselves. It's never persisted; it only lives for the duration of this
# single invocation.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$batchId = $Request.Params.batchId
$graphAccessToken = $Request.Body.graphAccessToken
$categoryName = $Request.Body.categoryName
$destinationFolderId = $Request.Body.destinationFolderId
$items = $Request.Body.items

if (-not $batchId -or -not $graphAccessToken -or -not $categoryName -or -not $items -or $items.Count -eq 0) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "batchId (route), graphAccessToken, categoryName, and a non-empty items array are all required."
    })
    return
}

$graphHeaders = @{ Authorization = "Bearer $graphAccessToken"; "Content-Type" = "application/json" }
$results = @()
$succeeded = 0
$failed = 0

foreach ($item in $items) {
    $status = $null
    $errorMessage = $null
    try {
        # Graph's PATCH replaces the whole categories array rather than merging into it, so
        # setting categories to just [categoryName] would silently wipe out anything else
        # already on the item -- confirmed, this is exactly what was happening. Read the
        # current list first and only drop an existing category that itself looks like a
        # project name (the same CODE#####_Name/-Name pattern used everywhere else in this
        # app, e.g. Test-ProjectMailboxAddress), on the assumption an item belongs to one
        # project at a time and an old project tag is being superseded, not added to. Any
        # other category -- anything a person actually set by hand -- is left alone.
        $existing = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/me/messages/$($item.restId)?`$select=categories" `
            -Headers $graphHeaders -ErrorAction Stop
        $keptCategories = @($existing.categories) | Where-Object { $_ -notmatch '^[a-zA-Z]{5}\d{5}[_-]' }
        $mergedCategories = @($keptCategories) + @($categoryName) | Select-Object -Unique

        $categorizeBody = @{ categories = @($mergedCategories) } | ConvertTo-Json
        Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/v1.0/me/messages/$($item.restId)" `
            -Headers $graphHeaders -Body $categorizeBody -ErrorAction Stop | Out-Null

        if ($destinationFolderId) {
            $moveBody = @{ destinationId = $destinationFolderId } | ConvertTo-Json
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/me/messages/$($item.restId)/move" `
                -Headers $graphHeaders -Body $moveBody -ErrorAction Stop | Out-Null
            $status = "done"
        } else {
            $status = "categorized-not-staged"
        }
        $succeeded++
    } catch {
        $status = "failed"
        $errorMessage = $_.Exception.Message
        # Invoke-RestMethod's own exception message is just the HTTP status line (e.g.
        # "Response status code does not indicate success: 404 (Not Found)."), not Graph's
        # actual error body -- but PowerShell 7's web cmdlets still capture that body in
        # ErrorDetails.Message. Prefer Graph's own code/message (e.g. "ErrorItemNotFound")
        # when it parses, so the client can tell "this item is just gone" apart from any
        # other failure instead of only ever seeing a generic HTTP status.
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $graphError = ($_.ErrorDetails.Message | ConvertFrom-Json).error
                if ($graphError -and $graphError.code) {
                    $errorMessage = "$($graphError.code): $($graphError.message)"
                }
            } catch {
                # Response body wasn't JSON, or didn't have the expected shape -- keep the
                # generic exception message already captured above.
            }
        }
        $failed++
    }
    $results += [ordered]@{
        subject = $item.subject
        restId  = $item.restId
        status  = $status
        error   = $errorMessage
    }
}

$batchResult = [ordered]@{
    batchId      = $batchId
    categoryName = $categoryName
    total        = $items.Count
    succeeded    = $succeeded
    failed       = $failed
    status       = "done"
    completedAt  = (Get-Date).ToUniversalTime().ToString("o")
    items        = $results
}

Push-OutputBinding -Name BatchBlob -Value ($batchResult | ConvertTo-Json -Depth 6)
Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $batchResult)
