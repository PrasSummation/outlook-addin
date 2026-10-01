# Summation Outlook Add-in — project handoff

This file exists so a fresh chat session can pick up this project without
re-deriving its architecture from scratch. It's a factual map of what exists
and how it fits together, not a task list — read it, then go explore the
actual files for anything you need in more depth.

## What this is

A classic Office.js Outlook task-pane add-in ("Summation Assistant") for
**Summation Pty Ltd**, plus a handful of standalone browser pages and one
small Azure Function backend. It automates the SharePoint/Exchange admin
that comes with running project-based mailboxes: creating new project
folders + mailboxes, moving projects between Active/Archive, granting or
revoking shared-mailbox access in bulk, and filing emails into the right
project mailbox.

- **Repo**: `PrasSummation/outlook-addin` on GitHub.
- **Hosting**: static GitHub Pages at
  `https://prassummation.github.io/outlook-addin/` — every `.html` file in
  the repo root is a live, directly-navigable page at that path. There is no
  build step; what's in the repo is what's served, immediately after a push.
- **Auth**: MSAL.js (`@azure/msal-browser`, loaded from CDN) against Entra ID
  app registration **"Summation Outlook Add-in"** (client ID
  `80497ed0-ecd5-475e-97e0-5c9e90fb8a0d`, tenant
  `ecb5f458-9548-4e8b-96f3-904f1828f931`, branded "Summation Assistant" only
  in the UI). All pages share this same MSAL config/clientId.
- **Data stores touched**: Microsoft Graph (SharePoint document libraries,
  user/staff directory, mail), and Exchange Online (shared mailbox creation
  and Full Access permissions) via the custom bridge below.

## File inventory

| File | Role |
|---|---|
| `manifest2.xml` | Office Add-in manifest. Registers the ribbon button and compose-mode button, both pointing at `taskpane.html`. This is the **only** entry point wired into Outlook itself. |
| `taskpane.html` | The task pane sidebar. Main menu + four "wizard" flows (see below) that collect inputs, then hand off execution. Also has the live `APP_VERSION` string shown in its footer — bump it on every change so you can confirm a deployed version in the field. |
| `complete-action.html` | Standalone execution page. Does the actual long-running work (SharePoint writes, mailbox creation, bulk grants) for all four taskpane wizards. See "The handoff pattern" below — this file exists specifically so closing the taskpane mid-action doesn't abort the action. |
| `manage-shared-mailbox-members.html` | Standalone page, linked from the taskpane's "Manage Shared Mailbox Members" button. Bulk two-pane UI: pick project mailbox(es) + pick staff, Confirm does a true diff (grant newly-checked, revoke newly-unchecked, no-op otherwise) with live per-member status. |
| `manage-mailboxes.html` | Standalone page, **not linked from the taskpane UI** — reached only by navigating directly to its URL. Single-user self-service: grant/revoke your own Full Access on one mailbox at a time, split Sustainability/Energy. |
| `manage-mailbox-automapping.html` | Standalone page, **not linked from the taskpane UI** either. Reconciles "what Exchange says you have Full Access to" against "what's actually showing in your Outlook folder pane" — these drift apart and neither Graph nor Exchange exposes that comparison directly. Requires the user to import a local JSON export of their actual Outlook mailbox list (`{ mailboxes: [...], exportedAtUtc }`) via a file picker; that export is **not produced by this repo** — it comes from some other local tool/script the user runs against their own Outlook. Also tracks Outlook's ~32-mailbox folder-pane display limit. |
| `exchange-bridge/` | Azure Function (PowerShell 7.6) — see its own `README.md`, which is the authoritative, detailed doc. Summary below. |
| `exchange-bridge/README.md` | **Read this in full before touching the bridge.** Covers the two-app-registration trust model, why the originally-planned least-privilege Exchange RBAC didn't work (ended up needing the full Exchange Administrator directory role), the API contract, and a completed setup runbook. |
| `README.md` (repo root) | Just a one-line stub — not useful, don't rely on it. |
| `logo-symbol-*.png` | Add-in icons referenced by the manifest and page headers. |

## The taskpane's four wizards

All four follow the same shape: an intake/browse step, a Confirm step that
only *collects* parameters, then a hand-off (see below) to
`complete-action.html`, which does the real work and shows the result.

1. **New BD project** — allocates the next project number for a
   service/branch combo (`getNextProjectNumber`, re-checked for races in
   `complete-action.html` right before writing), copies the Sustainability
   project template (or creates a blank folder + `BD` subfolder for Energy,
   which has no template) into Archive, files the triggering email +
   attachments into it via Graph (`fileEmailAndAttachmentsViaGraph` —
   downloads the message by `internetMessageId`, not via Office.js), **then
   creates a real Exchange shared mailbox and grants Full Access to every
   current Summation staff member** as the last step
   (`createProjectMailboxAndGrantAllStaff`). This mailbox-creation step was
   deliberately moved here from "Change BD to Active project" — see git log
   message `ee40a53`.
2. **Change BD to Active project** — copies a folder from the Archive drive
   to the Active drive (`copyFolderAcrossDrives`, polls a SharePoint copy
   monitor), then deletes the Archive original once the copy is confirmed
   present. No mailbox action (moved out to New BD Project).
3. **Convert Active to Archive** — the same folder-move logic, reversed
   direction.
4. **Create Shared Mailbox** (standalone wizard, not tied to a folder) —
   pick an existing project folder name (browsed from Active+Archive) or
   type a custom name, then create the mailbox and **grant Full Access to
   every current Summation staff member** — same policy as New BD Project,
   intentionally no per-team choice anymore (removed 2026-10-01, see commit
   `c45ce3b`; the "Service" radio on this wizard's first step only filters
   the folder-name search list, it no longer affects who gets granted
   access).

Two more taskpane features that aren't full wizards:
- **Search Shared Mailbox Online** — just opens a project mailbox in Outlook
  Web, no write actions.
- **Sync Emails** — pings `http://127.0.0.1:8791/ping` then POSTs
  `/sync-emails` to a locally-running companion desktop app, the
  **Summation Email Filer** (a separate Python/pywin32 COM tool, not part of
  this repo). This triggers it to scan the user's "Emails to File" subfolder,
  read Outlook categories, and move matching emails into their project
  mailboxes using a true `.Move()` (preserves received-date fidelity in a
  way Graph-only filing cannot). Progress/results are reported via the
  Filer's own tray notification, not back into the taskpane. If you need the
  exact spec given to that tool's team (category-matching rules, ambiguous
  category handling, failure reporting), it's not in this repo — ask the
  user, it was handed off as a separate document.
- There is also an older, simpler **"Create New Shared Mailbox"** button for
  personal Inbox subfolders (`createSharedMailbox()` in `taskpane.html`,
  around the `csmFolderList`/`createMailboxButton` area) — a legacy/manual
  path, distinct from the "Create Shared Mailbox" wizard above.

## The handoff pattern (taskpane → complete-action.html)

**Why it exists**: Office.js task panes have no background-execution model —
closing the pane kills its JS immediately, with no way to prevent closing or
to resume afterward. Users were closing the sidebar mid-action (e.g. mid
mailbox-grant loop) and silently losing progress. The fix: the taskpane only
*collects* inputs; on Confirm it synchronously opens a separate browser tab
at `complete-action.html` which does all the actual Graph/bridge work
independently of the taskpane's lifetime.

**How data gets from the taskpane to that tab — read this before changing
either file**: originally this used `localStorage` to pass the action
payload, which **does not work** on classic desktop Outlook. There,
`Office.context.ui.openBrowserWindow()` (the open call this uses for that
client) opens the URL in the OS's actual default browser — a fully separate
process/storage partition from the taskpane's embedded webview, even for the
same origin. So the fix (commit `8db6dc7`) encodes the payload directly in
the URL query string instead:
`handOffToCompleteAction(type, params)` in `taskpane.html` builds
`...complete-action.html?action=<encodeURIComponent(JSON.stringify({type, params}))>`;
`complete-action.html` reads it back via an IIFE
(`captureHandoffFromUrl()`) immediately on load, into a module-level
`pendingAction` variable, then scrubs the URL with `history.replaceState`.
Do not reintroduce `localStorage` for this handoff. Also note: the new-tab
open must stay **synchronous** (before any `await`) or popup blockers will
eat it.

**Known test gap**: this repo's local browser-preview tooling renders local
files as synthetic `data:` URLs, which silently discard query strings (and
also block `localStorage`). Neither mechanism can be fully exercised
end-to-end locally — real verification requires pushing to GitHub Pages and
testing inside real Outlook.

`complete-action.html` has its own `actionInProgress` + `beforeunload` guard
(same pattern as the taskpane — see below) so closing *that* tab mid-action
at least warns the user.

## Recurring code patterns

- **`guardAgainstClose(fn)` / `actionInProgress` / `beforeunload`**: used
  anywhere a click kicks off an async action that shouldn't be silently
  abandoned by closing the tab/pane. Pattern: rename the real handler to
  `xInner`, wrap it as `function x() { return guardAgainstClose(xInner); }`,
  and wire the click listener to the outer name — no handler-wiring changes
  needed. Present in `taskpane.html` (guards the manual mailbox-create path),
  `complete-action.html`, `manage-mailboxes.html`,
  `manage-mailbox-automapping.html`, and `manage-shared-mailbox-members.html`.
- **Diff-based reconciliation**: `manage-shared-mailbox-members.html`'s
  Confirm compares "checked" state against a freshly-fetched "current
  membership" state and only grants/revokes what actually changed, with live
  per-member status badges. This is the template to follow for any future
  bulk membership feature rather than a blind grant-all.
- **Project mailbox naming convention**: `^[a-zA-Z]{5}\d{5}[_-].+@summation\.au$`
  (5 letters + 5 digits + `_` or `-` + name, e.g. `SUPER26099_ProjectName`).
  Enforced both client-side (regex checks scattered across the `.html`
  files) and server-side (`Test-ProjectMailboxAddress` in
  `exchange-bridge/Modules/MailboxBridge/MailboxBridge.psm1`) — keep both in
  sync if this ever changes again.
- **Staff list source of truth**: `getAllStaffMembers()` queries Graph
  `/users` filtered to licensed, enabled accounts, explicitly excluding
  addresses matching the project-mailbox regex (so shared mailboxes never
  get treated as staff). Department-based filtering (`getStaffByDepartments`)
  existed for the old Create Shared Mailbox team-picker and was deleted
  2026-10-01 when that picker was removed — don't resurrect it without reason.
- **Drive/path constants** (`ACTIVE_DRIVE_ID`, `ARCHIVE_DRIVE_ID`,
  `TEMPLATE_PATH`, `ACTIVE_BRANCH_PATH`, `ARCHIVE_BRANCH_PATH`) are
  duplicated verbatim between `taskpane.html` and `complete-action.html`
  since there's no shared JS module — if you change one, change both.

## Exchange bridge (backend) — summary only, see `exchange-bridge/README.md`

A PowerShell Azure Function at
`https://summation-exchange-bridge-e6e5gsendkdxdwf5.australiaeast-01.azurewebsites.net`,
because Graph has **no API at all** for Exchange mailbox permissions,
AutoMapping, or `New-Mailbox`. It exposes:

- `GET /api/mailbox-permissions?mailbox=<smtp>` — list Full Access members.
- `POST /api/mailbox-permissions/grant` — `{ mailbox, user, autoMapping? }`
  (house default is `autoMapping: false`, passed explicitly by every caller).
- `POST /api/mailbox-permissions/revoke` — `{ mailbox, user }`.
- `POST /api/shared-mailboxes` — `{ mailbox, displayName }`, runs
  `New-Mailbox -Shared`; returns `409` (not an error to callers) if the
  recipient already exists.

Auth: callers get a token for the **"Summation Outlook Add-in"** app's
exposed `MailboxBridge.Call` scope (same MSAL session as everything else);
the Function validates that via Easy Auth, then uses its own **separate**,
certificate-based, app-only identity ("Summation Exchange Bridge") to talk
to Exchange Online — deliberately two different app registrations so the
Exchange-wide credential is never reachable from the public GitHub
Pages-hosted client code. That service principal ended up needing the full
**Exchange Administrator** directory role (a planned narrower custom RBAC
role turned out not to be supported for app-only Exchange Online
PowerShell auth at all) — this is a known, accepted trade-off, not an
oversight.

Every endpoint 403s mailbox/user addresses that don't match the expected
naming patterns, before touching Exchange.

## Things worth knowing before changing anything

- **Revoke isn't instant in Outlook.** Removing Full Access doesn't make a
  mailbox disappear from the target user's Outlook immediately — it waits
  for Autodiscover to refresh, sometimes requiring the user to remove it
  manually. Any UI calling revoke should say this, not promise instant
  disappearance.
- **AutoMapping state isn't directly queryable.** `Get-MailboxPermission`
  doesn't expose a clean AutoMapping flag; `manage-mailbox-automapping.html`
  works around this by reconciling against a user-supplied local export of
  their actual Outlook mailbox list rather than trusting Exchange alone.
- **Outlook's folder pane silently stops showing mailboxes beyond ~32** —
  tracked as `MAILBOX_DISPLAY_LIMIT` in `manage-mailbox-automapping.html`.
- **Bare Graph `POST /users` does not reliably provision a real Exchange
  mailbox** in this tenant (confirmed via a real incident where one sat
  unprovisioned for ~2 days) — always use the bridge's
  `POST /api/shared-mailboxes` (`New-Mailbox -Shared`) for mailbox creation,
  never a raw Graph user-object create.
- **`APP_VERSION` in `taskpane.html`** (currently `9.24`) is shown in the
  taskpane footer — bump it on every change so a live-tested version can be
  confirmed in screenshots/conversation.
- Two standalone pages (`manage-mailboxes.html`,
  `manage-mailbox-automapping.html`) are **not reachable from the taskpane
  UI at all** — only from a direct GitHub Pages URL. If asked to make them
  more discoverable, that likely means adding a taskpane button/link, not
  changing the pages themselves.

## Where to look for more

- `git log --oneline` in this repo is a fairly reliable change narrative —
  commit messages here have been written descriptively, not just "update
  taskpane.html" (that style only appears in the very oldest history, before
  current conventions were adopted).
- `exchange-bridge/README.md` is the deepest, most current doc on the
  backend and is kept up to date — prefer it over re-deriving bridge
  behavior from the PowerShell source.
