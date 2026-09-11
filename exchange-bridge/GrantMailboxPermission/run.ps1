using namespace System.Net

# POST /api/mailbox-permissions/grant
# Body: { "mailbox": "<project mailbox smtp address>", "user": "<summation.au address>", "autoMapping": <bool, optional, default true> }
#
# Grants Full Access. AutoMapping defaults to true (mailbox appears automatically
# in the target user's Outlook next time it refreshes Autodiscover) but can be set
# false to grant access without it being auto-added — useful for someone who wants
# to add the mailbox manually or keep their own folder pane uncluttered.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$mailbox = $Request.Body.mailbox
$user = $Request.Body.user
$autoMapping = $true
if ($null -ne $Request.Body.autoMapping) {
    $autoMapping = [bool]$Request.Body.autoMapping
}

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
    Add-MailboxPermission -Identity $mailbox -User $user -AccessRights FullAccess -AutoMapping $autoMapping -Confirm:$false | Out-Null

    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body @{
        mailbox     = $mailbox
        user        = $user
        action      = "granted"
        autoMapping = $autoMapping
    })
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = $_.Exception.Message
    })
}
