# Exchange Online bridge

A small Azure Function that does the three things Microsoft Graph cannot do at
all: list, grant, and revoke **Full Access** permission on a project shared
mailbox. This is what unblocks:

- Reviewing/managing who has access to a shared mailbox
- A real "un-map from Outlook" step when converting a project from Active to Archive
- The planned "Manage Outlook Shared Mailboxes" two-pane UI

Nothing in `taskpane.html` calls this yet — that's a deliberate next step once
this is deployed and tested on its own.

## Why this exists

Microsoft Graph has no API for Exchange mailbox permissions or AutoMapping —
none of it is exposed outside Exchange Online PowerShell
(`Get/Add/Remove-MailboxPermission`). Those cmdlets need an Exchange Online
PowerShell session, which needs a real identity behind it. This Function *is*
that identity's home: it holds the one credential capable of running those
cmdlets, and everything else (the taskpane, any future page) just calls it
over HTTPS instead of needing Exchange access itself.

## Architecture — two separate app registrations, on purpose

**This is the part most likely to get quietly merged into one thing if rushed
— don't.** They serve different trust levels:

1. **"Summation Assistant"** (already exists, client ID
   `80497ed0-ecd5-475e-97e0-5c9e90fb8a0d`) — the public, browser-facing sign-in
   app the taskpane already uses via MSAL. To call this bridge, it needs one
   addition: an **exposed API scope** (e.g. `api://80497ed0-.../MailboxBridge.Call`)
   that the taskpane requests like any other incremental-consent scope (same
   pattern as `Sites.Selected`), then sends as the Bearer token to the Function.
   This identifies *which signed-in Summation user* is calling.

2. **"Summation Exchange Bridge"** (new, to be created) — an app-only,
   **certificate-based** identity used exclusively by the Function's server-side
   code to authenticate to Exchange Online. It has the `Exchange.ManageAsApp`
   application permission and an Exchange RBAC role (see below), and its
   certificate's private key lives only in the Function App's own certificate
   store — never in any client-side code, never in this repo.

   This separation matters because `taskpane.html` is served from public
   GitHub Pages — its full source is readable by anyone. Any credential capable
   of running Exchange cmdlets tenant-wide must never be reachable from that
   file. The two app registrations keep "who's allowed to ask" (delegated,
   public, per-user) completely separate from "who's allowed to act"
   (app-only, private, one shared service identity).

```
Taskpane (MSAL token for "Summation Assistant" scope)
   │  HTTPS + Bearer token
   ▼
Azure Function  ──[App Service Authentication validates the token]──┐
   │ (only if valid)                                                │
   │ uses its OWN cert-based "Summation Exchange Bridge" identity    │
   ▼                                                                 │
Exchange Online PowerShell (Get/Add/Remove-MailboxPermission) ◄──────┘
```

## Least privilege on the Exchange side

Rather than assigning the bridge identity a broad role like Exchange
Administrator, `setup-exchange-rbac.ps1` creates:

- A **custom management role** cloned from the built-in "Mail Recipients"
  role, then trimmed to exactly three cmdlets: `Get-MailboxPermission`,
  `Add-MailboxPermission`, `Remove-MailboxPermission`.
- A **management scope** restricting that role to mailboxes matching the
  `SUPER*`/`SUADL*`/`ENPER*`/`ENADL*` naming convention.

So even in the worst case (the certificate is somehow compromised), this
identity cannot touch anyone's personal mailbox, cannot do anything to
recipients outside the project-mailbox naming convention, and cannot run any
cmdlet beyond those three.

The Function code adds a second, redundant layer of the same check
(`Test-ProjectMailboxAddress` / `Test-SummationUserAddress` in
`Modules/MailboxBridge/MailboxBridge.psm1`) so a bug in the Exchange-side scope
isn't the only thing standing between this and touching the wrong mailbox.

## API contract

| Method | Route | Body / Query | Returns |
|---|---|---|---|
| `GET` | `/api/mailbox-permissions?mailbox=<smtp>` | — | `{ mailbox, members: [{ user, accessRights, isInherited }] }` |
| `POST` | `/api/mailbox-permissions/grant` | `{ mailbox, user }` | `{ mailbox, user, action: "granted" }` |
| `POST` | `/api/mailbox-permissions/revoke` | `{ mailbox, user }` | `{ mailbox, user, action: "revoked" }` |

Every endpoint rejects (`403`) any `mailbox` that doesn't match the project
naming convention and any `user` that isn't a `summation.au` address, before
touching Exchange at all.

**Note on AutoMapping:** `Get-MailboxPermission` doesn't return a clean
AutoMapping on/off flag — that state lives in an AD attribute the cmdlet
doesn't surface. Treat the `members` list as "who currently has Full Access
(and is very likely auto-mapped)," not a guaranteed AutoMapping status.

**Note on revoke:** removing Full Access doesn't reliably make the mailbox
disappear from the target user's Outlook right away — Outlook only notices on
its next Autodiscover refresh, and community reports say this is often
unreliable without the user manually removing it. Whatever UI calls this
endpoint should say "access has been revoked; they may need to remove it from
their own Outlook if it lingers," not promise instant disappearance.

## One-time setup runbook

1. **Create the Azure subscription** (Pay-As-You-Go is fine — no resources
   deployed yet means no cost).
2. **Create the "Summation Exchange Bridge" app registration** in Entra ID:
   - No redirect URI, no delegated permissions.
   - API permissions → add → the "Office 365 Exchange Online" API → Application
     permissions → `Exchange.ManageAsApp` → grant admin consent.
   - Generate a certificate (`New-SelfSignedCertificate` or a real CA-issued
     one) and upload the **public** half to this app registration's
     Certificates & secrets. Keep the private half for step 5.
3. **Add an exposed API scope to the existing "Summation Assistant" app
   registration** (e.g. `MailboxBridge.Call`), so the taskpane can request a
   token for it via MSAL the same way it already requests `Sites.Selected`.
4. **Run `setup-exchange-rbac.ps1`** — connect as a real Exchange/Global admin
   and create the scoped custom role, then assign it to the Exchange Bridge
   app's client ID.
5. **Create the Function App** (Consumption plan, PowerShell runtime):
   - Deploy this folder's contents to it.
   - Upload the certificate's private half (`.pfx`) to the Function App's
     Certificates blade; set `WEBSITE_LOAD_CERTIFICATES` and
     `EXO_CERT_THUMBPRINT` to its thumbprint.
   - Set `EXO_APP_ID` to the Exchange Bridge app's client ID, `EXO_ORGANIZATION`
     to `summationptyltd.onmicrosoft.com`.
   - Enable **App Service Authentication** (Easy Auth), configured to require
     a valid Entra ID token whose audience matches the `MailboxBridge.Call`
     scope from step 3. This is what actually protects every route — the
     `"authLevel": "anonymous"` in each `function.json` is intentional and only
     safe because Easy Auth enforces authentication before a request ever
     reaches the function code. Skipping this step leaves the bridge open to
     the internet.
6. **Test each endpoint directly** (e.g. via `curl` with a token acquired
   through the Entra ID device-code flow) before wiring the taskpane to it.

## Cost

Consumption plan: 1,000,000 free executions + 400,000 GB-seconds free per
month, per subscription — shared across everything in that subscription, not
per user. At this feature's expected volume (occasional clicks from a small
team), realistic expected cost is **$0/month**, plus fractions of a cent for
the required linked Storage Account. See [Azure Functions
pricing](https://azure.microsoft.com/en-us/pricing/details/functions/).

## What's still needed after this is deployed

- Wire `taskpane.html` to actually call these three endpoints (not done —
  deliberately held back until this bridge is live and tested standalone).
- Decide the UI for "Manage Outlook Shared Mailboxes" (the two-pane layout
  already discussed) and the un-mapping step in Convert Active to Archive.
- Optional: turn on Application Insights on the Function App for an audit
  trail of who granted/revoked what and when.
