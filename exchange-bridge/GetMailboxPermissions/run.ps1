using namespace System.Net

# GET /api/mailbox-permissions?mailbox=<smtp address>
# Returns the current Full Access grants on a project mailbox.
#
# Note on "AutoMapping": Get-MailboxPermission does not return a clean
# AutoMapping boolean — that state lives in an internal AD attribute Exchange
# doesn't surface via this cmdlet. Treat every entry returned here as "has
# Full Access, and is very likely auto-mapped unless someone specifically
# disabled it" rather than a guaranteed automapping status.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/MailboxBridge/MailboxBridge.psm1" -Force

$mailbox = $Request.Query.mailbox

if (-not $mailbox) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::BadRequest) -Body @{
        error = "Missing 'mailbox' query parameter."
    })
    return
}

if (-not (Test-ProjectMailboxAddress $mailbox)) {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::Forbidden) -Body @{
        error = "This bridge only manages project mailboxes matching the SUPER/SUADL/ENPER/ENADL naming convention."
    })
    return
}

try {
    Connect-IfNeeded

    $members = Get-MailboxPermission -Identity $mailbox |
        Where-Object { $_.User -notlike "NT AUTHORITY\SELF" -and $_.AccessRights -contains "FullAccess" -and -not $_.Deny } |
        ForEach-Object {
            @{
                user         = $_.User.ToString()
                accessRights = @($_.AccessRights)
                isInherited  = [bool]$_.IsInherited
            }
        }

    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body @{
        mailbox = $mailbox
        members = @($members)
    })
} catch {
    Push-OutputBinding -Name Response -Value (New-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) -Body @{
        error = $_.Exception.Message
    })
}
