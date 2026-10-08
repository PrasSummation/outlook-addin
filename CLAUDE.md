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
| `batch-file-dialog.html` | Batch File Folder (added 2026-10-07): works through every email in a whole folder at once, each row getting its own project (or Skip), or one project applied to all via a bulk checkbox. Opened from the taskpane's own tile, same dialog architecture as the other two. See "Batch File Folder" below. |
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

## Content-based project suggestions (2026-10-07)

Both picker dialogs now show up to a few "Suggested — ⟨Project Name⟩ (reason)" rows above
the normal folder list, sourced from the hosted `email-index` repo's `/api/suggest`
endpoint (which merges a relational thread/person/domain signal with a new content-keyword
signal — see that repo's `SPEC_ContentBasedProjectSuggestions.md`, the shared source of
truth for this feature across both repos). Only ever additive to the existing list — same
rows, just reordered/prefixed, following `HANDOFF_MLPredictor_DeepDive.md` §9's UI rules:
shown only while the search box is empty, hidden the instant typing starts, re-validated
against the current folder list and service filter at every render (not just once), and
deduplicated so a suggested project doesn't also appear again further down the list.

- **Always best-effort, never interactive.** Every token acquisition for this feature uses
  `isUserAction: false` — if the signed-in user has never granted the add-in's
  `EmailIndex.Access` scope, suggestions just silently don't appear rather than popping up
  an unexpected consent dialog while someone's mid-filing. Once granted anywhere (e.g.
  `email-search.html`), it's silently available everywhere else too — consent is per user+app
  registration, not per page.
- **`file-email-dialog.html`**: has a real, Graph-addressable message already selected, so it
  does a silent `mailWriteRequest` Graph lookup (`$select=from,toRecipients,ccRecipients,
  conversationId,subject,bodyPreview`) for the first selected item, then calls `/api/suggest`
  with all of that. Guarded against a stale response landing after the selection moved on
  (`feSuggestionsLoadedFor`).
- **`file-on-send-dialog.html`**: fires at send time, before the outgoing item is a
  Graph-addressable object at all — deliberately lighter-weight than File Email's version.
  Rather than forcing an interactive `mailWriteRequest` consent right as the dialog opens
  (too intrusive for a nice-to-have, and `findOriginalMessage()`'s own lookup is already
  deferred until a project's actually picked), this only sends `subject` and
  `conversationId` — both already sitting in `sendContext` from `commands.js`'s own
  detection, no extra Graph round-trip needed. `conversationId` alone still drives the
  strongest signal (an exact thread match) for any reply/forward.
- Both dialogs share the same `matchesProjectCode(folderName, code)` helper (leading
  `CODE` matched against the folder name, same regex family as `extractProjectNumber`) to
  resolve a suggestion's bare project code back to one of the currently-loaded folder
  entries — same code-based resolution principle as the legacy ML doc's §8, just without
  the alias-derivation layer since the index already deals in real project codes.
- Still outstanding (see the spec's own §8 open questions): no real-world tuning yet on how
  relational vs. content scores combine, nor on the new `keyword_timer`'s 6-hour rebuild
  schedule in `email-index` — both are first-cut defaults, not measured.

## Batch File Folder (2026-10-07)

A new taskpane tile (`batchFileButton`, alongside the File Email tile — no new ribbon button,
no manifest change) for working through a whole folder of accumulated, unfiled emails in one
pass, rather than one-at-a-time via File Email. Opens `batch-file-dialog.html`.

- **Folder detection has no dedicated API to lean on.** Office.js has no way to ask "what
  folder is currently open in the navigation pane." The workaround: `openBatchFileDialog()`
  (taskpane.html) reuses `detectFileEmailSelection()` — the exact same function File Email
  uses — purely to get *one* selected item's `restId`. The dialog then does its own Graph
  lookup (`GET /me/messages/{restId}?$select=parentFolderId`) to find out which folder that
  item actually lives in, and lists *every* email in that folder, not just what was selected.
  If nothing is selected, the dialog just asks for a selection and stops there.
- **Paging past Graph's own page-size limits**: the folder's emails are read via
  `@odata.nextLink` pagination (`$top=100` per page), rendering each page's rows into the
  table as it arrives rather than waiting for the whole folder to load first — a folder with
  thousands of emails still shows something immediately.
- **UI**: each row gets a plain `<input list="...">` backed by one shared `<datalist>` of
  every project folder name, not a native `<select>` per row — a `<select>` with hundreds of
  `<option>`s replicated across potentially thousands of rows would be real DOM weight; a
  single shared datalist is effectively free per row. Leaving a row blank means Skip.
- **Bulk mode** ("Assign 1 project to all emails"): checking it swaps in one single project
  picker that applies to literally every row and disables the per-row inputs; unchecking it
  restores whatever each row had before, untouched. Deliberately override, not default-fill —
  confirmed with the user before building it, since the other reading (just pre-filling a
  starting value) is just as plausible from the spec alone.
- **Content-based suggestions, lighter-weight than File Email's own**: each row calls
  `/api/suggest` with only `subject`/`from`/`conversationId` — all already sitting in the
  folder-listing response's own `$select`, no extra per-row Graph call needed (unlike File
  Email's version, which does fetch the full message for its one selected item). Run through
  a small concurrency-limited queue (4 at a time), not fired for every row at once. Same
  always-silent (`isUserAction: false`) token rule as everywhere else this feature appears.
- **Dispatch reuses File Email's bridge plumbing verbatim**: rows are grouped by resolved
  project, each group's items are chunked (`BATCH_CHUNK_SIZE = 50`) into separate
  `FileEmailBatch` POSTs — this is the "overcome the item-count limit" part on the write side,
  mirroring the read-side pagination — fired with limited concurrency (3 at a time), tracked
  in the *same* `fileEmailPendingBatches` localStorage key File Email's own dialog reads, so
  an outcome from a batch-file run surfaces in File Email's existing pending-batches notice
  too. The master-category pre-flight/cleanup (`findMasterCategory`/`deleteMasterCategory`)
  runs once per *project group*, not once per chunk.
- **Found live, still being chased as of 2026-10-07**: a large real folder stops loading
  silently around ~200-300 emails. Three fixes tried so far, same cap each time:
  1. `@odata.nextLink` paging stopped producing a further link well short of the folder's own
     `totalItemCount`, no error at all.
  2. Switched to a `receivedDateTime` cursor (`$filter=receivedDateTime lt <last item's
     timestamp>`) in case `$orderby`'s search-index backing was the cause — same cap, just
     slightly later.
  3. Dropped `$orderby`/`$filter` entirely, back to plain `nextLink` — ruled out sorting as
     the cause, cap persisted regardless.
  Every attempt also added real error surfacing (a visible "stopped early — Retry" banner
  with a resumable link, replacing the old silent-swallow-into-console.error) and a
  `totalItemCount` mismatch check, so at least any future stop is now reported honestly
  rather than silently mistaken for success.
  The collect-then-render split (`collectFolderRoster` Phase 1, pure in-memory `nextLink`
  paging with no DOM writes at all, then `renderRosterIntoTable` Phase 2 once that's fully
  done) confirmed the *loading* side was actually fine — a real test loaded and rendered all
  742 emails in a large folder correctly. The cap turned out to be a completely separate bug
  on the **write side** (Confirm), not loading at all:
  - `fileGroup`'s dispatch fired chunks concurrently and never looked at their results — it
    declared "continuing in the background" the instant the POSTs were sent, without ever
    checking whether they actually succeeded.
  - `FileEmailBatch` is synchronous per chunk (up to 3 Graph calls per item, sequentially,
    inside one HTTP request/response) — so firing multiple chunks concurrently against the
    *same* mailbox made individual chunks slower and more timeout-prone, not faster.
  - Worst of all: because `handleConfirmInner` returned almost immediately (not awaiting the
    fire-and-forget dispatch), the `beforeunload`/`guardAgainstClose` warning only covered
    the instant of kicking requests off, not the minutes of real work still in flight — if the
    dialog closed (or was closed) while chunks were still running, the webview tearing down
    very plausibly aborted those in-flight `fetch()` calls mid-request, silently losing
    whatever hadn't completed yet. This is the most likely explanation for "starts processing
    but doesn't go through all emails."
  First fix made it worse: dispatching strictly sequentially (one chunk fully awaited before
  the next starts) meant a ~30-chunk run could take 15-20 minutes end to end, and the user
  then reported the dialog window **closing by itself** partway through a run — for reasons
  outside this page's own control (not a bug in this code closing it; something about the
  Outlook/WebView host itself, still unconfirmed exactly what). A chunk whose request was
  never actually sent yet is lost outright when that happens — there's nothing server-side to
  keep running, because nothing was ever started for it. Sequential dispatch maximized exactly
  that exposure window.
  **Current design**: front-load dispatch instead. Every chunk for every project is built and
  recorded in `fileEmailPendingBatches` up front (before any network calls), then all of them
  are fired together with bounded concurrency (`BF_DISPATCH_CONCURRENCY = 4`, `BATCH_CHUNK_SIZE
  = 25`) rather than awaited one at a time. The reasoning: once a chunk's request has actually
  reached the Azure Function, it keeps running to completion server-side regardless of whether
  this dialog still exists a moment later (the same guarantee file-email-dialog.html's own
  `postFeBatch` already relies on) — so the only real defense against an unpredictable early
  close is minimizing how long it takes to get every request *sent*, not how long it takes to
  see every result. `postChunkWithRetry` still retries a chunk that throws before giving up,
  and the result screen still shows live succeeded/failed counts as responses come back, now
  explicitly saying "this continues on the server even if this window closes" since that's
  the honest behavior rather than something to hide.
  **Not yet confirmed**: whether this actually prevents the self-closing dialog, since the
  cause of the close itself is still unknown — this only shrinks the window during which an
  early close costs you unsent work. A large table (742+ rows, each with its own input and
  shared datalist) is a plausible contributor to host/WebView memory pressure over a long
  session, but unconfirmed; worth revisiting with real telemetry if this still recurs.

## Reclassify project + multiselect bulk actions (2026-10-08)

Added to `email-search.html`: a "Reclassify project" button in the preview pane's actions row
(next to Open in Outlook/SharePoint, Show conversation), a checkbox (or ctrl/cmd-click) on
every result row for multiselect, and a bulk action bar that replaces the normal result count
when 1+ rows are checked (Bulk download, Bulk reclassify, Clear selection).

- **Reclassify's actual SharePoint move needed a write-capable Graph identity.**
  `email-index`'s own Function App only has read `Sites.Selected` by design (it just indexes
  what's already there). Rather than granting it write and taking on a new permission scope,
  this reuses the signed-in user's own delegated `Sites.Selected` permission — the same one
  Batch File Folder already uses to upload directly to SharePoint — proxied through a new
  `exchange-bridge` endpoint (`ReclassifyEmailBatch`/`ReclassifyEmailBatchStatus`, same
  survive-disconnect shape as `FileEmailBatch`: the request keeps running server-side to
  completion even if the tab closes, result written once to the same `file-email-batches`
  blob container under a `reclassify-{batchId}.json` name). The move itself is always
  copy-to-destination-then-delete-original (polling Graph's async copy monitor), never a
  `PATCH` move — Graph's move isn't reliable across document libraries, and copy+delete works
  identically whether the destination is the same library (Active/Archive) or the other one.
- **The target-project picker reuses Batch File Folder's own project-folder list** (live
  Graph listing of every branch-path folder, client-side, via the user's own `Sites.Selected`
  token) rather than `email-index`'s `/api/facet?key=project`, which only knows projects that
  already have at least one indexed email — the picker here needs to find a brand-new project
  folder too.
- **The index is updated by the same best-effort notify `email-filing-sync` already uses**
  (`POST /api/emails` right after the move succeeds) rather than teaching `exchange-bridge` to
  write to email-index's Azure SQL directly, or teaching email-index to delete rows itself.
  The *old* row is left for `sync_timer`'s own delta scan to clean up (it already does this —
  a deleted SharePoint item removes its row) within its normal ~5-minute cadence, so there's a
  short window where a just-reclassified email can show under both its old and new project, or
  briefly neither. Chosen over building an immediate two-way update because it needed zero new
  code on the index side beyond what was already there and deployed.
- **Bulk download is a new, pure-read `GET /api/bulk-download?ids=...`** on `email-index`
  itself (zips the original `.eml`/`.msg` files, reusing the same `load_original`/cache path
  `/api/email/{id}` already uses) — no new permission needed since it only reads. Pulled down
  via `fetch()` + a Blob URL (not a plain `<a href>`) since it needs the same bearer-token
  `api()` helper every other call on this page uses, unlike the signed, unauthenticated
  `/api/dl/...` links used for individual attachment/original downloads.
- **`/api/email/{id}`'s response gained `driveId`/`itemId`/`sentUtc`** (previously used only
  server-side for `load_original`) — the reclassify payload needs the file's current SharePoint
  location, and `sentUtc` round-trips cleanly into the notify call's `sentUtc` field without a
  date-parse-and-reformat step.
- **Not mirrored into `email-index`'s own prototype `search.html`.** That prototype has no
  MSAL/auth at all (a local, unauthenticated dev tool) — Reclassify's whole design leans on the
  signed-in user's own delegated tokens, so it doesn't translate there without first deciding
  what auth the prototype would even use. Flagging here rather than silently mirroring
  something that wouldn't actually work, per this file's usual "edits to one must be mirrored
  in the other by hand" rule.
- **Known v1 scope cuts**: no resume-after-tab-close for a reclassify batch (unlike Batch File
  Folder's `fileEmailPendingBatches` localStorage recovery) — reclassify selections are
  expected to be small (a handful of emails at a time), so this was judged not worth the extra
  machinery yet; worth adding the same pattern if bulk reclassify turns out to be used on large
  selections. No guard against picking the email's own current project as the reclassify
  target (harmless — it just copies the file to itself with `(1)` appended via Graph's own
  rename-on-conflict behavior and the old one gets deleted — but pointless).

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
