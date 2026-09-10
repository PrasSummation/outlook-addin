# Runs once per Function host cold start. Deliberately does nothing eager here —
# each function calls Connect-IfNeeded (see Modules/MailboxBridge) itself, since
# Exchange Online sessions can go stale on a warm instance and a lazy
# check-and-reconnect is more robust than assuming a cold-start connection is
# still good several invocations later.
