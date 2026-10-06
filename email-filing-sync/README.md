# Email filing sync

**Status: code written, infrastructure not yet provisioned (started 2026-10-05).** Not
deployed. Nothing in this folder has run against a real mailbox yet.

A second, independent Azure Function App — timer-triggered, no HTTP surface at all —
that watches every staff member's own **"Emails to File"** Outlook folder (the same
folder File Email's "Confirm" step already categorizes-and-stages emails into, in
`taskpane.html`) and finishes the job: for each staged email, it resolves the project
from its Outlook category, saves the email as `.eml` into that project's SharePoint
`Emails` folder (created if missing), adds `Filed` on top of whatever category it already
had (the original project category is left exactly as the user set it — see the fix note
below), and moves it into a local **"Filed"** folder. It runs unattended, continuously,
with no add-in or browser tab needing to be open.

This implements the background-sync design agreed over several prior sessions (see
`Brief - SharePoint Email Filing (Newforma-style).md`, decisions in its §9), reconciled
against a later, more detailed **email index** requirements doc
(`https://claude.ai/code/artifact/c5ae8342-25e5-4f53-ae43-fbfa175d978d` — the index
itself lives in the separate private repo `PrasSummation/email-index`, not here). Where
the two disagreed, the index doc won — see "Deviations from the original brief" below.

## Why a third Function App, a third app registration

This repo now has three separate trust boundaries, each narrower than the one before it,
on purpose:

| | "Summation Outlook Add-in" | "Summation Exchange Bridge" | "Summation Email Filing Sync" (this one, **to be created**) |
|---|---|---|---|
| Used by | The taskpane, browser-side, per signed-in user | `exchange-bridge/`, server-side only | `email-filing-sync/`, server-side only |
| Auth model | Public client, MSAL/PKCE, delegated | App-only, certificate | App-only, certificate |
| What it can do | Whatever the signed-in user themselves can do in Graph | Exchange Online cmdlets (Full Access grant/revoke, mailbox creation) — all-or-nothing, Exchange Administrator role | Graph `Mail.ReadWrite` app-only across **staff mailboxes only** (Exchange Application Access Policy-scoped) + `Sites.Selected` on the two Hub sites |
| Where the credential lives | N/A (public client, no secret) | This Function App's own cert store only | This Function App's own cert store only |

Reusing the Exchange Bridge's own app registration/certificate for this was explicitly
ruled out (brief §5, §8: "do not modify the Exchange Bridge's resources, app
registration or certificates"). This tool has no reason to ever hold
`Exchange.ManageAsApp` / Exchange Administrator — it only ever needs Graph, not Exchange
Online PowerShell — so giving it its own narrower app registration also means it never
inherits that bridge's much broader blast radius.

## Architecture

```
Timer (every 5 min)
  └─ SyncEmails Function, per staff mailbox:
        │  app-only Graph token (cert, client-credentials, "Summation Email Filing Sync")
        ▼
     /users (app-only)                 -- enumerate staff, same filter as
                                           complete-action.html's getAllStaffMembers()

     -- Sent Items pass (File on Send), runs first, independent of the pass below --
     /users/{upn}/mailFolders/sentitems/messages?sentDateTime ge <now-3h>
        -- categorized-but-not-"Filed" sent mail (tagged pre-send by the taskpane's
           File on Send dialog, via Office.js categories.addAsync -- there's no
           "stage it first" step possible for an outgoing message)
     drives/{ACTIVE|ARCHIVE_DRIVE_ID}/...           -- resolve/create <project>/Emails
     /users/{upn}/messages/{id}/$value              -- fetch raw .eml
     drives/.../items/{emailsFolderId}:/{name}:/content  -- upload
     /users/{upn}/messages/{id} (PATCH categories)  -- tag Filed, left IN PLACE (not moved --
                                                        nobody wants their own Sent folder
                                                        emptied out by automation)

     -- "Emails to File" pass (received mail, staged by File Email or auto-move-on-filing) --
     /users/{upn}/mailFolders/inbox/childFolders?displayName eq 'Emails to File'
     /users/{upn}/mailFolders/{id}/messages        -- read staged, categorized emails
     drives/{ACTIVE|ARCHIVE_DRIVE_ID}/...           -- resolve/create <project>/Emails
     /users/{upn}/messages/{id}/$value              -- fetch raw .eml
     drives/.../items/{emailsFolderId}:/{name}:/content  -- upload
     /users/{upn}/messages/{id} (PATCH categories)  -- add Filed, keep the original category as-is
     /users/{upn}/messages/{id}/move                -- move into "Filed"
        │
        ▼ (best-effort, non-blocking, both passes)
     POST {EMAIL_INDEX_BASE_URL}/api/emails          -- notify the index, if reachable
```

### The Sent Items pass (File on Send), added 2026-10-06

Filing a sent reply can't happen the same way as filing a received email: there's no
item to tag-and-stage before the user hits Send (a reply/new message doesn't exist as a
real, Graph-addressable item until Outlook finishes sending it), and there's no
Office.js/Graph access at all inside the dialog that actually prompts for a project
(`file-on-send-dialog.html`, opened from `commands.js`'s `onMessageSendHandler` — dialogs
opened via `displayDialogAsync` get no `Office.context.mailbox`). So the taskpane side
only ever *categorizes* the outgoing item (`Office.context.mailbox.item.categories.addAsync`,
run from the `OnMessageSend` handler, before `event.completed()`); this Function App is
what actually files it, afterward, once it's a real sent message.

Consequences worth knowing:
- **A 3-hour lookback window** (`sentDateTime ge <now-3h>`), not a staging folder —
  there's nothing to stage. Wide enough to tolerate a missed run or two without
  needing a backfill; a message that's somehow still unfiled after 3 hours just won't
  be picked up automatically and needs a manual look.
- **Sent items are never moved.** The Inbox pass empties out "Emails to File" on
  purpose (that's the whole point of staging); nobody wants their own *Sent* folder
  silently rearranged, so this pass only tags `Filed` onto the existing message in place.
- **"File the original" (the "Save Both" option in the dialog) does not go through this
  Function App at all** — it's a direct, synchronous call from the dialog itself to the
  Exchange bridge's existing `FileEmailBatch` endpoint (the exact one `taskpane.html`'s
  File Email already uses), found via a `conversationId` search since there's no direct
  API for "the message I'm replying to" from a compose item. That part is immediate
  (same categorize+move-to-"Emails to File" as a manual File Email), not something this
  timer needs to pick up later.

Each mailbox, and each email within it, is wrapped so one failure doesn't stop the rest
of the run — a `Write-Error` plus a per-run totals line (`EmailFilingSync: run complete.
{...}`) is the only reporting surface, since there is no UI and no user watching this
happen in real time. Check Application Insights traces/exceptions (**note:** this
repo's other Function App, `exchange-bridge`, was found to have zero telemetry
reaching App Insights despite real invocations, during an unrelated investigation on
2026-10-05 — confirm this one's traces are actually arriving before relying on them for
anything time-sensitive).

## Deviations from the original brief

The project's `Brief - SharePoint Email Filing (Newforma-style).md` (§9, "confirmed by
Pras 2026-10-05") said an `Email` (singular) subfolder. The later email-index
requirements doc makes `Emails` (plural) a hard `Must` — its folder-path parsing looks
for a path segment named exactly `Emails`, with no singular fallback. Asked directly,
Pras chose **`Emails` (plural)** on 2026-10-05, so the index can actually find what this
tool files. This is the decision this code follows; the original brief's §9 point 2 and
§5 "Storage design" section are superseded by this on that one point.

The original brief's "Storage design (SharePoint)" section (metadata columns, a
"Project Email" site content type, `PATCH listItem/fields`) is **not implemented, and
not planned** — the index doc's design does all of that work itself, reading structured
fields out of the `.eml` file (and, optionally, the `POST /api/emails` call) rather than
SharePoint list columns. Implementing both would mean keeping two separate metadata
stores in sync for no benefit.

## Fixed: category rewrite on filing (2026-10-06)

The Inbox ("Emails to File") pass used to strip any project-shaped category off a message
before re-tagging it — e.g. a message categorized `SUPER26007_ProjectName` came out the
other side as just `SUPER26007` plus `Filed`, silently discarding the project-name part of
whatever label the user (or File Email) had actually assigned. Caught in production: staff
noticed filed emails' categories had been rewritten down to the bare code. Fixed in
`run.ps1` to just add `Filed` on top of the existing categories unchanged, matching how the
Sent Items pass already worked.

## What this version does NOT do (known v1 gaps)

- **File names use the email's UTC sent time, not a true mailbox-local time.** The index
  doc says file names exist for humans browsing the folder and aren't parsed by the
  index itself, so this wasn't judged worth a per-branch timezone lookup. `sentLocal` is
  therefore also omitted from the `POST /api/emails` payload (it's an optional field).
- **The index-notify call will almost always fail, and that's fine.** `EMAIL_INDEX_BASE_URL`
  defaults to the prototype's `http://127.0.0.1:8792` — a loopback address on whichever
  staff PC happens to be running it, unreachable from this cloud-hosted Function. Filing
  still fully succeeds via the file route alone; the email is indexed later once
  OneDrive syncs the new file to that PC. Update this setting to the index's real URL
  once it's hosted (the doc's own "After hosting (planned)" section says the API
  contract won't change, just the base URL and adding a bearer token).
- **Thread/conversation suggestions, attachment-level indexing detail, and the
  label-mismatch recommendation loop are not built.** They're the index's own job, not
  this sync tool's.
- **Not independently confirmed**: that a category set via `item.categories.addAsync`
  on a compose item (`file-on-send-dialog.html` → `commands.js`, before send) actually
  survives onto the sent copy that lands in Sent Items. This is standard, documented
  Outlook behavior, but hasn't been verified against a real send in this tenant yet —
  if it doesn't carry over, the Sent Items pass above will simply never find anything to
  file, with no error anywhere (nothing to retry; the category was never there to find).

## One-time setup runbook (as actually completed)

1. ✅ **Azure resource group** `summation-email-filing-sync-rg`, Australia East, in the
   **same** subscription as Exchange Bridge, per brief §5/§8 — the bridge's own
   resources, app registration and certificate were never touched.
2. ✅ **"Summation Email Filing Sync" app registration** created (client ID
   `4bc59d03-c16b-4266-a506-656f398797b9`), single-tenant, no redirect URI,
   certificate-based (no client secret — certificate generated locally,
   `New-SelfSignedCertificate`, thumbprint `E9BA438A5FB0A2CF1EB81B8F6922493E6DF9BA7E`,
   private half kept only at `%USERPROFILE%\SummationEmailFilingSyncCerts`, same pattern
   as the bridge's own cert). Application permissions `Mail.ReadWrite` and
   `Sites.Selected` (both Graph, app-only) added and admin-consented.
3. ✅ **Exchange Application Access Policy** scoping `Mail.ReadWrite` to a new
   mail-enabled security group, "Summation Staff Mailboxes", populated with every
   current `UserMailbox`-type recipient (19 at creation time) — explicitly excluding
   every `SharedMailbox` (325 at creation time, i.e. the project mailboxes). Verified
   with `Test-ApplicationAccessPolicy`: a real staff mailbox returns `Granted`, a
   project/shared mailbox returns `Denied`.
   - **Membership is static, not automatic.** A dynamic distribution group was tried
     first and rejected outright by Exchange ("dynamic groups do not qualify as
     security principals" for this feature) — `New-ApplicationAccessPolicy` only
     accepts a real mail-enabled security group. That means **this group needs manual
     upkeep as staff join or leave** (`Add-DistributionGroupMember` /
     `Remove-DistributionGroupMember` on "Summation Staff Mailboxes") — nothing in this
     repo keeps it in sync automatically yet. Worth automating later (this Function
     could reconcile it itself on each run) or migrating to Microsoft's newer **"RBAC
     for Applications"**, which Microsoft's own docs now say is the forward-looking
     replacement for Application Access Policies.
4. ✅ **`Sites.Selected` write access** granted on the Hub site
   (`https://summationptyltd.sharepoint.com/sites/Hub`, the one site holding both the
   Active and Archive libraries) to the app's own `appId`, via
   `Grant-PnPAzureADAppSitePermission` — not `Sites.ReadWrite.All`. Getting PnP.Powershell
   working needed, in order: installing PowerShell 7 (PnP 3.x requires 7.4+, this
   machine only had Windows PowerShell 5.1), then registering a dedicated,
   single-tenant, Summation-owned "PnP Interactive" bootstrap app scoped to only the one
   delegated permission needed (`Sites.FullControl.All`, the documented minimum to grant
   a `Sites.Selected` permission at all) via `Register-PnPEntraIDAppForInteractiveLogin`
   — deliberately not the shared, multi-tenant "PnP Management Shell" app, to avoid
   consenting a third-party-maintained app tenant-wide. That bootstrap app was **deleted
   immediately after use** (`az ad app delete`) once the grant was confirmed, so no
   standing `Sites.FullControl.All` credential is left anywhere.
5. ✅ **Function App** `summation-email-filing-sync` created (PowerShell 7.6,
   Consumption, Windows, Australia East — same shape as the bridge), own storage account
   (`summationemailfiling`), own Application Insights component. Certificate's private
   half uploaded via `az webapp config ssl upload`. App settings applied per
   `local.settings.json.example`. Code deployed (`az functionapp deployment source
   config-zip`); the `SyncEmails` timer function confirmed registered.
6. ✅ **Proof of concept run, for real** (2026-10-06): the first live runs surfaced two
   permission gaps, both fixed and verified against production before being trusted:
   - `Get-StaffMailboxes` originally called `/users` directly, needing `User.Read.All`/
     `Directory.Read.All` the app never had — real `403 Authorization_RequestDenied` on
     the very first run. Fixed by reading the "Summation Staff Mailboxes" group's own
     membership instead (needs only `GroupMember.Read.All`) — the same group the access
     policy already trusts, so there's no way for "who this code thinks is staff" to
     drift from "whose mail Exchange actually lets it touch."
   - That group-membership call then returned every selected property (`displayName`,
     `mail`, `accountEnabled`) as `null` for the app-only token, with no error at all --
     a genuine Microsoft Graph platform quirk: delegated callers get baseline directory
     read for free, application-permission callers don't. Confirmed by direct
     side-by-side reproduction (same URL, delegated token = full data, app-only token =
     all nulls). Fixed by adding `User.Read.All` (Application).
   - With both fixed, a real run against Pras's own, already-staged backlog of 126
     emails filed the large majority of them correctly on the first attempt (right
     project, right Active/Archive library, sensible file names), correctly left
     no-category emails untouched, and correctly skipped (at the time) anything over
     4MB rather than losing or corrupting anything — see the large-file fix below.
7. ✅ **Large file (>4MB) uploads** now use a Graph upload session
   (`Send-GraphLargeFile`, chunked PUT in 10 MiB pieces) instead of being skipped — the
   gap found during the proof of concept above.
8. ⬜ Budget alert on the subscription (brief §5) — not yet set.

### A real, separate, already-hosted email-index was discovered mid-build

While inventorying the subscription before creating anything, `summation-email-index-rg`
already existed — a real Function App (`summation-email-index`, Linux, Node/Python —
`kind: functionapp,linux`) plus an Azure SQL Database (`summation-email-index-sql` /
`emailindex`), not just the local SQLite prototype the requirements doc describes. No
functions are deployed to it yet (`az functionapp function list` returns empty) and Easy
Auth is disabled, so it's mid-build elsewhere, not yet live. `EMAIL_INDEX_BASE_URL` is
set to its real hostname (`https://summation-email-index.azurewebsites.net`) rather than
the prototype's `127.0.0.1:8792`, ready for whenever it goes live — `Invoke-IndexApi`'s
error handling doesn't care either way.

## Cost

Same Consumption-plan free-tier shape as `exchange-bridge` (see its README) — a timer
trigger running every 5 minutes is ~8,640 executions/month, nowhere near the 1,000,000
free monthly executions. Expect close to $0/month plus the new Storage Account's
fractions of a cent, same as the bridge.
