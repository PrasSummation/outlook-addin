using namespace System.Net

# POST /api/mailbox-permissions/revoke
# Body: { "mailbox": "<project mailbox smtp address>", "user": "<summation.au address>" }
#
# Revokes Full Access outright. Note: this does not guarantee the mailbox
# disappears from the user's Outlook immediately — Outlook only notices on
# its next Autodiscover refresh (can take hours, sometimes needs a restart),
# and removal is commonly unreliable without a follow-up manual step on the
# user's end. Surface that expectation in the UI; don't imply an instant,
# guaranteed disappearance.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$mailbox = $Request.Body.mailbox
$user = $Request.Body.user

if (-not $mailbox -or -not $user) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "Both 'mailbox' and 'user' are required."
    })
    return
}

if (-not (Test-ProjectMailboxAddress $mailbox)) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::Forbidden) -Body @{
        error = "This bridge only manages project mailboxes matching the SUPER/SUADL/ENPER/ENADL naming convention."
    })
    return
}

if (-not (Test-SummationUserAddress $user)) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::Forbidden) -Body @{
        error = "'user' must be a summation.au address."
    })
    return
}

try {
    Connect-IfNeeded
    Remove-MailboxPermission -Identity $mailbox -User $user -AccessRights FullAccess -Confirm:$false | Out-Null

    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body @{
        mailbox = $mailbox
        user    = $user
        action  = "revoked"
    })
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = $_.Exception.Message
    })
}
