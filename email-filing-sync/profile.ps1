# Runs once per Function host cold start. Deliberately does nothing eager here —
# Get-GraphAppToken (see Modules/EmailFilingSync) acquires and caches its own token
# lazily, the same check-and-reconnect shape exchange-bridge uses for Exchange Online
# sessions, since a cold-start token can't be assumed still valid several invocations
# (and therefore minutes) later.
