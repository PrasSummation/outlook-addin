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
| `manifest2.xml` | Office Add-in manifest. Registers the main ribbon/compose-mode buttons (pointing at `taskpane.html`), the `OnMessageSend`/`OnMessageCompose` LaunchEvents (`commands.js`), and the ribbon's dedicated **File Email** button — `ShowTaskpane` → `FileEmail.Url` since the 2026-10-16 revert (briefly `ExecuteFunction` from 2026-10-06, which broke multi-select) — see "File Email is a dialog, not a wizard" below for the full history. |
| `taskpane.html` | The task pane sidebar. Main menu + three "wizard" flows (see below) that collect inputs, then hand off execution, plus the standalone Email Search action. File Email used to be a fourth inline flow here too; as of 2026-10-06 clicking its tile just opens `file-email-dialog.html` (see below). Since the 2026-10-16 revert, the ribbon's dedicated File Email button reaches this same code too, via the `?view=fileEmail` deep link (`feDeepLinkRequested` → `openFileEmailDialog()`) — `commands.js` no longer has its own separate copy of this logic. Also has the live `APP_VERSION` string shown in its footer — bump it on every change so you can confirm a deployed version in the field. |
| `file-email-dialog.html` | The File Email picker, as an `Office.context.ui.displayDialogAsync` dialog rather than inline in the taskpane (changed 2026-10-06 — see "File Email is a dialog, not a wizard" below). Self-contained like `complete-action.html` (own MSAL sign-in, own copies of the Graph/bridge helpers), reads its initial selection context from its own URL query string, and receives live selection updates from whichever page opened it via `Office.context.ui.addHandlerAsync(Office.EventType.DialogParentMessageReceived, ...)`. |
| `commands.js` / `commands.html` | UI-less ribbon/event command functions — see its own header comments for the two different ways Outlook clients load this file. Holds `onMessageSendHandler` (the **File on Send** feature, live as of 2026-10-06 — see its own section below; replaced an earlier phase-1 probe) and `fileEmailDialogHandler` (the ribbon's dedicated File Email button — detects the selection and opens `file-email-dialog.html`, duplicating taskpane.html's own copy of that same detection logic). |
| `file-on-send-dialog.html` | The File on Send project picker, opened by `commands.js`'s `onMessageSendHandler` via `displayDialogAsync` when a message is sent. Built from the separately-approved mockup at https://claude.ai/artifact/EqTMRsGos3VHXtspmZPXpp. See "File on Send is live" below. |
| `batch-file-dialog.html` | Batch File Folder (added 2026-10-07): works through every email in a whole folder at once, each row getting its own project (or Skip), or one project applied to all via a bulk checkbox. Opened from the taskpane's own tile via `openUrlInBrowser()` into a real OS browser tab, **not** an Office.js dialog (changed 2026-10-13) — see "Batch File Folder" below. |
| `mailbox-sync.html` | Mailbox Sync (added 2026-10-26): a manual sweep for emails anywhere in Inbox (recursively) or Sent Items that already carry a project category but were never staged into "Emails Awaiting Sync" — closes the gap File on Send deliberately leaves open. Opened the same `openUrlInBrowser()`-into-a-real-tab way as Batch File Folder, same reasoning — see "Mailbox Sync" below. |
| `complete-action.html` | Standalone execution page. Does the actual long-running work (SharePoint writes, mailbox creation) for the three taskpane wizards. See "The handoff pattern" below — this file exists specifically so closing the taskpane mid-action doesn't abort the action. |
| `help-guide.html` | Standalone page, linked from the taskpane footer ("Help Guide"). Staff-facing walkthrough of the four things people actually use day to day: File Email (manual), the automatic background filing pass, sent-email auto-save (not live yet), and Email Search. Update this whenever one of those workflows changes. |
| `email-search.html` | The hosted email index/search page, linked from the taskpane's **Email Search** button. Generated from the `email-index` repo's own prototype `search.html` by a scratch script there — **edits to one must be mirrored in the other by hand**, this repo doesn't regenerate it. MSAL sign-in against this repo's same app registration, calls the hosted Function App described in the email-index repo's `HANDOFF.md`. |
| `manage-shared-mailbox-members.html` | Standalone page, **no longer linked from the taskpane UI** (its button was removed 2026-10-06 — shared mailboxes are being retired). Still reachable by direct URL if ever needed for an existing mailbox. Bulk two-pane UI: pick project mailbox(es) + pick staff, Confirm does a true diff (grant newly-checked, revoke newly-unchecked, no-op otherwise) with live per-member status. |
| `manage-mailboxes.html` | Standalone page, **not linked from the taskpane UI** — reached only by navigating directly to its URL. Single-user self-service: grant/revoke your own Full Access on one mailbox at a time, split Sustainability/Energy. |
| `manage-mailbox-automapping.html` | Standalone page, **not linked from the taskpane UI** either. Reconciles "what Exchange says you have Full Access to" against "what's actually showing in your Outlook folder pane" — these drift apart and neither Graph nor Exchange exposes that comparison directly. Requires the user to import a local JSON export of their actual Outlook mailbox list (`{ mailboxes: [...], exportedAtUtc }`) via a file picker; that export is **not produced by this repo** — it comes from some other local tool/script the user runs against their own Outlook. Also tracks Outlook's ~32-mailbox folder-pane display limit. |
| `exchange-bridge/` | Azure Function (PowerShell 7.6) — see its own `README.md`, which is the authoritative, detailed doc. Summary below. |
| `exchange-bridge/README.md` | **Read this in full before touching the bridge.** Covers the two-app-registration trust model, why the originally-planned least-privilege Exchange RBAC didn't work (ended up needing the full Exchange Administrator directory role), the API contract, and a completed setup runbook. |
| `email-filing-sync/` | A **separate** Azure Function App (own Entra app registration, own resource group — never the bridge's) with a timer-triggered `SyncEmails` (watches every staff mailbox's "Master Email Management/Emails Awaiting Sync" folder — replaced the old flat "Emails to File" 2026-10-26 — files categorized emails into their project's SharePoint `Emails` folder, moves the originals into "Master Email Management/Emails Awaiting Sync/Synced Emails", formerly the flat "Filed" folder) and a temporary HTTP-triggered `RemediateCorruptedEmails` (see "2026-10-21/22 content-corruption incident" below — remove once remediation is confirmed complete, see that section). No signed-in user for either — see `email-filing-sync/README.md` for `SyncEmails`'s own design, which is authoritative for that function. **Status as of 2026-10-06: live in production**, including the >4MB upload-session path. This is what the taskpane's removed "Sync Emails" button/local desktop Filer used to do manually — it's now fully automatic. |
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
  "sync" step for staff to run. **The Summation Email Filer desktop app itself
  (installed per-machine, triggered by Win+`` ` ``) is legacy and no longer
  used (confirmed 2026-10-13)** — if it's still installed on someone's PC it
  does nothing useful anymore and can be uninstalled; don't point anyone at
  it or its installer for current email filing.

## Diagnostic round in progress (added 2026-10-16, remove once resolved)

Three things bundled into one manifest push rather than three separate propagation cycles, all
using `diagNotify()`/`withTimeout()` (`commands.js`) or `updateStatus()` (`taskpane.html`) as
the visible-without-DevTools channel, same technique proven out during the SharedRuntime spike
investigation:

1. **RESOLVED, diagnostic removed 2026-10-27**: File Email multi-select, re-tested in isolation
   via `Summation.FileEmailDiagButton` (manifest2.xml, `MessageReadCommandSurface`) →
   `fileEmailDialogHandlerDiag` (`commands.js`), which reran the retired ExecuteFunction +
   multi-select + `displayDialogAsync` combo with an 8s timeout at each step. Never actually
   resolved the original multi-select question either way — superseded by File Email's own
   dialog/bridge path being independently debugged and confirmed working end to end this same
   day (see "File Email is a dialog, not a wizard" below: the auto-close race, the manual
   Close-button race, and the bridge timing investigation). Removed the button
   (`manifest2.xml`), its handler, and the now-unused `diagNotify()`/`withTimeout()` helpers
   (`commands.js`) together, per the user's explicit instruction once File Email was confirmed
   working.
2. **File on Send's Smart Alerts redesign**, not yet live-tested at all: `onMessageSendHandler`
   now posts a marker at entry, after `categories.getAsync()` resolves (showing the actual
   category list), and right before calling `event.completed()` with the Take Action options —
   confirms each step actually ran even if the native Smart Alerts dialog itself doesn't appear
   or doesn't show the custom button as expected.
3. **Compose-time filing chain**, confirmed live up to the banner appearing, but the
   categorize-the-draft step hadn't been exercised yet: `onMessageComposeHandler` markers show
   the already-filed check's result, and `taskpane.html`'s `openComposeFilingDialog()` now
   narrates every step (dialog opening, message received + its action, the `categories.addAsync`
   call and its result) via `updateStatus()`.
4. **RESOLVED, diagnostic removed**: direct `displayDialogAsync` from `OnMessageCompose`,
   re-tested specifically (2026-10-16, to get hard confirmation rather than assume the
   `OnMessageSend` finding below generalizes). Result was more decisive than expected: it threw
   synchronously with `"Office.context.ui.displayDialogAsync is not a function"` — the API isn't
   merely restricted at runtime here, it's structurally absent from this execution context.
   Confirms with direct evidence, not inference, that auto-opening a dialog from a compose event
   handler isn't possible on this client.

**Bug found and fixed in the diagnostics themselves, 2026-10-16**: `diagNotify()` originally gave
each marker its own notification key so they'd stack into a visible history — but Outlook caps
notifications at **5 per message**, and that stacking silently consumed the InsightMessage
prompt's own slot. Confirmed live: 5 `DIAG` banners appeared, the real "Choose project" prompt
never did, with no error anywhere, since nothing in `showPrompt()` checked `addAsync`'s own
result. Fixed: `diagNotify()` now reuses one fixed key (`addAsync` once, `replaceAsync`
thereafter), reset at the top of each handler since notifications are scoped per mailbox item —
diagnostics now always occupy exactly one slot regardless of how many steps get logged.

**Status-message overwrite race found and fixed, 2026-10-19**: `openComposeFilingDialog()`'s
`"save"` handler called `updateStatus("Filed to X.")` unconditionally after
`categorizeViaGraph()` resolved, silently erasing any cache-sync-failure message the function had
just set moments before. Fixed: `categorizeViaGraph()` now returns `{cacheSynced,
cacheSyncError}` and the caller builds one combined final message from it instead of layering two
independent `updateStatus()` calls.

**`categorizeViaGraph()` given step-by-step `updateStatus()` markers, 2026-10-19**: previously
only the client-cache-sync tail end had any visibility; added one before/after each link in the
chain (`saveAsync`, `getItemIdAsync`, token acquisition, Graph `GET`, Graph `PATCH`) so a failure
anywhere in it is pinpointable from the status text alone, without needing DevTools.

**Dispatch theory ruled out live, 2026-10-19**: a screenshot showing the pane settled on its
general ACTIONS menu (not the picker) was initially read as evidence that
`openComposeFilingDialog()` never ran — i.e. the already-open-pane `contextData` fix regressing.
Directly contradicted by live confirmation: **the picker dialog did open.** Revised
understanding: the pane naturally rests on its general menu once the dialog closes (there's no
dedicated "just finished filing" view), and `#statusMessage`'s single quiet line is easy to miss
or scroll past once attention has been on the dialog — it was never a dispatch failure, just a
visibility gap in reporting whatever `categorizeViaGraph()` actually did. **Fixed**: an
always-visible top banner (`#diagTopBanner`, `taskpane.html`) now shows the dispatch decision
(`search`/`initContext`/`focContextRequested`) on load, and `updateStatus()` mirrors every
subsequent call into the same banner — so the whole chain, including the Graph-chain steps above,
is visible in one fixed place regardless of which view is on screen when the user looks.

**Root cause of "category still not appearing" found live, 2026-10-19**: the top-banner mirror
above (not a dispatch failure after all — the picker genuinely was opening) surfaced a concrete
error for the first time: `Could not read current categories (Graph GET 404)`, straight out of
`categorizeViaGraph()`'s first Graph call, right after `saveAsync()`/`getItemIdAsync()`/
`convertToRestId()`. This is a known class of race, not a logic bug: `saveAsync()` returns once
the EWS write lands, but Graph's own index of the mailbox can lag a short moment behind that
write, so an immediate `GET` on the just-created draft can 404 even though the save genuinely
succeeded. Explains the "worked once, then stopped" pattern (timing-dependent) and why the
master-category-cleanup revert — byte-identical to the last confirmed-working commit — didn't fix
it: that was never the actual cause. **Fixed**: `fetchWithRetryOn404()` (`taskpane.html`) wraps
both the Graph `GET` and `PATCH` with a short backoff (300ms/600ms/1200ms/2400ms, up to 4 retries)
scoped specifically to a 404 on this just-saved item; any other HTTP status still fails
immediately, same as before. **Not yet independently confirmed this resolves it** — reproduce
live (ideally on one of the "other projects" that reliably failed before) and read the banner
rather than assume; if it still 404s after all retries, the next thing to check is whether the
compose window is actually in a shared/delegate mailbox context, where `/me/messages/{id}` would
legitimately never find the draft (it would live under `/users/{mailbox}/messages/{id}` instead).

**Graph GET 404 retry fix confirmed live, 2026-10-19/20**: the banner showed the retry path firing
(404, retrying...) and then succeeding — category applied and visible on the sent email. The
404-right-after-`saveAsync()` race theory holds.

**Master-category-list cleanup, done properly as a deferred sweep, 2026-10-20**: the category
still works, but every project code ever filed this way permanently accumulates in the master
category picker — the 2026-10-19 attempt to remove it immediately after tagging broke the fix
(see above), so this redoes it the way that section said it had to be done: queue, don't remove
immediately. `ensureMasterCategory()` now queues each category it actually adds (localStorage key
`summation_pendingCategorySweep`, same convention as `FE_BATCHES_STORAGE_KEY` elsewhere in this
codebase) instead of removing it; `sweepPendingMasterCategories()` (called at the end of
`categorizeViaGraph()`, after this run's own category has been tagged onto the item) actually
removes everything *previously* queued via `masterCategories.removeAsync()` — never the entry
this run just added, which only gets queued for the run after it. By the time a previous run's
entry is swept, it's always a different, already-settled item, sidestepping the same-item timing
issue that broke the immediate-removal attempt. **Confirmed live 2026-10-20**: category survived
on the sent copy, and the master list cleaned up (the previous run's entry removed) once a
second filing run completed.

**End-to-end status as of 2026-10-20: the whole compose-time filing chain is confirmed working**
— InsightMessage banner → `commandId`/`contextData` dispatch → picker dialog → Graph write (with
404 retry) → client-cache-sync → deferred master-list sweep. Every individual bug this chain hit
is now fixed and live-verified.

**Item 3 (compose-time filing chain) diagnostics removed, 2026-10-21**: every `DIAG:`-prefixed
`updateStatus()`/`diagNotify()` call and the always-visible top banner (`#diagTopBanner`) are
gone from `taskpane.html`/`commands.js` — `updateStatus()` now shows plain, final-outcome
messages only (`"Filing to X..."`, `"Filed to X."`, or a plain error), and the retry/sweep
mechanisms this debugging round built stay in place, just silent unless they fail. Four more
changes landed in the same pass:
- `fetchWithRetryOn404()`'s retry count bumped from 4 to 6 attempts (now
  300/600/1200/2400/4800/9600ms backoff) for extra headroom on a slower Graph sync.
- A filing failure now also pops a `window.alert()` (`alertFilingFailure()`), in addition to the
  `updateStatus(..., true)` red line — the whole point of the extra retries is to make this a rare
  event, so when it does happen it needs to be impossible to miss rather than just a quiet status
  line the user might not be looking at.
- **"Save Both" casing bug found and fixed**: `file-on-send-dialog.html`'s `isReplyLike` check
  (and its `findOriginalMessage()`-driven Save Both/Reply Only UI, which was already fully built)
  compares `sendContext.composeType` against lowercase `"reply"`/`"forward"`, but
  `openComposeFilingDialog()` (`taskpane.html`) was passing `getComposeTypeAsync()`'s raw
  PascalCase value (`"Reply"`/`"Forward"`/`"NewMail"`) straight through unlowercased — so
  `isReplyLike` was always false, every real reply/forward got the single plain "Save" button, and
  Save Both never had a chance to run. Fixed by lowercasing `composeType` before it goes into the
  dialog's URL `context`. Save Both's own logic (`findOriginalMessage()`, `fileOriginalMessage()`
  via the exchange-bridge, same as a one-item File Email batch) was already correct and didn't
  need to change — it just never used to get the chance to run in this flow.
- **New: auto-apply the original's project code on a reply/forward**
  (`findOriginalMessageCategory()`, `taskpane.html`). Before opening the picker at all,
  `openComposeFilingDialog()` now checks (silent-token-only, never an interactive popup) whether
  "the original" — same best-effort conversationId lookup as Save Both's own `findOriginalMessage()`
  — already carries a project category, and if so calls `categorizeViaGraph()` with that same code
  directly, skipping the manual search-and-pick step entirely. Falls through to the normal picker
  if no original is found, the lookup fails, or the original isn't categorized. **Not yet
  live-tested** — reproduce on a reply to an already-filed thread and confirm it files without the
  picker appearing at all.

Item 1 is now resolved and removed (above). Item 2 (File on Send Smart Alerts) — this note is
stale: `commands.js` has had `FILE_ON_SEND_ENABLED = true` since 2026-10-21 (see "File on Send:
Smart Alerts redesign" below), so whatever's still "open" here hasn't been true for a while;
treat this whole section as historical background, not current status.

## File Email is a dialog, not a wizard (changed 2026-10-06)

**Partially reverted 2026-10-16**: the ribbon's dedicated File Email button's `ExecuteFunction`
change (described below) broke multi-select — confirmed live, the button would show Outlook's
generic "still working on your request" message and never complete when multiple messages were
selected. Root cause: `SupportsMultiSelect`/`SupportsNoItemContext` can only be declared on a
`ShowTaskpane` action per the Action element schema, never `ExecuteFunction` — confirmed via
Microsoft's own spam-reporting add-in docs, which describe the identical default behavior (an
`ExecuteFunction` button becomes unavailable whenever multiple messages are selected). This was
a latent bug from 2026-10-06 itself, not something introduced later — the 2026-10-13 schema fix
that removed those two (already-invalid-there) elements from the button's `ExecuteFunction`
action only exposed it, it didn't cause it.
`Summation.FileEmailButton` is back to `ShowTaskpane` → `FileEmail.Url`, the same dormant path
the V1.0 fallback used the whole time — `commands.js`'s `fileEmailDialogHandler` and its
detect-selection helpers were removed as dead code (nothing in the manifest points to them any
more). The **File Email tile** inside the taskpane (`Summation.TaskpaneButton`, always
`ShowTaskpane`) was never affected by any of this. Trade-off knowingly reaccepted: the original
keyboard-focus bug described below is back for the ribbon button's single-item case, since that
bug and multi-select support are opposite sides of the same `ExecuteFunction`-vs-`ShowTaskpane`
choice — Outlook doesn't offer a way to have both from one button.

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

**Confirm latency fix (2026-10-27)**: a user-reported delay between clicking "Add Category &
Stage for Filing" and seeing "Filing X — continuing in the background." Root cause: two
independent Graph reads (`findMasterCategory`, `getOrCreateEmailsToFileFolderId`) were `await`ed
one after the other in `handleFeConfirmInner`, both blocking that status message from rendering
at all. Three fixes, same shape as File on Send's own earlier latency work:
1. The two reads now run together via `Promise.allSettled` (each keeps its own independent
   fallback-on-error behavior, just concurrently instead of sequentially).
2. `getOrCreateEmailsToFileFolderId`'s result is now cached to localStorage
   (`feAwaitingSyncFolderIdCache:<username>`), not just the in-memory `feEmailsToFileFolderId`
   above it — this page is a *fresh dialog load every single time* File Email is used, so that
   in-memory cache never actually helped in practice; every real use was paying two sequential
   Graph round-trips to re-resolve an id that's permanent for all practical purposes once the
   folder exists. This is the main win: after the first use on a given browser profile, this
   entire resolution is skipped. Same stale-is-acceptable trade-off the project-folder-list cache
   already makes — a wrong cached id fails visibly later (via the bridge's own error reporting in
   the pending-batches notice), nothing here auto-heals it.
3. `postFeBatch`'s two token acquisitions (`mailWriteRequest`, `bridgeRequest`) also now run via
   `Promise.all` instead of sequentially — doesn't affect the visible pre-"continuing" delay
   (this function is already fire-and-forget relative to the UI), but makes the actual background
   filing finish sooner.

**Still slow on a cold cache, fixed same day**: fix #2 above only pays off from a dialog's
*second* real use onward — the very first time (or after clearing storage), both Graph calls in
`getOrCreateEmailsToFileFolderId` are still on the critical path at Confirm time, and a live user
test right after deploying fix #1-3 still showed a multi-second wait on "Filing X — continuing in
the background." Fix: `getOrCreateEmailsToFileFolderId` now memoizes its *in-flight promise*, not
just the resolved id, and `renderFeContext()` fires it speculatively (`startFolderIdPrefetch()`)
the moment the dialog opens and shows the project picker — the same already-shipped pattern
`loadFeFolderNames` uses for the project-folder list on this same page. By the time the user has
actually found and picked a project (a few seconds of human interaction, same order of magnitude
as the Graph round-trips themselves), the Confirm-time call usually just awaits an
already-settled promise instead of starting the work from scratch. A failed prefetch (e.g. an
interactive-consent popup getting blocked because it wasn't a direct click) clears the memo so
the real Confirm-time call — which *does* have a genuine user gesture — gets a clean retry rather
than inheriting a cached rejection.

**Timing diagnostics + the actual remaining cost, same investigation**: with the above fixes
live, a real test showed "Filing X — continuing in the background" now rendering in ~200ms (down
from several seconds) — but the dialog still visibly sat around for another ~1.5s before the
*background* bridge call (categorize + move, `FileEmailBatch`) actually finished. Added on-page
timing diagnostics (not just `console.log`, since this is an Office.js dialog inside Outlook's own
WebView where a normal user can't easily attach DevTools) rendered right into the result step,
marking: prefetch start/settle (relative to page load), pre-flight settle, batch-recorded,
UI-shows-message, and — once it actually lands — the background call's token-acquisition,
response, and full-completion times, all relative to when Confirm was clicked.

That data pinned the remaining ~1.5s squarely on `FileEmailBatch` itself, not on this dialog's own
JS. Investigated whether that's reducible: it does 3 sequential Graph calls per email (read
current categories → PATCH the merged set → move to the destination folder). The read is
load-bearing, not incidental — Graph's category PATCH *replaces* the whole array rather than
merging, and this exact codebase has already been burned once by reusing a stale categories
snapshot instead of a fresh read right before writing (see `SyncEmails`'s own comment on this).
PATCH-then-move can't combine into one Graph call, and categorizing before moving (not the
reverse) is itself relied upon elsewhere (the bridge's own "already-filed" retry-detection logic
assumes that fixed order). Checked the bridge's hosting region (Australia East — correct for an
AU tenant, not a mismatch) and confirmed `Import-Module ... -Force` on every invocation is
negligible (the module is 51 lines). Conclusion: ~1.5s for 3 necessary, correctly-ordered,
sequential Graph round-trips is close to an honest floor for this architecture — no safe code
change found that meaningfully cuts it further.

**Given that, re-enabled auto-close (2026-10-27)** — originally disabled 2026-10-07 while the
`AppDomains` manifest fix was still propagating (long since landed) and specifically to keep
pending-batch outcomes/errors visible instead of disappearing immediately. Since the remaining
background time can't be meaningfully shortened, there's no more "wait and watch" value in
keeping the dialog open through it.

**First attempt broke filing entirely, caught live within minutes**: closed immediately,
in parallel with (not after) kicking off the fire-and-forget `postFeBatch` call. This destroys
the dialog's whole JS execution context — including `postFeBatch`'s own in-flight MSAL token
acquisition, which hadn't even settled yet — before the actual `fetch()` to the bridge was ever
sent. Confirmed live: the email was neither categorized nor moved, and its tracked batch sat as
"still processing" indefinitely in the pending-batches notice, because nothing was ever
dispatched for the bridge to process in the first place. The existing "the bridge keeps a batch
running regardless of whether this dialog is still open" guarantee (relied on throughout this
file and `batch-file-dialog.html`) only ever applied from the moment Azure Functions actually
*receives* the request — closing before that moment doesn't interrupt work in progress, it
prevents the request from ever being made. **Fix**: the close is now chained onto
`backgroundBatch.finally(...)` — i.e. it waits for the fire-and-forget chain to actually settle
(success or failure) before calling `messageParent({action:"close"})` at all, so it can never
land earlier than the real work being done. This means the dialog still takes the full ~1.5–1.8s
(the bridge floor established above) to actually close, but that's the correct trade-off: a
close that can race ahead of the request it's supposed to follow isn't safe at any speed.

**Second source of the same race, found the same day**: more "still processing" batches were
reported even after the fix above landed. The manual `feCloseButton` had its own unconditional,
unguarded close handler, active the whole time "continuing in the background" is shown — clicking
it mid-flight is the identical destroy-the-JS-context-before-the-request-is-sent race, just
human-triggered instead of automatic. (Not directly observed being clicked, but it's the only
other unguarded close path left, and the symptom matches exactly.) Fixed by disabling that button
for the duration of `backgroundBatch`, with a 20s timed re-enable as an escape hatch in case
something is genuinely stuck. Also added a 60s `withTimeout` around `postFeBatch`'s own bridge
`fetch()` (previously unbounded) — without it, a truly hung bridge call would mean
`backgroundBatch` never settles, so neither the auto-close nor the Close-button re-enable would
ever fire, trapping the dialog open with no way out at all.

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

**Redesign, 2026-10-25 — categorize-only, no more moving the original**: the
paragraphs above describing "Save (Both/Reply Only)" firing `FileEmailBatch`
to **file and move** the original are now stale on two counts. First, the
2026-10-24 latency pass (not otherwise logged here) replaced the "abort its
own fetch after a brief delay" pattern with `postFeBatch()` splitting into
`sent` (tokens acquired, a `keepalive: true` fetch actually issued -- awaited)
and `result` (the bridge's eventual response -- fire-and-forget), plus
parallelizing the independent Graph lookups and caching the "Emails to File"
folder id, all to cut the close-delay on what was then still a categorize-
**and-move** action. Second, and more fundamentally: moving the original into
"Emails to File" immediately was found to drag an open, in-progress
reply/forward draft along with it -- a real UI side effect of relocating the
item a draft is replying to while that draft is still live, not a timing bug
fixable with a shorter delay. The fix is to stop moving it at all: this
dialog now only ever **categorizes**, never moves, anything. Buttons renamed
to match (**Categorise Both** / **Categorise Reply Only** / plain
**Categorise** for a new message) and a third option, **Categorise
Conversation**, added -- tags every message found via a `conversationId`
search (`/me/messages`, whole mailbox, not folder-scoped), not just the one
`findOriginalMessage()` guesses is "the original". A categorized original (or
older conversation message) now just sits wherever it already was; the user
moves it into "Emails to File" themselves when ready, the same manual staging
step File Email's own batch flow already relies on, and `SyncEmails`'s
existing staging-folder pass files and relocates it from there. Deliberately
**not** done as part of this change: extending `SyncEmails` with a matching
Inbox-wide scan (so a categorized-but-not-yet-staged original gets filed
automatically) -- full-Inbox scanning every 5 minutes for every staff mailbox
is a materially bigger job than the current small staging-folder scan, and
Graph has no efficient server-side filter on the `categories` property, so
this needs its own sizing/performance pass before being added. Relying on
manual staging for now.

**Simplified further, 2026-10-26 — two buttons, Inbox-scoped, inReplyTo
abandoned**: the three-button design above (Categorise Both / Conversation /
Reply Only) didn't survive contact with reality. **"Categorise Both"
(the single-"original" guess) is removed entirely.** `findOriginalMessage()`
first tried an exact match via Office.js's `LoadedMessageCompose.inReplyTo`
(an `internetMessageId`, not an approximation) — confirmed live, across both
forwards and a genuine reply, that it came back null with no error every
time on classic Outlook for Windows. Microsoft's own documented client
support table for requirement set 1.15, which that API needs, doesn't list
classic Windows Outlook at all — a real platform gap, not a bug in this
code. Before that, the plain `conversationId`-across-the-whole-mailbox
heuristic was confirmed live to repeatedly pick the wrong message (e.g. a
self-forward sitting in Sent Items instead of the real Inbox item). Given
both single-item approaches failed in practice, the fix is to stop picking
one at all: **"Categorise Conversation" now finds every message this
conversation has in the signed-in user's Inbox (root only, no subfolders)
and categorizes all of them** — there's no "right" item to identify, just
"everything currently there," removing the misidentification problem
structurally rather than patching the heuristic again. The confirm step
shows a live count ("Found N message(s) in your Inbox...") instead of a
single subject/sender preview. Down to two options now: **Categorise
Conversation** (the reply plus every Inbox match) and **Categorise Reply
Only** (just the reply) — "Categorise Conversation" also doubles as the
single action for a brand-new (non-reply) message, relabeled plain
**Categorise** in that case (`categoriseConversationButton` serves both
roles; see `handlePrimaryAction()`). `fileOriginalMessage()`,
`findOriginalMessage()`, `startOriginalMessageLookup()`, and
`taskpane.html`'s `getInReplyToMessageId()` are gone. Explicitly discussed
and declined: moving the found Inbox messages (immediately, or deferred
until the reply is confirmed sent/filed via a `SyncEmails` marker-category
trigger) — categorize-only, no move at all, is what shipped; a move
trigger remains a real option to revisit later if manual staging proves too
manual in practice.

**Folder restructuring, 2026-10-26 — "Master Email Management" replaces the flat
"Emails to File"/"Filed" model**: every staff mailbox now gets, under Inbox,
`Master Email Management` containing `Emails Yet to Label` (purely manual —
a place for staff to drag emails until they have time to file them, nothing
in this codebase reads or writes it), and `Emails Awaiting Sync` (the
`SyncEmails` staging-folder pass's new source, replacing "Emails to File")
containing `Synced Emails` (the new destination, replacing "Filed"). The
whole hierarchy is created automatically for any mailbox missing it —
`Get-OrCreateEmailManagementFolders` in `EmailFilingSync.psm1`, called by
`SyncEmails` every run. `file-email-dialog.html` and `batch-file-dialog.html`
both got the same nested-resolve treatment for the folder they stage into
before handing a batch to `FileEmailBatch`. **Transitional safety net,
read-only, never recreated:** `SyncEmails` still also checks the OLD flat
"Emails to File" folder for anything left over from before this shipped, so
nothing already staged there gets silently stranded — delete that fallback
block once every mailbox's old folder is confirmed empty. Deliberately *not*
done: a bulk migration script moving old-folder contents into the new
structure, or renaming the (unrelated) `"Filed"` Outlook *category* string —
neither was asked for, and the transitional read keeps old data flowing
without one.

**Found/fixed, 2026-10-26 — the "unrolled byte[]" PowerShell gotcha struck a
second time, this time as a host-crashing CPU spike, not silent corruption**:
while verifying the folder restructuring above actually worked in production,
`SyncEmails` runs kept dying ~90 seconds in (`DrainMode mode enabled` /
`Stopping the listener`, visible in Application Insights as a preceding
`Host CPU threshold exceeded` warning), never reaching their `run complete`
log line. Root cause: `Add-SummationLabelsHeader` in `EmailFilingSync.psm1`
did `return $combined` on a `byte[]` — the exact same missing-unary-comma
pattern as `ConvertFrom-CorruptedBytes` in the 2026-10-21/22 corruption
incident above, in a different function that the remediation pass back then
didn't think to check. This time the symptom was different because the
array is *much* bigger (a whole email's raw MIME bytes, not a short decoded
buffer): the Azure Functions PowerShell worker traces every unrolled
pipeline object individually regardless of whether the caller's plain
assignment (`$stampedBytes = Add-SummationLabelsHeader ...`) later
reassembles them, so filing one email with real content emitted roughly one
Application Insights trace line *per byte* — enough on its own to spike host
CPU and trigger a platform-level restart before the run could finish. Fixed
the same way: `return ,$combined`. **Lesson for next time**: grep
`EmailFilingSync.psm1` for `return \$[a-zA-Z]+$` (no leading comma) whenever
touching it — two other hits exist (`Get-GraphAllPages`'s `$items`,
`Get-ProjectFolderEntries`'s `$entries`), both arrays of Graph objects rather
than raw bytes, lower-impact since every current call site happens to
re-wrap the result in `@(...)` or a plain assignment, but the same
trace-flood mechanism applies at a smaller scale — not fixed yet, deliberately
out of scope for this pass.

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

**Important correction, confirmed live 2026-10-16**: the ~10-minute GitHub Pages cache is
necessary but **not sufficient** for an Outlook session that's already running. Classic Outlook
pulls the event-based bundle fresh at its own startup/add-in-initialization point (confirmed via
runtime logging: "Pulling the latest bundle.js for Event-based Add-in..."), not on every send —
so a teammate stuck mid-incident, with Outlook already open, kept seeing the OLD `commands.js`
behavior for several minutes after the GitHub Pages copy had already updated (verified directly
via `curl`), until they fully quit and reopened Outlook. **Flipping this kill switch during a
live incident must be paired with telling the affected user to restart Outlook, not just wait.**
If a restart doesn't clear it, disabling the add-in entirely from Outlook's own Get
Add-ins/Manage Add-ins UI is the next-fastest, code-independent escape hatch — it works
immediately regardless of any caching layer, since OnMessageSend just never runs.

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
- **`file-on-send-dialog.html`**: originally sent only `subject`+`conversationId` (no Graph
  round-trip), reasoning that `findOriginalMessage()`'s own lookup was already deferred until a
  project's picked and forcing it earlier would mean an interactive `mailWriteRequest` consent
  popping right as the dialog opens. **Confirmed live 2026-10-21 this was a materially weaker
  signal** — a reply produced few/no suggestions here while the identical thread's File Email
  suggestions (richer from/to/cc/body) worked fine. **Fixed**: `findOriginalMessage()`'s `$select`
  now also pulls `toRecipients`/`ccRecipients`/`bodyPreview`, and a new
  `startOriginalMessageLookup()` kicks it off right alongside `fetchSuggestions()` — silently
  (`isUserAction: false`, so the "no surprise popup" guarantee holds), sharing one result between
  both features instead of running the lookup twice. `selectProject()` now reuses that same
  promise for Save Both's own "Original" line, falling back to one interactive-capable retry only
  if the silent attempt came back empty.

**Real root cause found live 2026-10-21**: the richer from/to/cc/body fix above didn't fix it —
the dialog's own context box was rendering the subject as literally `[object Object]`. Unlike
Read mode, `item.subject` on a **Compose** item is not a plain string — it's an `Office.Subject`
object with its own `getAsync()`/`setAsync()`. `openComposeFilingDialog()` (`taskpane.html`) had
`subject: item.subject || "(no subject)"`, and since the object itself is truthy, that object
(not the fallback string) went straight into `JSON.stringify()`'d URL context, arriving at
`file-on-send-dialog.html` as `{}`. Beyond the cosmetic break, this silently broke
`fetchSuggestions()` entirely: `sendContext.subject` was an object, `.slice()` on it threw, caught
by that function's own `try/catch` — so suggestions never ran at all (not a weak-signal problem, a
never-even-called one). **Fixed**: `openComposeFilingDialog()` now awaits `item.subject.getAsync()`
properly before building the context. **Confirmed live 2026-10-21**: suggestions now appear.

**Save Both still greyed out, confirmed genuinely finding nothing — not the self-reply false
alarm**: ruled out live — the original sender was a real external address, not the signed-in
user's own. The "not sent by me" heuristic itself (or the conversationId match it depends on) is
failing for a real case. **Added, not yet a fix**: `findOriginalMessage()` now records *why* it
came back empty (`lastOriginalLookupResult`) — no conversationId at all, no token, Graph returned
zero messages for that conversationId (points at a conversationId mismatch between Office.js and
Graph), or Graph returned messages but every one was attributed to the signed-in user's own
address (points at the matching logic or a shared/delegate-mailbox from-address mismatch instead)
— and `selectProject()`'s "Original message not found" text now appends that reason. Next live
test should say which of these it actually is.

**Root cause confirmed live 2026-10-21**: the appended reason gave a hard answer —
`Graph API error: 400 Bad Request - {"error":{"code":"InefficientFilter","message":"The
restriction or sort order is too complex for this operation."}}`. This is a documented Microsoft
Graph limitation, not specific to this query: filtering `/me/messages` by `conversationId` while
also sorting by `receivedDateTime` can trigger `InefficientFilter` unless the request opts into
Graph's "advanced query parameters" mode. **Fixed**: `findOriginalMessage()`'s Graph `GET` now
adds the `ConsistencyLevel: eventual` header (via a new optional third argument on `graphGet()`)
and `$count=true` to the query string — Graph's own documented workaround for this exact error.

**That fix did NOT work, confirmed live 2026-10-21**: identical `InefficientFilter` error on a
second test email. Root cause per Graph's own "List messages" docs (confirmed via web search,
[Microsoft Q&A](https://learn.microsoft.com/en-us/answers/a/658420)): when `$filter` and
`$orderby` are combined, every property in `$orderby` must also appear in `$filter`, in matching
order. `receivedDateTime` was only ever in `$orderby` here, never in `$filter` — that's an
outright incompatible combination, not something advanced query parameters can override.
**Fixed properly**: dropped `$orderby` entirely, raised `$top` to 25, and sort the (small) result
set client-side by `receivedDateTime` instead — no ordering rule left to violate. Reverted the
now-unused `graphGet()` extra-headers parameter added for the first attempt. **Confirmed live
2026-10-21**: Save Both became clickable.

**Save Both confirmed clickable, but the original still wasn't getting filed — root cause found
live 2026-10-21**: the user's own "Recent File Email batches" notice (File Email's stuck-batch
recovery, shared `FE_BATCHES_STORAGE_KEY`) showed two Save-Both attempts that had sat "stuck" and
only succeeded once automatically retried later. Root cause: `handleSave()`'s original
fire-and-forget pattern for `fileOriginalMessage()` closed this dialog (and explicitly aborted the
in-flight bridge request via `AbortController`) just **500ms** after clicking Save Both — but
`fileOriginalMessage()` first awaits two sequential Graph round-trips (`findMasterCategory()`,
`getOrCreateEmailsToFileFolderId()`) before `postFeBatch()` even starts acquiring its own two
tokens and sending the POST, so that window was essentially never enough in practice; the request
was being killed before it ever reached the bridge, nearly every time. File Email's own
`handleFeConfirmInner()` (`file-email-dialog.html`) never had this problem because it deliberately
**disables its auto-close entirely** (see that function's own comment) and just leaves the dialog
open — that's what actually made it reliable, not anything specific to its token/scope setup
(confirmed separately that `MailboxBridge.Call` consent itself is fine — File Email's Confirm
reliably works). **Fixed**: `fileOriginalMessage()` now awaits `postFeBatch()` fully (no
`AbortController`, `postFeBatch()`'s now-unused `signal` parameter removed) and shows its real
outcome ("Original filed." / a queued-for-retry message with the actual error) in the existing
"Original" line; `handleSave()` only closes the dialog once that's actually done (plus a short
1.2s grace to read the result), and disables "Back to email" for that window so the user can't
re-introduce the same early-close problem manually. The batch is still durably tracked in
localStorage *before* the request starts either way, so File Email's existing stuck-batch recovery
remains the safety net if this dialog is ever killed externally (e.g. Outlook force-closing it).
Also fixed the dialog's static "Sending will pause until you choose an option." header text, which
was only ever accurate for the (currently always-off, `FILE_ON_SEND_ENABLED = false`)
`OnMessageSend`-triggered path — today this dialog only ever opens from the proactive compose-time
banner, which never blocks or resumes a send at all. **Not yet live-tested.**
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

- **Opened as a separate OS browser tab, not an Office.js dialog (changed 2026-10-13).**
  Originally `displayDialogAsync`, same as the other two pickers -- but a long run that
  categorizes-and-moves many emails out of the folder the user is actively viewing can
  disappear items from Outlook's own currently-displayed list in real time, which can trigger
  Outlook's "tear down the pane on selection change" behavior (the default once
  `SupportsMultiSelect` is on, unless the pane is pinned). That kills a dialog mid-batch with
  no warning -- confirmed live, root-caused by having the user select the *last* item in the
  folder before running it (nothing disrupted the selection early, and the whole folder went
  through cleanly). Switched to `taskpane.html`'s `openUrlInBrowser()` (the same
  `complete-action.html`/`email-search.html` pattern) instead: a real, separate OS browser
  process can't be touched by anything Outlook does to its own task pane. This means
  `batch-file-dialog.html` has **no Office.js context at all** now (no script tag, no
  `Office.onReady`, no `messageParent`/`closeContainer`) -- same reasoning as
  `complete-action.html`'s own header comment. It never had live-selection-forwarding or
  parent-initiated-close wiring to begin with (unlike `file-email-dialog.html`), so nothing
  was lost by dropping the dialog channel.
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
  **Update, 2026-10-13**: the self-closing-window problem above was a *dialog* problem
  specifically — separately root-caused (via the "select the last item in the folder" repro) to
  Outlook's own pane-teardown behavior being able to kill an Office.js dialog mid-run. Switching
  to a real OS browser tab (see this section's first bullet) removes that failure mode
  structurally, not just by shrinking the exposure window — Outlook has no way to touch an
  independent browser process at all. Combined with the front-loaded, result-checked dispatch
  above, both halves of the original "doesn't go through all emails" symptom have a real,
  targeted fix in place now. **Still not done**: nobody has re-run an actual large (hundreds of
  emails) batch against this exact current combination (browser tab + front-loaded dispatch) to
  confirm it end-to-end since the tab switch landed — worth doing once, rather than assuming,
  if this is ever raised again.
- **Group by conversation (added 2026-10-26)**: a checkbox (`bfGroupConversationCheckbox`,
  defaults on) that, once any row resolves to a real project — typed, picked from the datalist,
  or auto-suggested — fills every *other* row sharing its `conversationId` that's still blank
  with the same project. Untouched-only, same rule as the suggestion auto-fill it reuses styling
  from (`.suggested`, highlight + clear button): never overrides a row the user already set
  themselves. Deliberately conversation-only, not subject-based — `conversationId` is Graph's own
  reliable thread identifier; grouping by normalized subject instead was considered and rejected
  (risks merging unrelated emails that just happen to share a subject line). Turning the checkbox
  ON sweeps every already-resolved row retroactively against the whole table; turning it OFF
  leaves whatever's already filled in untouched, same "nothing visible gets clobbered" rule as
  everywhere else on this page.

## Mailbox Sync (2026-10-26)

A new taskpane tile (`mailboxSyncButton`, alongside Batch File Folder — no new ribbon button, no
manifest change) that closes a gap File on Send deliberately leaves open: File on Send tags a
sent reply/forward/new email with a project category but never moves anything (a deliberate
decision — see "File on Send is live" below), and any OTHER tagged message in the conversation
it found stays wherever it was too. Mailbox Sync is a manual, user-triggered sweep that finds
every email anywhere in Inbox (recursively through its subfolders) or Sent Items that already
carries a project-shaped category but was never staged, and moves each one into "Master Email
Management/Emails Awaiting Sync" — the same destination File Email stages into — so the existing
`SyncEmails` timer then files it from there. It never talks to SharePoint or the exchange-bridge
itself; it only moves emails via Graph.

- **Opens `mailbox-sync.html` via `openUrlInBrowser()` into a real OS browser tab, not an
  Office.js dialog** — same reasoning as Batch File Folder (see that section above): a sweep
  across a whole Inbox is exactly the kind of long-running operation Outlook's own pane-teardown
  behavior could kill mid-run if it were a dialog instead of an independent browser process. No
  selection to detect first (unlike Batch File Folder, which needs one selected email to find
  *which* folder to work through) — Mailbox Sync scans the whole mailbox, so it opens with no
  context param at all.
- **Scope, deliberately**: Inbox and every subfolder underneath it, walked recursively via
  `/childFolders`, plus Sent Items (not recursively — "sent folder" was asked for, not its
  subfolders). The whole "Master Email Management" subtree (`Emails Yet to Label`/`Emails
  Awaiting Sync`/`Synced Emails`) is excluded from the walk entirely, by display name, the moment
  it's encountered as a child of Inbox — it's the destination/staging area itself, so anything
  already staged or already synced must never be re-swept back into Awaiting Sync. Drafts/Junk/
  Deleted Items/Outbox are never reached by this walk at all, since they're siblings of Inbox in
  the mailbox tree, not descendants of it.
- **Matching**: a message qualifies if any of its categories matches the same project-code shape
  used everywhere else in this codebase (`/^[a-zA-Z]{5}\d{5}[_\s-]/`, mirroring
  `EmailFilingSync.psm1`'s `$ProjectCodePattern`) AND it doesn't already carry the `"Filed"`
  completion-marker category. There's no server-side Graph filter for "any category matching
  this shape" against an unbounded set of real project names (539 of them, per
  `Get-ProjectFolderEntries`) — doing one filtered query per possible project code would be far
  more expensive than it sounds. Instead every scanned folder is paged with a cheap
  `$select=id,subject,categories` and filtered client-side; this doesn't attempt to resolve the
  category to a real, currently-existing project folder at all (unlike File Email/Batch File
  Folder's own suggestion/validation) — that's `SyncEmails`'s job once the email lands in
  Awaiting Sync, and it already reports "no matching project folder" there if the category
  doesn't resolve to anything real.
- **Live progress, not a silent scan-then-report**: each matched email is logged (and moved) as
  soon as it's found, not after the whole mailbox has been collected first — folders scanned,
  emails checked, moved, and failed counts update continuously, since a large Inbox makes this a
  genuinely multi-minute operation. Moves are dispatched through a small concurrency gate
  (`MS_MOVE_CONCURRENCY = 4`, same enqueue/pump shape as `batch-file-dialog.html`'s own
  suggestion queue) rather than fired unbounded as matches are found, and each move's result is
  actually awaited and checked (succeeded/failed) before being counted — **not** the old
  fire-and-forget-without-checking-results pattern Batch File Folder's own Confirm step used to
  have (see that section's write-up on `fileGroup`'s dispatch bug above); one failed move is
  logged and the sweep continues, never aborts the rest of the mailbox.
- **Not done, deliberately**: no attempt to detect or warn about an email the user might
  specifically want to keep in Inbox forever without filing — if that's a real need, it doesn't
  exist as a concept anywhere else in this app either (File Email/File on Send would already have
  staged it), so Mailbox Sync doesn't introduce a new gap here, just inherits the existing one.
- **Naming**: CLAUDE.md's file inventory separately notes the old, retired taskpane "Sync Emails"
  button/local desktop Filer ("it's now fully automatic") — this is a different, narrower tool
  (find-and-stage already-labelled stragglers, not do the filing itself), but reuses a similar
  name on purpose, per explicit instruction, despite that history.

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

## Two small UI fixes (2026-10-08)

- `email-search.html`'s preview pane now shows `${projectCode}_${projectName}` in the
  `.pv-date` tag instead of just the bare code (data was already in the API response, just
  not displayed) — mirrored into `email-index`'s prototype `search.html` too, since that file's
  own `renderPreview` had the identical structure. Result-list rows' own smaller project tag
  (`renderResults()`) is untouched — out of scope.
- `file-email-dialog.html`'s service filter gained an "All" radio option, before Sustainability
  and Energy, now the default-checked one — `serviceFilterMatches()` short-circuits to `true`
  for it, so "All" just means no service filter rather than a third hardcoded list. Didn't
  touch `batch-file-dialog.html` — it has no equivalent Sustainability/Energy toggle at all
  (its combo maps are always loaded unfiltered), so there's nothing analogous to add there.

## Index-notify retries + visible failure logging (2026-10-08)

Prompted by a real incident: an email was correctly uploaded to SharePoint by
`email-filing-sync`, but didn't show up in search for over 90 minutes. Root cause turned out
to be `email-index`'s own `sync_timer` (its independent Graph-delta backstop, see that repo's
own notes) having a stuck delta cursor for the Active drive — but investigating it surfaced a
second, older problem worth fixing at the same time: both of this repo's "notify the index
right away" call sites were a single best-effort attempt that silently swallowed every
failure, on the historical reasoning that the index used to live at an unreachable
`127.0.0.1` address so failure was the permanent expected case. That hasn't been true for a
while — the index is a real hosted Function App now — but the silent-swallow code was never
revisited until now.

- **`email-filing-sync/Modules/EmailFilingSync/EmailFilingSync.psm1`'s `Invoke-IndexApi`**:
  now retries a transient failure (timeout/network/5xx) up to 5 attempts with a short
  backoff (2s/4s/8s, capped), fails fast without retrying on a 4xx (retrying a client error
  can't help), and surfaces an exhausted failure via `Write-Warning` instead of vanishing —
  confirmed today that Application Insights actually receives traces from this Function App
  now, so this isn't a no-op. Its return shape changed from bare data-or-`$null` to
  `[pscustomobject]@{ Success; Data }`, so `SyncEmails/run.ps1` can tell "exhausted and gave
  up" apart from "nothing configured, nothing attempted" (both have `Data = $null`) — updated
  both of its call sites (the Inbox pass and the Sent Items/File-on-Send pass) to capture and
  check `.Success` rather than discarding the result with `| Out-Null`.
- **`SyncEmails/run.ps1`'s `$totals`** gained `notifyFailed` and `sentNotifyFailed` (matching
  the existing `sent*` naming convention), incremented whenever a filing's notify call
  exhausts its retries, so a human skimming Application Insights can see at a glance whether
  notifies are failing on a given run — not just whether the save itself failed. The filing
  still always succeeds regardless of notify outcome; this is purely visibility.
- **`exchange-bridge/ReclassifyEmailBatch/run.ps1`'s `Send-IndexNotify`** (very recently
  added alongside Reclassify project, see that section above) had the exact same single-
  attempt swallow-everything shape — given the identical retry/backoff/fail-fast-on-4xx
  treatment and a `Write-Warning` on exhaustion, naming the batch id and message id so a
  failure is traceable to a specific reclassify. Not wired into any counter (ReclassifyEmailBatch
  already returns a per-item result array with its own `status`/`error` fields for the
  Graph copy/delete; notify failure was deliberately left out of that per-item status since
  it was never meant to affect whether reclassify itself reports success).

**Not yet confirmed**: no retry/backoff has been watched fire against the real hosted index
under an actual outage — this is written from first principles (same shape as other retry
code elsewhere in the codebase), not measured against a real failure yet.

## `email-index` sync_timer self-healing for a stuck delta cursor (2026-10-08)

The other half of the same incident above: `sync_timer`'s stored delta cursor for the Active
drive had gotten stuck, reporting zero new items on every run for over 90 minutes, even
though a fresh (un-cursored) delta walk immediately found the filed email. Fixed by hand that
day (clearing `sync_state.delta_link`/`next_link` to NULL for that drive, forcing the same
fresh-resync path `sync.py` already uses on a Graph 410) — but nobody had any visibility into
it until a human went looking, and the stuck cursor had no way to notice itself. This lives
in the separate `email-index` repo (`hosted/emailindex/sync.py` and `db.py`), not this one,
but is noted here too since the incident and the fix are one piece of work with the
index-notify changes above.

`DriveSync.run()` (`sync.py`) now tracks a `consecutive_empty_runs` counter per drive (new
`sync_state` column, `db.py`'s `SCHEMA`), reset to 0 whenever a completed run finds any delta
items at all. On a completed run that finds zero items, `check_stuck_cursor()` only acts once
that counter reaches 3 in a row (so a couple of minutes of normal Graph propagation lag is
never mistaken for stuck) — and even then, only if the `emails` table has picked up a row for
that same library with `indexed_at` newer than the drive's own `finished_at` from before this
run (i.e. filing *is* happening and the index *does* know about it, via the notify path above
— just not corroborated by this drive's own delta scan). If both are true, it clears that
drive's `delta_link`/`next_link` to NULL (the same fresh-resync path as a 410) and logs
exactly why via `log.warning` (consecutive empty-run count, newer-row count, the cutoff
timestamp compared against) so a future recurrence is debuggable from Application Insights
without a human needing to go hunting again.

**Not yet confirmed**: the "3 consecutive empty runs" threshold (~10-15 minutes at the timer's
5-minute cadence) is a reasonable first guess balancing "don't wait an hour like today"
against "don't react to one quiet run", not something watched fire for real yet — worth
revisiting if it either fires on a genuinely quiet period (too sensitive) or still takes too
long to catch a real stuck cursor (not sensitive enough).

## Compose-time filing nudge via InsightMessage (2026-10-13), replacing a retired SPIKE

A 2026-10-11 spike tried to force the task pane open automatically on compose by declaring
`Taskpane.Url` as a shared runtime (`manifest2.xml`) and calling `Office.addin.showAsTaskpane()`
from an `OnNewMessageCompose` event handler (`commands.js`). **Confirmed not viable**: tested on
both classic Windows Outlook and Outlook on the web, identical failure on both (the handler
either never fires or resolves as a silent no-op — ambiguous which, because Outlook's runtime
logging doesn't capture an add-in's own `console.log` output, only host-level manifest/loading
diagnostics). Ruling out a manifest-propagation delay (OWA doesn't cache manifests the way
classic desktop does, yet behaved identically) pointed to the real cause: **Outlook doesn't
support shared runtimes at all** — unlike Word/Excel/PowerPoint, every surface (task pane,
function command, event handler) runs in its own separate runtime process, so there's no
shared JS context for `showAsTaskpane()` to reach into from an event handler. All three
SPIKE-tagged pieces (the `SharedRuntime` manifest requirement, `Taskpane.Url`'s `lifetime="long"`
override, `onNewMessageComposeHandler` + its taskpane.html banner) were removed in the same
commit that added the replacement below.

**The replacement**: `onMessageComposeHandler` (`commands.js`), registered on `OnMessageCompose`
(Mailbox 1.12 — fires on new/reply/reply-all/forward *and* on reopening an existing draft,
broader than `OnNewMessageCompose`), calls `item.notificationMessages.addAsync()` with an
`InsightMessage` — "File this email to a project" with a "Choose project" action. The action's
`actionType: ActionType.ShowTaskPane` is a different, older, purpose-built mechanism (Mailbox
1.10) that opens the task pane *in response to the user's click* on the banner, rather than
programmatically forcing it open — Outlook natively supports this, since it's just Outlook's
own UI reacting to a real user gesture, not an add-in reaching across runtimes on its own. The
action's `commandId` ("Summation.ComposeTaskpaneButton") references the *existing*
`MessageComposeCommandSurface` button — no new manifest button or `SharedRuntime` declaration
needed, which is a big part of why this is lower-risk than the retired spike.

**Wired up to an actual picker (2026-10-16)**: `Summation.ComposeTaskpaneButton`'s
`SourceLocation` now points at a new deep link, `FileOnCompose.Url`
(`taskpane.html?view=fileOnCompose`), instead of the plain `Taskpane.Url` — both the manual
ribbon click and the InsightMessage's "Choose project" action (same `commandId`) land there.
`taskpane.html`'s new `openComposeFilingDialog()` opens **`file-on-send-dialog.html`** (the
same picker File on Send already built, searchable project search + optional "also file the
original" for a reply/forward) via `displayDialogAsync`, using the same
`{action:"ready"|"cancel"|"skip"|"save",categoryName}` dialog↔parent protocol
`onMessageSendHandler` already speaks to it. On `"save"`, the task pane tags the draft via
`categorizeViaGraph()` and closes the dialog — see "File on Send: Smart Alerts redesign..."
below (the "Root cause of the categorize step" paragraph) for why this isn't a direct
`item.categories.addAsync()` call.

Crucially, this is opened **from the task pane, not an event handler** — unlike
`onMessageSendHandler`'s own `displayDialogAsync` call (see "architecturally broken" below),
there's no restriction here, since by the time the user clicks through to the task pane, we're
well outside the event-handler context that blocks dialogs. This is what makes the InsightMessage
detour (event handler → native banner → user click → task pane → *then* a normal dialog) actually
work end to end, where directly calling `displayDialogAsync` from the event handler itself never
could.

**Already-filed check (2026-10-16)**: before showing the prompt, `onMessageComposeHandler` calls
`item.categories.getAsync()` and skips the notification if a project-shaped category
(`PROJECT_CATEGORY_PATTERN`, commands.js) is already present — e.g. a reply/forward that
inherited one from the original, or an email already filed through this same banner earlier.
If the check itself fails (including the known Outlook-on-the-web/new-Outlook compose-mode
categories restriction below), it defaults to showing the prompt anyway — there's no send to
protect here, so erring toward "still visible" beats silently never offering to file it. The
identical check gates `onMessageSendHandler` below, for the same reason.

**Already-open-pane bug found and fixed, 2026-10-16**: clicking "Choose project" opened the task
pane, but landed on its general menu instead of the picker — confirmed live. Root cause: Outlook
doesn't support a separate `TaskpaneId` per control *in Outlook* (explicitly "not supported in
Outlook" per the manifest `Action` element docs), so every `ShowTaskpane`-type control in this
add-in shares one pane instance. If Summation Assistant's pane was already open from earlier in
the session, the InsightMessage's `commandId` action just brought it to the front — it didn't
re-navigate to `FileOnCompose.Url`'s `?view=fileOnCompose` query string, so
`openComposeFilingDialog()` never ran. Fixed using Outlook's own documented mechanism for exactly
this case: the InsightMessage action now also sets `contextData: "fileOnCompose"`
(`commands.js`), and `taskpane.html` checks for it two ways — `getInitializationContextAsync()`
on a fresh load, and an `Office.EventType.InitializationContextChanged` handler (Mailbox 1.15,
already covered by this manifest) for the already-open-pane case, since which path Outlook
actually takes isn't something this code controls. Both paths converge on the same
`focContextRequested` flag that gates calling `openComposeFilingDialog()`.

**That fix itself regressed the banner's visibility, found and fixed 2026-10-19**: a clean
before/after split — the InsightMessage banner rendered reliably *before* `contextData` was
added above, and silently stopped rendering on every test since (`addAsync` kept reporting
`Succeeded`, but nothing ever appeared — confirmed on a forward, a deliberately blank new email,
and again after a full Outlook restart, ruling out both "forward/content-specific" and
"session-accumulated state" as the explanation). Root cause: `contextData` is typed as a plain
`string`, but Microsoft's own docs for it describe a `JSON.stringify()`/`JSON.parse()` round
trip regardless — a bare, non-JSON-encoded string was passed instead. Theory: `addAsync`'s own
validation is shallow (hence it kept reporting success), but the later rendering pipeline
silently chokes on a `contextData` value that isn't valid JSON. Fixed by JSON-encoding it
(`commands.js`) and parsing it back out on both paths (`taskpane.html`). **Not yet
independently confirmed this resolves it** — reproduce live before trusting it.

## File on Send: Smart Alerts redesign, re-enabled 2026-10-21 with a safer SendMode

**Current status: `FILE_ON_SEND_ENABLED = true`, `SendMode="PromptUser"` (manifest2.xml,
1.0.0.20).** Triggered by the user asking whether Save Both/Reply Only could actually let the send
through (they can't trigger a send on their own — Office.js has no API for a task pane or dialog
to invoke Send programmatically; this is the only mechanism that gets that experience, by letting
the user's own Send click be the trigger).

**Deliberately split into two steps, not pushed together**: `commands.js` deploys in ~10 minutes
via its own CDN cache, but the manifest's `SendMode` change needed a slower re-upload to the
Microsoft 365 admin center's Integrated Apps and propagation before it was actually live on the
client. Flipping `FILE_ON_SEND_ENABLED` to `true` in the *same* push as the manifest change would
have created a window where File on Send was active while the client was still running the OLD
manifest (`SendMode="SoftBlock"`) — exactly the risky combination that caused the incident below.
**Steps actually taken, in order**: (1) manifest2.xml (1.0.0.20) re-uploaded to the Microsoft 365
admin center via Integrated Apps → Summation Assistant → Update add-in → "Provide link to
manifest file" (`https://prassummation.github.io/outlook-addin/manifest2.xml`) → validated →
accepted; confirmed already scoped to "Just me (Pras@summation.au)" beforehand, not "Everyone", so
this only ever affected the one account; (2) user restarted Outlook (not just waited) to pick up
the new manifest, same lesson as the 2026-10-07 incident; (3) `FILE_ON_SEND_ENABLED` flipped back
to `true` in `commands.js`. **Not yet live-tested with an actual send** — the next real send that
gets intercepted should be checked for whether Outlook's native Smart Alert actually offers "Send
Anyway" (confirms `PromptUser` took effect, not a stale cached `SoftBlock` manifest).

All the root causes found during the 2026-10-16 to 2026-10-21 debugging arc are believed fixed by
the time step 3 happens: the Graph GET 404 right after `saveAsync()` (retry added), the
master-category cleanup race (deferred sweep instead of immediate removal), the compose-mode
`item.subject` object bug, and Save Both's dialog killing its own bridge request before it landed
(now awaits it fully instead of racing a timeout). `SendMode="PromptUser"` itself is the safety
margin for whatever isn't — see manifest2.xml's own comment on the `LaunchEvent` for why that
specifically matters (`PromptUser`'s native dialog includes a "Send Anyway" override; `SoftBlock`
only ever failed open if the *handler* errored/hung, never gave an escape once its own Take Action
dialog was already showing, which is exactly what trapped the user last time).

**2026-10-16 live-blocking incident (why this was off until now)**: the redesign below was
enabled, tested live, and immediately caused a real incident: the native Smart Alerts dialog
showed correctly (**Choose project** / **Don't Send**), but `SendMode="SoftBlock"` gave no "Send
Anyway" escape, and **Choose project** → task pane → `file-on-send-dialog.html` →
`categories.addAsync` wasn't completing the categorization — leaving the user fully unable to
send, stuck in a loop. Flipped back off within minutes (same kill switch as the 2026-10-07
incident; see that section's "Important correction" note above about also needing an Outlook
restart, not just waiting on the cache).

**Root cause of the categorize step found, 2026-10-16**: `item.categories.addAsync()` requires
the category to already exist in the mailbox's own master category list
(`Office.context.mailbox.masterCategories`) — confirmed in Microsoft's own docs and its sample
code's own comment ("In order for you to successfully add a category, it must be in the mailbox
categories master list"), failing with `InvalidCategory` otherwise. Every other place in this
codebase applies project categories via Microsoft Graph (`email-index`'s sync, Batch File
Folder, File Email's Graph-based filing, exchange-bridge's reclassify), which has no such
restriction — this compose-time flow was the first to call the Office.js API directly for an
arbitrary, just-picked project category, so it was the first to hit this, and did so 100% of the
time (any project not already in this specific mailbox's local master list, which in practice
meant most of them). Office.js categories APIs also don't work on a Compose-mode item at all on
Outlook on the web/new Outlook on Windows — a second, separate restriction Graph doesn't have
either.

**Fixed properly via Graph instead, not via Office.js at all** (`categorizeViaGraph()`,
`taskpane.html`), closing both gaps at once rather than working around just the first:
`item.saveAsync()` forces the still-composing draft to be saved (a brand-new compose item has no
Graph-addressable id until it has been), `item.getItemIdAsync()` returns the resulting EWS id
(there's no plain `itemId` property on a Compose item the way there is in Read mode),
`convertToRestId()` converts it, then a Graph `GET` + `PATCH` to `/me/messages/{restId}` sets the
category — `GET` first because Graph's `PATCH` to `categories` **replaces** the whole array
rather than merging (the same lesson already learned in `email-filing-sync`'s `sync.ps1`), so the
current categories are fetched and filtered (dropping any stale project tag,
`PROJECT_CATEGORY_PATTERN`) before appending the new one and writing back, rather than wiping out
whatever else a reply/forward may have inherited.

**No new Azure AD work needed**: a `Mail.ReadWrite` delegated permission is already present on
the "Summation Outlook Add-in" app registration *and* already has tenant-wide admin consent
(confirmed via `az ad app permission list-grants` — `consentType: "AllPrincipals"`) — it was
simply never requested at runtime before. `taskpane.html` now requests it via a new
`mailWriteRequest` scope object, same pattern as `sitesRequest`/`bridgeRequest`; no new consent
prompt should appear for users.

**This fix applies to the already-live compose-time "Choose project" banner too**, not just the
still-disabled File on Send flow — both share `openComposeFilingDialog()`. Before this fix, the
banner's categorize step was silently failing the same way, just without a blocked send to
surface it.

**Second bug found live, same day**: even with the Graph write succeeding, the category didn't
survive actually sending the email — confirmed live (picked a project, picker reported success,
sent category-less anyway). Corroborated by a related `office-js` GitHub issue describing the
same general class of problem: a category written via Graph isn't reflected in Outlook's own
client-side cache of the item. Working theory: classic Outlook holds its own in-memory copy of
the draft, and clicking **Send** pushes that stale, pre-Graph-write copy back to the server as
part of sending — silently overwriting the category Graph had just set, since the client never
learned about the change. Fixed by also writing the category into the client's own object model
via `item.categories.addAsync()` right after the Graph write succeeds (re-adding
`ensureMasterCategory()`, since that API's master-category-list requirement is unrelated to and
unaffected by anything Graph does). Graph stays the authoritative write — this step exists only
so the client's own save-at-send doesn't undo it, and is allowed to fail quietly if it doesn't
work (e.g. Outlook on the web/new Outlook on Windows, where this exact API doesn't function on a
Compose-mode item at all — there is currently nothing more this code can do on those clients with
what Office.js exposes). **Confirmed fixed live 2026-10-19** — category present on the actually-
sent copy, verified directly (not just the picker's own success message, which an earlier bug
briefly made unreliable — see "Add visibility to the client-cache-sync step" below).

**Master category list cleanup — tried and reverted same day, 2026-10-19**: `ensureMasterCategory()`
only needs the category in the master list long enough for `item.categories.addAsync()` to
accept it, and per live feedback it was never meant to permanently litter the mailbox's category
picker with every one-off project code the user happens to file. A fix was added
(`categorizeViaGraph()` removing the entry again via `masterCategories.removeAsync()` right after
tagging the item, only when `ensureMasterCategory()` itself had added it) — **and confirmed live
to break the actual fix above**: the category stopped surviving to the sent copy at all. Despite
the documented model (an item's `categories` are plain string names, not a reference to a
master-list entry), live behavior says otherwise here — removing the master entry while the
item-level add is still settling appears to invalidate it. **Reverted the same day**: the master
list now permanently accumulates one entry per distinct project code ever filed this way — an
accepted cosmetic trade-off for now, correctness over tidiness. If revisited, do it as a
**deferred sweep** (clean up entries from a *previous* run, tracked separately, never the one
just added in the current run) rather than retrying immediate removal with different timing.

**Decided 2026-10-21**: the `SendMode="PromptUser"` question above is settled (switched, see the
"re-enabling in progress" section above) — `FILE_ON_SEND_ENABLED` stays `false` until that manifest
change is confirmed live, per that section's step-by-step sequencing. The `diagNotify()` markers
that were in `onMessageSendHandler` have since been removed now that the compose-time filing chain
they covered is confirmed working — see "Diagnostic round in progress" below for that history;
this flow (`onMessageSendHandler` specifically) has never had a live send-triggered test of its
own since the 2026-10-16 incident, so that's the first thing to confirm once re-enabled.

Re-enabled (`FILE_ON_SEND_ENABLED = true`) using the redesign option 1 below actually calls for,
combined with option 2's commandId mechanism: `onMessageSendHandler` no longer calls
`displayDialogAsync` at all. Instead it calls `item.categories.getAsync()` first (same
already-filed check as the compose-time banner — already-tagged sends go through with no prompt
at all), and for everything else calls `event.completed({ allowEvent: false, errorMessage,
cancelLabel: "Choose project", commandId: "Summation.ComposeTaskpaneButton" })`. Outlook shows
its own native Smart Alerts dialog automatically (no custom code renders anything) with a **Take
Action** button (your build/channel naming — see Microsoft's table of **Don't
Send**-vs-**Take-Action** naming by client/version); clicking it opens the task pane via that
same `commandId`/`FileOnCompose.Url` deep link the compose-time banner already uses, which opens
the real picker (`file-on-send-dialog.html`) from the task pane, not an event handler — see the
"Compose-time filing nudge" section above for why that's the part that actually works. No new
manifest `Requirements` needed: requirement sets 1.14/1.15 govern whether the **button**
specifically renders, not whether the manifest parses, and this manifest's existing
`DefaultMinVersion="1.15"` already covers it.

**Trade-off inherent to this approach, not a bug**: `allowEvent: false` soft-blocks *that send
attempt*. Tagging the draft via the picker doesn't auto-resume the original send — the user has
to click **Send** again afterward, same as any other Smart Alerts nag (e.g. a missing-attachment
check). There's no way to both show a native Smart Alerts button and auto-continue the same send
once the picker closes.

**Known platform gap, not introduced by this change**: on Outlook on the web and new Outlook on
Windows, *"you can't use the API to manage categories applied to a message in Compose mode"*
(Microsoft's own words, `Office.Categories` reference) — this affects `categories.getAsync()`
*and* `categories.addAsync()` on a still-composing/still-sending item, which means both the
already-filed check and the actual tagging step are classic-Windows-Outlook-only in practice.
This was already true of the original 2026-10-06 File on Send build (it used the identical
`categories.addAsync` call) — not something this redesign introduces. Both handlers fail open
if the check errors, so web/new-Outlook users just see the normal, pre-existing behavior
(prompted every time, or the send going through) rather than a broken error.

## File on Send is architecturally broken, disabled pending a redesign (2026-10-11)

**Historical — see "fixed via Smart Alerts' native Take Action button" above for current
status.** Kept for the incident trail; the root-cause analysis below is still accurate, only the
"disabled" and "none implemented yet" framing is no longer current.

**What's wrong**: `onMessageSendHandler` (`commands.js`) calls
`Office.context.ui.displayDialogAsync` to open `file-on-send-dialog.html`'s project picker.
That call's callback **never fires at all** — confirmed deterministic (every single send, not
intermittent) via temporary `notificationMessages`-banner checkpoint markers added specifically
to diagnose this (removed again once confirmed, commit `b8fd119`). This isn't a timing bug or
an environment quirk: Microsoft's own `Outlook-Add-in-SSO-events` sample states it directly —
*"It's not possible to open a dialog from an event in Outlook"* — and the Dialog API docs scope
dialogs to "a task pane, content add-in, or add-in command," which excludes `OnMessageSend`
event-based activation entirely. `File Email`'s dialog works fine with the exact same
`displayDialogAsync` call because it's launched from a ribbon button (a normal function
command), not from an event handler — that's the structural difference, not anything about the
dialog itself.

**Incident trail for context** (all genuine fixes for genuine problems, none of which could
have fixed the actual blocker): the 2026-10-07 hang was traced to a missing `AppDomains` entry
(`d740991`) and fixed; a 2026-10-11 retest hit the identical symptom, which led to widening the
handler's safety-timeout into a single watchdog covering the whole handler instead of just the
dialog-already-open phase (`13a73e2`) — a real improvement (converts "hangs forever" into "fails
open after 20s"), but still can't make the dialog open. Only once the checkpoint markers showed
the stall was 100%-reproducible, always at the identical `getComposeTypeAsync` →
`displayDialogAsync` boundary, did the real, non-fixable-by-retry cause become clear.

**Options for an actual redesign** (none implemented yet — needs a product decision, not just a
code change):
1. **Drop the in-flow picker, keep a lightweight send-time nudge.** Smart Alerts (the
   `OnMessageSend`/`OnAppointmentSend` framework this handler already uses) can show Outlook's
   own simple alert via `event.completed`'s own parameters (a short message, optionally
   blocking the send) without any custom dialog — not a searchable project picker, just a
   plain prompt. Project selection would have to happen some other way (e.g., a required
   category convention, or a follow-up step).
2. **Move selection to a `notificationMessages` custom action** (requirement set 1.10,
   `ItemNotificationMessageType.InsightMessage` + `NotificationMessageDetails.actions`) —
   lets the user click a button in the notification banner itself, but still can't render a
   searchable list of hundreds of projects; at best a small fixed set of quick choices.
3. **Don't intercept the send at all — act after it, on the Sent Items copy.** This is what
   `email-filing-sync`'s existing Sent Items pass already does (see its own `README.md`'s
   section on this) for the *categorized* case. Extending that to prompt for a project
   *without* needing a send-time dialog would mean leaning entirely on that backstop plus
   `Batch File Folder`/`File Email` after the fact, dropping the "catch it at send time" UX
   goal rather than working around the platform limit.
4. **A task-pane-based nudge instead of event-based activation.** A task pane isn't an event
   handler, so it CAN host a real dialog — but a task pane also doesn't fire automatically
   when a user clicks Send; it would need a different trigger (e.g., prompting proactively
   while composing, not strictly "on send"), which changes the feature's premise.

None of these preserve the original "send → full project-picker dialog appears → pick →
tagged" flow exactly as designed; that flow is the part that's impossible from this context.
Whoever picks this back up should treat it as a redesign, not a bugfix.

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

## email-filing-sync: 2026-10-21/22 content-corruption incident, root-caused and fixed

Triggered by a user report that a filed email in a project's SharePoint `Emails` folder "contains
no information" — investigation found this was far bigger and more active than a single bad file.

**Scale, confirmed via a full scan (`RemediateCorruptedEmails`, mode `scan`, 2026-10-21)**: 2,936
distinct corrupted `.eml` files across 80 projects (~19% of all 15,096 filed emails scanned).
Failure volume in `SyncEmails` had also been climbing every single day since 2026-10-07 (670
failures that day, 3,331/day by 2026-10-20, ~29,800 total) — two bugs, both now fixed:

1. **`New-EmailFileName`'s `$Subject`/`$FromName` params lacked `[AllowEmptyString()]`** —
   PowerShell rejects an empty string for a `[Parameter(Mandatory)][string]` by default. A
   genuinely blank-subject email hit this every single retry, forever (16,000+ occurrences).
2. **`Invoke-RestMethod`'s content-type auto-detection for the `/$value` fetch** caused two
   separate problems: (a) decoding most responses as a .NET string roughly doubled peak memory,
   blowing the Consumption plan's hard 1.5GB-per-instance ceiling for emails with large
   attachments (13,500+ `OutOfMemoryException` occurrences, 107 distinct real emails never
   filed); (b) for some binary content types it returned something that wasn't exactly `[byte[]]`
   and silently got stringified via PowerShell's own default array-to-string join (each byte
   rendered as its decimal value, space-separated) instead of erroring — this is the actual
   corruption signature found in all 2,936 files. Switched to `Invoke-WebRequest` (whose
   `.Content` is far more consistently `byte[]`, though see the remediation bug below for why
   "consistently" still isn't "always"), removing the ambiguity rather than pattern-matching
   around it.
3. A size-based circuit breaker (skip/move messages too large to safely process instead of
   retrying forever) was attempted and **reverted the same day**: it depended on Graph's message
   `size` property, which this tenant's Graph resolver doesn't expose on **any** message query —
   confirmed live, fails with `"Could not find a property named 'size' on type
   'Microsoft.OutlookServices.Message'"` even on a bare `/me/messages` call. A HEAD request
   against `/$value` (hoping for a `Content-Length` without downloading the body) also isn't
   supported (405). A proper circuit breaker that doesn't depend on a property this tenant
   doesn't have is a deliberate follow-up, not yet built — the 107 OOM emails may now succeed
   anyway given the memory fix, worth checking before building anything more here.

**Remediation tooling**: `RemediateCorruptedEmails` (new HTTP-triggered function, temporary —
remove it and this section once remediation is confirmed fully complete) reuses `SyncEmails`'s
own `Get-GraphAppToken`/`Get-ProjectFolderEntries` helpers.
- **`mode: "scan"`**: read-only, peeks the first ~200 bytes of every `.eml` in every project's
  `Emails` folder (a corrupted file is *entirely* digits/whitespace throughout — a short peek is
  enough to tell apart from a real MIME header line). Resumable via `resumeIndex` (which project)
  **and** `resumeFileIndex` (which file within it) — a single project with thousands of filed
  emails was found live to never advance past folder-level resuming alone, since every resumed
  call just restarted peeking that same folder from file zero and hit the deadline at roughly the
  same position every time. Time-boxed to 45 seconds per call, not the function's own 9-minute
  `functionTimeout` — confirmed live that a long-running HTTP call isn't reliable on this
  Consumption plan regardless of client-side timeout settings (one call ran the full 7 minutes and
  completed successfully server-side; a later identical call got cut off by what looks like a
  platform-level instance recycle around 1m41s in, with the client-side connection separately
  timing out or resetting before ever seeing the response either way).
- **`mode: "fix"`**: takes a batch of files from a scan and actually remediates them. The
  corruption is **fully reversible** — decodes each file back to its original bytes (split the
  corrupted text on whitespace, parse each token as a 0-255 byte value) and overwrites it in
  place, but only after confirming the decoded content's first line actually looks like a real
  RFC 5322 header (`Header-Name: value`); anything that fails either the decode or the sanity
  check is left untouched and reported, never guessed at. No separate re-fetch from the original
  mailbox needed — the corrupted file alone already contains 100% of the information needed to
  reconstruct it.

**A second, genuinely tricky bug found live while first testing "fix"**: every attempt reported
`200 OK` and even created a *genuinely new SharePoint version* each time (confirmed via the
`/versions` endpoint, version numbers incrementing normally), yet the stored content — and even
its own size metadata — never actually changed, repeated identically across different content-
types, different addressing styles (`/items/{id}/content` vs `/items/{parentId}:/{name}:/content`,
both independently confirmed to work fine via an isolated trivial write), and different file
sizes. This looked exactly like a SharePoint retention policy or "declared record" setting might
be silently accepting writes as new version stubs while pinning the actual content immutable —
**ruled out** by a trivial hardcoded write to the exact same item succeeding perfectly, byte-for-
byte, on the first try. Root cause was actually in `ConvertFrom-CorruptedBytes` itself: `return
$bytes` (no leading comma) **unrolls a `byte[]` element-by-element onto the pipeline** — a classic
PowerShell gotcha. The caller's plain assignment (`$decoded = ConvertFrom-CorruptedBytes ...`)
reassembled those individually emitted, boxed byte values back into a generic `System.Object[]`,
not the original `byte[]` — confirmed directly via `$decoded.GetType().FullName`. This stayed
completely invisible through several rounds of diagnosis because
`[System.Text.Encoding]::GetString($decoded, ...)` (a .NET method call) still worked and produced
a perfectly correct preview — a method call's own argument binding coerces `object[]` back to
`byte[]` far more leniently than `Invoke-WebRequest`'s `-Body` parameter does, which instead
silently serialized the wrapped array as something that was not the real bytes. Fixed with the
unary comma operator: `return ,$bytes`. **Confirmed live, end to end**: `SUPER26102_Babylon`'s
filed email now reads correctly both via the Graph API and the local OneDrive-synced copy,
immediately, no propagation delay. **This exact gotcha struck again 2026-10-26** in a different
function (`Add-SummationLabelsHeader`) — see the "Found/fixed, 2026-10-26" entry under the folder
restructuring section above; worth a full grep of `EmailFilingSync.psm1` for this pattern before
trusting any new code added to it.

**Status as of 2026-10-22**: bulk remediation has been RUN and is complete. After the individual
test-file confirmations, a Node.js driver (byte-budgeted batches of ~800KB/5 files, 4-way
concurrency, 3 retries per batch, checkpointed to disk) ran the `fix` endpoint against all 2,933
remaining corrupted files. First-pass result: 2,926 fixed, 7 reported "failed". All 7 were
investigated directly (reading the live file content) and turned out to be false negatives, not
genuine failures — every one already contained valid, correctly-decoded content by the time it was
checked. The mechanism: a batch's HTTP call can succeed server-side (the fix lands) but still
appear to fail client-side (timeout/connection hiccup before the response is received), triggering
the driver's retry logic; the retry then correctly declines to "fix" an already-fixed file,
reporting a confusing-but-harmless "could not decode as the known corruption pattern" or similar.
A follow-up full re-scan is being run as an independent check to confirm zero corrupted files
remain (not yet complete as of this writing). Once confirmed, `RemediateCorruptedEmails` (the
function, its manifest entry, and this section) should be removed — it existed only to use the
Function App's own app-only Graph identity for a one-off job, not something this app should carry
around as permanent HTTP surface area.

## Where to look for more

- `git log --oneline` in this repo is a fairly reliable change narrative —
  commit messages here have been written descriptively, not just "update
  taskpane.html" (that style only appears in the very oldest history, before
  current conventions were adopted).
- `exchange-bridge/README.md` is the deepest, most current doc on the
  backend and is kept up to date — prefer it over re-deriving bridge
  behavior from the PowerShell source.
