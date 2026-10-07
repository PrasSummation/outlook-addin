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
| `manifest2.xml` | Office Add-in manifest. Registers the main ribbon/compose-mode buttons (pointing at `taskpane.html`), the OnMessageSend LaunchEvent (`commands.js`), and, as of 2026-10-06, the ribbon's dedicated **File Email** button as an `ExecuteFunction` (also `commands.js`) rather than a `ShowTaskpane` — see "File Email is a dialog, not a wizard" below for why. |
| `taskpane.html` | The task pane sidebar. Main menu + three "wizard" flows (see below) that collect inputs, then hand off execution, plus the standalone Email Search action. File Email used to be a fourth inline flow here too; as of 2026-10-06 clicking its tile just opens `file-email-dialog.html` (see below) — the tile is the only File Email surface left in this file. Also has the live `APP_VERSION` string shown in its footer — bump it on every change so you can confirm a deployed version in the field. |
| `file-email-dialog.html` | The File Email picker, as an `Office.context.ui.displayDialogAsync` dialog rather than inline in the taskpane (changed 2026-10-06 — see "File Email is a dialog, not a wizard" below). Self-contained like `complete-action.html` (own MSAL sign-in, own copies of the Graph/bridge helpers), reads its initial selection context from its own URL query string, and receives live selection updates from whichever page opened it via `Office.context.ui.addHandlerAsync(Office.EventType.DialogParentMessageReceived, ...)`. |
| `commands.js` / `commands.html` | UI-less ribbon/event command functions — see its own header comments for the two different ways Outlook clients load this file. Holds `onMessageSendHandler` (the **File on Send** feature, live as of 2026-10-06 — see its own section below; replaced an earlier phase-1 probe) and `fileEmailDialogHandler` (the ribbon's dedicated File Email button — detects the selection and opens `file-email-dialog.html`, duplicating taskpane.html's own copy of that same detection logic). |
| `file-on-send-dialog.html` | The File on Send project picker, opened by `commands.js`'s `onMessageSendHandler` via `displayDialogAsync` when a message is sent. Built from the separately-approved mockup at https://claude.ai/artifact/EqTMRsGos3VHXtspmZPXpp. See "File on Send is live" below. |
| `complete-action.html` | Standalone execution page. Does the actual long-running work (SharePoint writes, mailbox creation) for the three taskpane wizards. See "The handoff pattern" below — this file exists specifically so closing the taskpane mid-action doesn't abort the action. |
| `help-guide.html` | Standalone page, linked from the taskpane footer ("Help Guide"). Staff-facing walkthrough of the four things people actually use day to day: File Email (manual), the automatic background filing pass, sent-email auto-save (not live yet), and Email Search. Update this whenever one of those workflows changes. |
| `email-search.html` | The hosted email index/search page, linked from the taskpane's **Email Search** button. Generated from the `email-index` repo's own prototype `search.html` by a scratch script there — **edits to one must be mirrored in the other by hand**, this repo doesn't regenerate it. MSAL sign-in against this repo's same app registration, calls the hosted Function App described in the email-index repo's `HANDOFF.md`. |
| `manage-shared-mailbox-members.html` | Standalone page, **no longer linked from the taskpane UI** (its button was removed 2026-10-06 — shared mailboxes are being retired). Still reachable by direct URL if ever needed for an existing mailbox. Bulk two-pane UI: pick project mailbox(es) + pick staff, Confirm does a true diff (grant newly-checked, revoke newly-unchecked, no-op otherwise) with live per-member status. |
| `manage-mailboxes.html` | Standalone page, **not linked from the taskpane UI** — reached only by navigating directly to its URL. Single-user self-service: grant/revoke your own Full Access on one mailbox at a time, split Sustainability/Energy. |
| `manage-mailbox-automapping.html` | Standalone page, **not linked from the taskpane UI** either. Reconciles "what Exchange says you have Full Access to" against "what's actually showing in your Outlook folder pane" — these drift apart and neither Graph nor Exchange exposes that comparison directly. Requires the user to import a local JSON export of their actual Outlook mailbox list (`{ mailboxes: [...], exportedAtUtc }`) via a file picker; that export is **not produced by this repo** — it comes from some other local tool/script the user runs against their own Outlook. Also tracks Outlook's ~32-mailbox folder-pane display limit. |
| `exchange-bridge/` | Azure Function (PowerShell 7.6) — see its own `README.md`, which is the authoritative, detailed doc. Summary below. |
| `exchange-bridge/README.md` | **Read this in full before touching the bridge.** Covers the two-app-registration trust model, why the originally-planned least-privilege Exchange RBAC didn't work (ended up needing the full Exchange Administrator directory role), the API contract, and a completed setup runbook. |
| `email-filing-sync/` | A **separate, timer-triggered** Azure Function App (own Entra app registration, own resource group — never the bridge's) that watches every staff mailbox's "Emails to File" folder and files categorized emails into their project's SharePoint `Emails` folder, then moves the originals into a local "Filed" folder. No HTTP surface, no signed-in user — see its own `README.md`, which is authoritative. **Status as of 2026-10-06: live in production**, including the >4MB upload-session path. This is what the taskpane's removed "Sync Emails" button/local desktop Filer used to do manually — it's now fully automatic. |
| `README.md` (repo root) | Just a one-line stub — not useful, don't rely on it. |
| *(elsewhere)* | The email **index and search** backend (indexing + the API `email-search.html` calls) lives in its own private repo, `PrasSummation/email-index` (split out of this repo's former `prototypes/email-index/`). Read its `HANDOFF.md` before touching the search page or its backend. It shares this repo's Entra app registration and GitHub Pages origin. |
| `logo-symbol-*.png` | Add-in icons referenced by the manifest and page headers. |

## The taskpane's three wizards

All three follow the same shape: an intake/browse step, a Confirm step that
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

A fourth wizard, **Create Shared Mailbox** (standalone, not tied to a
folder), was removed from the taskpane 2026-10-06 — shared mailboxes are
being phased out in favor of filing straight to SharePoint. Its
`complete-action.html` handler (`runCreateSharedMailbox`, case
`"createSharedMailbox"`) was deleted too, but the shared helpers it used
(`createSharedMailboxViaBridge`, `createProjectMailboxAndGrantAllStaff`,
`grantAccessToStaffWithRetry`, `getAllStaffMembers`) were **kept** — New BD
Project (above) still uses them to create that project's mailbox. There is
also still an older, simpler **"Create New Shared Mailbox"** button for
personal Inbox subfolders (`createSharedMailbox()` in `taskpane.html`,
around the `csmFolderList`/`createMailboxButton` area) — unrelated to either
of the above, not removed, left alone.

Two more taskpane features that aren't full wizards:
- **Search Shared Mailbox Online -legacy** — just opens a project mailbox in
  Outlook Web, no write actions. Renamed with the "-legacy" suffix
  2026-10-06 for the same reason as above (shared mailboxes being phased
  out) — kept for now since some still exist, but **Email Search** (below)
  is the preferred way to find a project's correspondence going forward.
- **Email Search** (added 2026-10-06) — opens `email-search.html` (see file
  inventory above) in the system browser, same `openUrlInBrowser` pattern as
  every other handoff in this file.

Removed 2026-10-06, **no longer in the taskpane at all**:
- **Manage Shared Mailbox Members** button (`manage-shared-mailbox-members.html`
  is still in the repo and still works if opened by direct URL, just no
  longer linked).
- **Sync Emails** button — used to ping `http://127.0.0.1:8791/ping` then
  POST `/sync-emails` to a locally-running companion desktop app, the
  **Summation Email Filer** (a separate Python/pywin32 COM tool, not part of
  this repo), to move categorized emails out of "Emails to File" with a true
  `.Move()` (date-fidelity). This whole local-Filer path is superseded by
  `email-filing-sync/` (see file inventory above), which does the same job
  automatically server-side every ~5 minutes — there is no longer any manual
  "sync" step for staff to run.

## File Email is a dialog, not a wizard (changed 2026-10-06)

File Email used to be the taskpane's fourth inline "wizard" (project search
list, Confirm, Result — all rendered inside `taskpane.html` itself), with a
comment explaining it specifically *couldn't* use the handoff pattern below
because the handed-off page has no `Office.context.mailbox` access at all.
That's all still true, but the inline approach turned out to have its own
real bug: a task pane Outlook opens **fresh** — specifically, clicking the
ribbon's dedicated File Email button when the Summation Assistant wasn't
already open — wasn't reliably getting real OS keyboard focus, so the
project search box's autofocus silently did nothing. Clicking the File
Email *tile* inside an already-open, already-focused pane never had this
problem. Confirmed in real Outlook across several fix attempts (a single
delayed `.focus()`, then a 150ms retry loop, then reacting to window
focus/visibilitychange events) — none of it helped, which points to Outlook
never handing that freshly-created webview real focus at all, not just slow
timing that a longer wait would fix.

The fix: `Office.context.ui.displayDialogAsync` instead. Hosts are expected
to give a dialog real focus on creation, which a task pane apparently isn't
guaranteed to get. This was already the planned mechanism for the
File-on-Send picker (see `manifest2.xml`'s `AppDomains` comment, predating
this change) — File Email just got there first once its own focus bug
forced the question.

**What moved where:**
- `file-email-dialog.html` — the actual picker: project search/pick (with
  the keyboard-nav work from the same day — arrows + Enter, auto-focus),
  Confirm, the categorize+move batch POST to the bridge, and the
  pending-batch retry/dismiss UI. All ported close to verbatim from the old
  inline implementation.
- `taskpane.html` — now only *detects the current selection*
  (`detectFileEmailSelection`, converting to REST ids since the dialog can't
  do that itself) and opens the dialog with it, for the **File Email tile**
  entry point.
- `commands.js` — a second, independent copy of that same detect-and-open
  logic (`fileEmailDialogHandler`), for the **ribbon's dedicated File Email
  button** entry point, which no longer touches `taskpane.html` at all
  (manifest's `Summation.FileEmailButton` Action is `ExecuteFunction` now,
  not `ShowTaskpane` — V1.1 block only, see `manifest2.xml`'s own comment
  there). Can't share code with `taskpane.html`'s copy — same reason no JS
  is shared between any of this repo's pages.

**Live selection tracking**: a one-shot dialog can't call
`getSelectedItemsAsync` itself (dialogs don't get `Office.context.mailbox`
at all, only `Office.context.ui.*`), so whichever page opened it
(`taskpane.html` or `commands.js`) keeps its own `SelectedItemsChanged`
listener running for as long as that dialog is open, and forwards every
change in via `dialog.messageChild(...)`. The dialog receives these via
`Office.context.ui.addHandlerAsync(Office.EventType.DialogParentMessageReceived, ...)`
and only acts on them while still on its "pick" step — same guard the old
inline version used, so changing the selection after a project's already
been picked doesn't retroactively change what's being filed. **Not
independently confirmed**: whether `commands.js`'s own `SelectedItemsChanged`
listener keeps firing for the dialog's *entire* open duration on every
client — confirmed true for classic Outlook on Windows (its JS-only runtime
persists across invocations in practice) but not verified elsewhere. If a
given host tears that down early, live tracking would stop working
specifically for dialogs opened via the ribbon button, not the tile.

Both entry points share `file-email-dialog.html` and the same
`fileEmailPendingBatches` localStorage key (same-origin dialog, expected to
share storage with `taskpane.html` normally — also worth confirming once
tested live, since nothing in this repo had opened a dialog before this).

## File on Send is live (2026-10-06)

Replaces the earlier `onMessageSendHandler` phase-1 probe (which only
proved `OnMessageSend` fires and always let the send through unchanged)
with the real thing, built from the separately-approved mockup:
https://claude.ai/artifact/EqTMRsGos3VHXtspmZPXpp. Chosen trigger model —
**prompts on every send**, not just an opt-in — was an explicit choice,
not a default; see the known gap below before assuming that's still right
for how staff actually work.

**Flow**: sending any message fires `onMessageSendHandler` (`commands.js`),
which reads the compose context (subject, `conversationId`,
`getComposeTypeAsync`'s `composeType`) via plain Office.js, then opens
`file-on-send-dialog.html` via `displayDialogAsync` — same dialog
architecture as File Email, for the same reason (dialogs get no
`Office.context.mailbox`, so everything requiring Graph/SharePoint access
has to live in the dialog, not in `commands.js`). The dialog:
- Loads the project list exactly like File Email's does (same Graph/Site
  calls), with real DOM-focus-driven keyboard nav per the mockup (not File
  Email's virtual-highlight-index approach — deliberately not unified,
  since the mockup is the source of truth here).
- For a reply/forward, best-effort finds "the original" message via a
  `conversationId` search (`findOriginalMessage` — picks the most recent
  message in the conversation not sent by the signed-in user; there's no
  direct API for "the item I'm replying to" from a compose item, so this
  is an approximation, not a guarantee). "Save Both" stays disabled until
  that lookup resolves, and disabled permanently if nothing was found.
- On Save (Both/Reply Only/plain Save for a new message): messages the
  parent with the chosen category immediately, independently fires (and
  does not wait for) the bridge's existing `FileEmailBatch` endpoint to
  file the original if asked — **reusing File Email's exact batch-tracking
  plumbing and `fileEmailPendingBatches` localStorage key**, so a failure
  here surfaces in File Email's own pending-batches notice — then closes
  itself after a brief delay, aborting its own fetch first (same reason as
  File Email's Confirm: some Outlook hosts hold a dialog open until its
  outstanding requests settle).
- On Cancel ("← Back to email"): messages the parent to cancel, shows
  "Send cancelled" briefly, closes itself.

**Back in `commands.js`**: only it can tag the *outgoing* item's
categories (`item.categories.addAsync`, before `event.completed()`) or
actually allow/cancel the send (`event.completed({allowEvent})`) — neither
is possible from the dialog. `SendMode="SoftBlock"` is relied on as the
safety net for a hung/erroring handler, not duplicated with an extra
timeout in this code.

**Filing the sent reply happens later, server-side**: at `OnMessageSend`
time the reply/new message doesn't exist as a real, Graph-addressable item
yet (per the mockup's own note) — all this code can do is categorize the
*outgoing* item before it sends. `email-filing-sync`'s `SyncEmails/run.ps1`
was extended with a new Sent Items pass (runs first, independent of the
existing "Emails to File" pass) that looks for recently-sent, categorized,
not-yet-`Filed` messages and files them the same way, but **never moves
them** — see `email-filing-sync/README.md`'s own new section for the
full design, including the 3-hour lookback window and the one
**not-independently-confirmed assumption** this whole half of the feature
rests on: that a category set via `categories.addAsync` before send
actually survives onto the sent copy in Sent Items. Standard, documented
Outlook behavior, but unverified against a real send in this tenant as of
this writing.

**Skip Save, added later the same day**: a "Skip — send without filing"
link on the pick step messages the parent with `{action:"skip"}`, which
`commands.js` treats as an explicit no-op path to `finish(true)` (same
outcome as the old silent fallback for any unrecognized message, just
named so the intent is obvious in the code) — no category is added, the
send goes through untagged, with no bridge call and no delay closing
(nothing in flight to abort). This still pops up on *every* send; it just
no longer forces a project choice on non-project mail.

**UX parity pass with File Email, same day**: the dialog wasn't actually
focusing its search box on open at all (`showStep` only focused it on an
explicit transition back to `stepPick`, never on first load) — fixed by
porting File Email's retrying `focusWhenReady` helper and calling it once
after the first successful sign-in. Also: Save Both now re-steals focus
from the Reply Only fallback once the original-message lookup resolves
and enables it (if the user hasn't already moved focus away manually),
so the mockup's "default focus on Save Both" holds even for the async
case. Separately, `file-email-dialog.html`'s CSS was brought in line with
this dialog's (ported from the approved mockup) for visual consistency —
list-head + refresh button, button hint subtext, context/summary box
styling — its interaction model (virtual-highlight-index nav, not real
DOM focus) was deliberately left alone.

**Incident, 2026-10-07 — sends hanging on "add-in taking longer than
expected"**: a teammate (classic Outlook for Windows) got stuck on
Outlook's own slow-add-in warning when sending, with no visible picker
and no way forward except "Don't Send." Mitigated immediately with a
`FILE_ON_SEND_ENABLED` kill switch at the top of `commands.js` —
`onMessageSendHandler` short-circuits to `event.completed({allowEvent:
true})` before touching the dialog at all. This deploys in ~10 minutes
(GitHub Pages' CDN cache on `commands.js`), not the hours a manifest
change takes to propagate — worth remembering for any future
send-blocking incident, since the manifest's `LaunchEvent` wiring itself
can't be the fast lever.

Root cause: `manifest2.xml`'s `AppDomains` only listed
`prassummation.github.io`, missing `https://login.microsoftonline.com` —
MSAL's authority host, used by both `acquireTokenSilent` (a hidden
iframe) and `loginPopup` (an actual popup) from *inside* the dialog.
`AppDomains` isn't just about `displayDialogAsync`'s own target URL; it
also gates navigation happening inside an already-open dialog. Without
that entry, Office's dialog host can block that in-dialog navigation
silently instead of raising a catchable error, so the MSAL call just
hangs forever rather than resolving or rejecting — explaining why it
worked in testing (an already-cached, unexpired token resolves straight
from local storage, no navigation needed) but hung for someone signing
in fresh. Fixed by adding the entry — but like any `AppDomains` change,
this is a manifest edit, so it's subject to the same slow propagation as
the kill switch's root problem.

Because of that propagation lag, also added a second, faster-deploying
layer of defense in `commands.js`: a 20-second bounded timeout on the
dialog actually becoming interactive, cleared the moment the dialog
pings back `{action:"ready"}` (added to `file-on-send-dialog.html`'s
`showApp`, fired the instant it renders either the sign-in prompt or the
picker). This deliberately does NOT cap how long a user gets to actually
pick a project — once "ready" is received, the user has as much time as
they want, same as before. It only bounds the "did the dialog even wake
up" phase, which is exactly what failed here. `SendMode="SoftBlock"`'s
own built-in timeout remains the ultimate backstop, but its duration
isn't documented and evidently isn't tight enough for a good incident
experience on its own — deliberately duplicated now, not left solely to
that net.

**Follow-up, closing File Email's dialog turned out not to need any of
this waiting at all**: confirmed live that manually closing
`file-email-dialog.html`'s window right after Confirm never affects the
batch — the bridge keeps it running to completion regardless, same as
always relied on. That means every "the dialog won't close" report
(this evening's and earlier ones) traced back to the dialog's own code
still being stuck awaiting a hung MSAL call somewhere above the close
line, never actually reaching `Office.context.ui.closeContainer()` at
all — not `closeContainer()` itself waiting on anything. The earlier
"abort the fetch before closing" fix was chasing the wrong cause.
Replaced with a **parent-initiated close**: the dialog now messages its
opener (`messageParent({action:"close"})`) immediately after firing the
batch, and both entry points that open it — `taskpane.html`'s
`openFileEmailDialog` and `commands.js`'s `fileEmailDialogHandler` —
listen for it and call `dialog.close()` on their own host-held handle.
That's the same kind of close as a user manually closing the window
(host-initiated, not the dialog's own script tearing itself down), so
it should be reliable where the self-close wasn't. The dialog's own
`closeContainer()` call is kept only as a 1.5s-delayed fallback in case
nothing is listening. Also dropped the now-pointless `AbortController`
plumbing around `postFeBatch` — it was only ever wired to the bridge
`fetch()` itself, which was never what was hanging.

**Same bug, different dialog**: `file-email-dialog.html`'s Confirm step
turned out to have the identical latent vulnerability — reported
separately as "the dialog isn't closing right after Confirm." Its
pre-flight `findMasterCategory`/`getOrCreateEmailsToFileFolderId` calls
request `mailWriteRequest` (`Mail.ReadWrite`), a scope not used anywhere
else in that dialog, so they're the first thing each session to need a
*silent* token for it — same blocked hidden-iframe hang as above. It
worked during earlier testing purely because of a fresh/cached token
window, same as File on Send's. Fixed with a `withTimeout()` wrapper (8
seconds) around both calls, so a hang falls through to their existing
`catch` fallback instead of leaving the dialog stuck on "Starting..."
forever. Didn't bother timing out `postFeBatch` itself at first — it's already
fire-and-forget and doesn't block the dialog closing, and an eventual
non-response there is already handled by the existing pending-batch
retry/notice mechanism. (Revisited below — it turned out to matter for
a different reason.)

**Two more bugs found the same evening, both in `file-email-dialog.html`**:

1. **Confirm step auto-skipped itself.** Pressing Enter in the filter
   box to select a highlighted project calls `selectFeProject()`
   synchronously, which shows `stepConfirm` and focuses
   `feConfirmButton` — all within that same keydown event. Since
   `handleFeFilterKeydown` only called `e.preventDefault()` (which stops
   the default action, not propagation), that same keydown then bubbled
   up to the document-level "Enter accepts Confirm" listener, which saw
   `stepConfirm` now visible and `e.target` still the filter box (not a
   BUTTON — `e.target` doesn't follow a focus change mid-bubble), and
   immediately called `handleFeConfirm()` — confirming the exact
   keystroke that had just selected the project, before the user ever
   saw the Confirm screen. Fixed with `e.stopPropagation()` in that
   Enter branch.

2. **The dialog still wasn't closing promptly even after the
   `withTimeout` fix above.** Root cause: `postFeBatch` itself requests
   `bridgeRequest` (`MailboxBridge.Call`) — a *third* scope, used
   nowhere else in this dialog — so it can be the first thing needing a
   silent token for it, hitting the same blocked-navigation hang,
   upstream of the `fetch()` call the existing `AbortController` is
   wired to. Aborting that signal can't reach a hang that occurs before
   the fetch is ever made. Wrapped both of `postFeBatch`'s auth calls in
   the same `withTimeout()` so the promise at least settles and the
   fire-and-forget `.catch` actually runs — but flagged honestly: if the
   dialog's *host* is the one refusing to close while a navigation is
   still in flight (rather than our own JS just being stuck), no amount
   of timing out our own promise can force that — that part should
   resolve once the `AppDomains` fix actually finishes propagating.

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
- **`APP_VERSION` in `taskpane.html`** (currently `11.0`) is shown in the
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
