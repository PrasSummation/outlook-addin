# Run ONCE, interactively, by an Exchange Administrator or Global Administrator,
# connecting with YOUR OWN admin credentials — not the app-only bridge identity.
# This sets up the narrow role and scope the bridge's app-only identity will be
# assigned to, so that identity can only ever touch project mailboxes and can
# only ever manage Full Access permissions, nothing broader.
#
# Review and test the RecipientRestrictionFilter syntax below in your own tenant
# before running for real — Exchange filter syntax is fussy and this hasn't been
# run against a live tenant from here.

Connect-ExchangeOnline -UserPrincipalName "<your-admin-upn>@summationptyltd.onmicrosoft.com"

# 1. A management scope limited to project mailboxes only (SUPER/SUADL/ENPER/ENADL
#    naming convention), so the role assignment below can never reach any other
#    mailbox in the tenant even if broadened by mistake later.
New-ManagementScope -Name "SummationProjectMailboxes" `
    -RecipientRestrictionFilter "(Alias -like 'SUPER*') -or (Alias -like 'SUADL*') -or (Alias -like 'ENPER*') -or (Alias -like 'ENADL*')"

# 2. A custom role containing only the three cmdlets this bridge needs, cloned
#    from the built-in "Mail Recipients" role (where those cmdlets live) and
#    then trimmed down.
New-ManagementRole -Name "SummationMailboxPermissionManager" -Parent "Mail Recipients"

Get-ManagementRoleEntry "SummationMailboxPermissionManager\*" |
    Where-Object { $_.Name -notin @("Get-MailboxPermission", "Add-MailboxPermission", "Remove-MailboxPermission") } |
    ForEach-Object { Remove-ManagementRoleEntry $_.Identity -Confirm:$false }

# 3. Assign the role, scoped to project mailboxes only, to the app-only identity.
#    <bridge-app-id> is the client ID of the SEPARATE "Summation Exchange Bridge"
#    app registration created for this backend — never the "Summation Assistant"
#    sign-in app the taskpane's users authenticate against.
New-ManagementRoleAssignment -App "<bridge-app-id>" `
    -Role "SummationMailboxPermissionManager" `
    -CustomRecipientWriteScope "SummationProjectMailboxes"

# Verify:
# Get-ManagementRoleAssignment -App "<bridge-app-id>"
