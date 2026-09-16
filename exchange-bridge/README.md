# Exchange Online bridge

**Status: deployed and in active use (last updated 2026-09-17).** Live at
`https://summation-exchange-bridge-e6e5gsendkdxdwf5.australiaeast-01.azurewebsites.net`,
in resource group `summation-exchange-bridge-rg`. `taskpane.html`,
`manage-mailboxes.html`, `manage-shared-mailbox-members.html`, and
`manage-mailbox-automapping.html` all call it now — the two-pane UI, the bulk
member-add wizard, mailbox creation, and the automapping reconciliation page
are all real, shipped features, not just planned ones.

A small Azure Function that does the things Microsoft Graph cannot do at all:
list, grant, and revoke **Full Access** permission on a project shared
mailbox, and — as of 2026-09-17 — actually **create** one. The creation
endpoint exists because the original approach (a bare Graph `POST /users`
call, assuming Exchange would provision a mailbox for it on its own) turned
out not to work in this tenant at all: one such mailbox sat completely
unrecognized by Exchange — not even as a generic recipient — two full days
after creation. `New-Mailbox -Shared` creates a real, immediately usable
mailbox directly, with no such wait.

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

1. **"Summation Outlook Add-in"** (already exists, client ID
   `80497ed0-ecd5-475e-97e0-5c9e90fb8a0d`; branded "Summation Assistant" in the
   taskpane UI, but that's just its display name there) — the public,
   browser-facing sign-in app the taskpane already uses via MSAL. It now has
   an **exposed API scope**, `api://80497ed0-.../MailboxBridge.Call`, that the
   taskpane requests like any other incremental-consent scope (same pattern as
   `Sites.Selected`), then sends as the Bearer token to the Function. This
   identifies *which signed-in Summation user* is calling.

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

## Least privilege on the Exchange side — plan vs. reality

The original design (and `setup-exchange-rbac.ps1`, still present) tried to
avoid assigning the bridge identity a broad role like Exchange Administrator,
by creating:

- A **custom management role** cloned from the built-in "Mail Recipients"
  role, then trimmed to exactly three cmdlets: `Get-MailboxPermission`,
  `Add-MailboxPermission`, `Remove-MailboxPermission`.
- A **management scope** restricting that role to mailboxes matching the
  `SUPER*`/`SUADL*`/`ENPER*`/`ENADL*` naming convention.
- `New-ManagementRoleAssignment -App <id> -Role <role> -CustomResourceScope <scope>`
  to assign that scoped role to the bridge's service principal.

**This doesn't actually work for this authentication flow.** Exchange
Online's app-only `Connect-ExchangeOnline -AppId -CertificateThumbprint` login
doesn't support fine-grained delegation the way Microsoft Graph does — it's
enforced as all-or-nothing, and requires the service principal to hold the
actual Entra ID **Exchange Administrator** directory role. A custom-scoped
Exchange management role assignment doesn't satisfy that check at all (it
fails with "the role assigned to application ... isn't supported in this
scenario"). This was confirmed both by direct testing and by Microsoft
support threads describing the same limitation.

So the bridge's service principal is assigned the full **Exchange
Administrator** directory role (Entra ID → Roles & admins → Exchange
Administrator → assignments), which grants it broad rights across all of
Exchange Online (mail flow rules, connectors, retention, every mailbox — not
just Full Access management), tenant-wide. This is a real, accepted trade-off,
not an oversight — see the discussion that led to it for the full reasoning.

The custom role (`SummationMailboxPermissionManager`) and scope
(`SummationProjectMailboxes`) created by `setup-exchange-rbac.ps1` are now
**inert leftover configuration** — harmless, but not doing anything, since
they were never successfully assigned to the app before this was discovered.
Worth deleting at some point for clarity (`Remove-ManagementRoleAssignment`,
`Remove-ManagementRole`, `Remove-ManagementScope`), not urgent.

**What actually keeps the blast radius narrow, given the broader credential:**

- The Function code's own validation (`Test-ProjectMailboxAddress` /
  `Test-SummationUserAddress` in `Modules/MailboxBridge/MailboxBridge.psm1`)
  still means the bridge itself only ever calls the three intended cmdlets on
  project-pattern mailboxes — as long as nobody changes that code.
- The certificate's private key is never reachable from any public-facing
  code — only from the Function App's own certificate store.
- Easy Auth (see below) means only tokens issued to the taskpane app, for
  signed-in Summation users, in Summation's own tenant, can reach the
  endpoints at all — there's no anonymous path to triggering anything.
- The security boundary is therefore "trust the Function code + who has
  Azure access to change it," not "Exchange enforces the limit" — a strictly
  weaker guarantee than originally designed, worth remembering if this bridge
  is ever extended to do more than these three actions.

## API contract

| Method | Route | Body / Query | Returns |
|---|---|---|---|
| `GET` | `/api/mailbox-permissions?mailbox=<smtp>` | — | `{ mailbox, members: [{ user, accessRights, isInherited }] }` |
| `POST` | `/api/mailbox-permissions/grant` | `{ mailbox, user, autoMapping? }` (autoMapping defaults to `true`; every client in this repo now passes `false` explicitly — automapping-off is the house default) | `{ mailbox, user, action: "granted", autoMapping }` |
| `POST` | `/api/mailbox-permissions/revoke` | `{ mailbox, user }` | `{ mailbox, user, action: "revoked" }` |
| `POST` | `/api/shared-mailboxes` | `{ mailbox, displayName }` | `200` `{ mailbox, displayName, action: "created" }`, or `409` `{ mailbox, error }` if a recipient with that address already exists (not treated as a failure by any client — they proceed to granting members) |

Every endpoint rejects (`403`) any `mailbox` that doesn't match the project
naming convention (`^[a-zA-Z]{5}\d{5}[_-].+@summation\.au$` — broadened in
2026-09-16 to accept a hyphen as well as the original underscore, after real
export data turned up legacy mailboxes using "CODE - Name") and any `user`
that isn't a `summation.au` address, before touching Exchange at all.

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

## One-time setup runbook (as actually completed)

1. ✅ **Azure subscription** created (`Summation Exchange Bridge`, Microsoft
   Azure Plan, billed to Summation Pty Ltd's own billing account).
2. ✅ **"Summation Exchange Bridge" app registration** created in Entra ID
   (client ID `0b1fee8e-5157-4234-8a96-b8fb981aa1b1`), single-tenant, no
   redirect URI. Certificate generated locally
   (`New-SelfSignedCertificate`, thumbprint
   `1CEFB4F1B21952E56CE35F7B08992DEB9385D86F`), public half uploaded to the
   app registration's Certificates & secrets. `Exchange.ManageAsApp`
   application permission added and admin-consented.
3. ✅ **Exposed an API scope on the existing "Summation Outlook Add-in" app
   registration** (client ID `80497ed0-ecd5-475e-97e0-5c9e90fb8a0d` — this is
   the app the taskpane signs in with; "Summation Assistant" is just its
   taskpane branding, not its Entra display name). Scope:
   `api://80497ed0-ecd5-475e-97e0-5c9e90fb8a0d/MailboxBridge.Call`, consent
   type "Admins and users".
4. ⚠️ **`setup-exchange-rbac.ps1` was run but turned out insufficient** — see
   "Least privilege on the Exchange side" above. What actually had to be done
   instead: assign the bridge's service principal the **Exchange
   Administrator** directory role (Entra ID → Roles & admins → Exchange
   Administrator → Add assignments → "Summation Exchange Bridge").
5. ✅ **Function App created**: `summation-exchange-bridge`, Consumption
   (Windows), PowerShell 7.6, Australia East, Application Insights enabled,
   resource group `summation-exchange-bridge-rg`. Basic authentication is
   disabled on it (the secure default), so deployment used Azure CLI
   (`az functionapp deployment source config-zip`, authenticated via `az
   login`) rather than a publish-profile/FTP method.
   - Code deployed from this folder; all three functions confirmed present
     (`GetMailboxPermissions`, `GrantMailboxPermission`,
     `RevokeMailboxPermission`) at their expected routes.
   - Certificate's private half (`.pfx`) uploaded via the Function App's
     Certificates blade.
   - App settings set: `EXO_APP_ID`, `EXO_ORGANIZATION`
     (`summationptyltd.onmicrosoft.com`), `EXO_CERT_THUMBPRINT`,
     `WEBSITE_LOAD_CERTIFICATES` (same thumbprint).
   - **App Service Authentication (Easy Auth) enabled**: Microsoft provider,
     existing app registration "Summation Outlook Add-in", client application
     requirement "Allow requests only from this application itself", tenant
     requirement restricted to Summation's own tenant, "Require
     authentication" with unauthenticated requests returning 401. Note this
     flow generates a client secret on the "Summation Outlook Add-in" app
     registration, stored only in the Function App's own configuration —
     this doesn't affect or get used by the taskpane's own public/PKCE MSAL
     sign-in flow.
6. ✅ **Tested directly** (before touching the taskpane at all): a full
   grant → verify → revoke → verify round trip against a real project
   mailbox left no lasting change, and an anonymous request after enabling
   Easy Auth correctly returned 401.

## Cost

Consumption plan: 1,000,000 free executions + 400,000 GB-seconds free per
month, per subscription — shared across everything in that subscription, not
per user. At this feature's expected volume (occasional clicks from a small
team), realistic expected cost is **$0/month**, plus fractions of a cent for
the required linked Storage Account. See [Azure Functions
pricing](https://azure.microsoft.com/en-us/pricing/details/functions/).

## What's still needed

- Optional cleanup: delete the inert `SummationMailboxPermissionManager`
  custom role and `SummationProjectMailboxes` scope (see above).
- Application Insights is already enabled on the Function App — worth
  checking its logs periodically to confirm grant/revoke/create actions are
  showing up as expected for audit purposes.
- The `CreateSharedMailbox` function's `-Name` parameter is the mailbox's
  local-part alias (no spaces); `-DisplayName` carries the human-readable
  name. Worth a periodic sanity check that `Get-Recipient` pre-checks are
  still catching real conflicts cleanly — the very first live test hit a
  transient Exchange directory-replication lag (a just-deleted account's
  address briefly still refused as "in use" by `New-Mailbox`, even though
  Azure AD and Exchange's own recipient search both already showed it gone)
  that resolved itself on a simple retry a short time later.
