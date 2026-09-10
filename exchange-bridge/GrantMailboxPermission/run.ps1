using namespace System.Net

# POST /api/mailbox-permissions/grant
# Body: { "mailbox": "<project mailbox smtp address>", "user": "<summation.au address>" }
#
# Grants Full Access with AutoMapping on, so the mailbox appears automatically
# in the target user's Outlook next time it refreshes Autodiscover.

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
    Add-MailboxPermission -Identity $mailbox -User $user -AccessRights FullAccess -AutoMapping $true -Confirm:$false | Out-Null

    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body @{
        mailbox = $mailbox
        user    = $user
        action  = "granted"
    })
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = $_.Exception.Message
    })
}
