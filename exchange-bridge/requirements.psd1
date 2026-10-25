@{
    # Deliberately empty (2026-10-24): ExchangeOnlineManagement used to be declared here as a
    # managed dependency, but managedDependency.enabled (host.json) makes Azure eagerly import
    # every module listed here into the shared runspace on EVERY cold start of this app -- app
    # wide, regardless of which function actually gets invoked. That's a real cost: it's one of
    # the heavier PowerShell modules to import, and only 4 of this app's functions
    # (Grant/RevokeMailboxPermission, GetMailboxPermissions, CreateSharedMailbox, via
    # Connect-IfNeeded) ever use it -- FileEmailBatch/FileEmailBatchStatus, the hot path for the
    # Outlook add-in's "Save" flows, never touch Exchange Online PowerShell at all. The module is
    # now vendored directly under Modules/ExchangeOnlineManagement instead (see that folder's own
    # note, and Modules/.gitignore), which makes it available on PSModulePath for Connect-IfNeeded's
    # own explicit Import-Module call, but only loaded on demand -- not eagerly for every cold
    # start regardless of which function is invoked.
}
