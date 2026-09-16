using namespace System.Net

# POST /api/shared-mailboxes
# Body: { "mailbox": "<project mailbox smtp address>", "displayName": "<human-readable name>" }
#
# Creates a real Exchange shared mailbox via New-Mailbox -Shared. This exists because the
# previous approach — creating a bare Graph user object (POST /users) and waiting for
# Exchange to "provision" a mailbox for it — does not actually happen in this tenant. A
# mailbox created that way was found completely unrecognized by Exchange (not even as a
# generic recipient) two full days later. New-Mailbox -Shared creates a real, immediately
# usable mailbox directly, with no such wait.
#
# Returns 409 (not an error) if a recipient with this address already exists, so the caller
# can treat "already exists" as "proceed to granting members" rather than a failure.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$mailbox = $Request.Body.mailbox
$displayName = $Request.Body.displayName

if (-not $mailbox -or -not $displayName) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "Both 'mailbox' and 'displayName' are required."
    })
    return
}

if (-not (Test-ProjectMailboxAddress $mailbox)) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::Forbidden) -Body @{
        error = "This bridge only manages project mailboxes matching the SUPER/SUADL/ENPER/ENADL naming convention."
    })
    return
}

$alias = ($mailbox -split "@")[0]

try {
    Connect-IfNeeded

    $existing = Get-Recipient -Identity $mailbox -ErrorAction SilentlyContinue
    if ($existing) {
        Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::Conflict) -Body @{
            mailbox = $mailbox
            error   = "A recipient with this address already exists."
        })
        return
    }

    $mbx = New-Mailbox -Shared -Name $alias -DisplayName $displayName -PrimarySmtpAddress $mailbox -ErrorAction Stop

    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body @{
        mailbox     = $mbx.PrimarySmtpAddress.ToString()
        displayName = $mbx.DisplayName
        action      = "created"
    })
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = $_.Exception.Message
    })
}
