/*
 * File on Send -- redesigned 2026-10-16 on Smart Alerts' native "Take Action" button
 * (requirement sets 1.14/1.15), replacing the 2026-10-06 go-live build that tried to open
 * file-on-send-dialog.html directly from this handler via displayDialogAsync. That approach
 * is disabled for good reason, kept below for context: Office.context.ui.displayDialogAsync
 * cannot be called from an event-based handler in Outlook at all (confirmed deterministic,
 * every single send; Microsoft's own Outlook-Add-in-SSO-events sample states it directly --
 * "It's not possible to open a dialog from an event in Outlook" -- and the Dialog API docs
 * scope dialogs to "a task pane, content add-in, or add-in command", which excludes
 * OnMessageSend entirely). See CLAUDE.md's "File on Send is architecturally broken" section
 * for the full incident trail.
 *
 * The redesign sidesteps that restriction entirely by never trying to open anything from this
 * handler. Instead, event.completed()'s own commandId option tells Outlook to show a
 * "Take Action" button on its own native Smart Alerts dialog -- a real user click Outlook
 * handles itself, not something this code forces open. Clicking it opens the task pane via
 * Summation.ComposeTaskpaneButton's SourceLocation (FileOnCompose.Url, manifest2.xml), the
 * same deep link the compose-time InsightMessage banner already uses, which in turn opens
 * file-on-send-dialog.html from the task pane -- not an event handler, so the restriction
 * above doesn't apply there at all. See taskpane.html's openComposeFilingDialog().
 *
 * This file is loaded two different ways depending on the Outlook client: classic Outlook on
 * Windows loads it directly in a JavaScript-only runtime (no HTML, no office.js <script> tag,
 * no imports, no Office.onReady/Office.initialize); every other client (web, new Outlook on
 * Windows, Mac) loads it via an ordinary <script src="commands.js"> tag inside commands.html,
 * after office.js has already loaded there. Both paths land here with an already-usable
 * Office global, which is why there's no Office.onReady wrapper -- adding one would just
 * never fire on classic Windows.
 *
 * The manifest's SendMode="SoftBlock" means Outlook itself lets the send through if this
 * handler throws, hangs, or never calls event.completed() within its own platform timeout --
 * a deliberate safety net this code leans on rather than duplicates.
 */
const FILE_ON_SEND_ENABLED = true;

// Shared by onMessageSendHandler and onMessageComposeHandler: matches the project-category
// naming convention this codebase already uses everywhere else (email-index's keywords.py,
// email-filing-sync's sync.ps1) -- 5 letters + 5 digits + "_" or "-", e.g. "SUPER26099_...".
const PROJECT_CATEGORY_PATTERN = /^[a-zA-Z]{5}\d{5}[_-]/;

function onMessageSendHandler(event) {
  if (!FILE_ON_SEND_ENABLED) {
    event.completed({ allowEvent: true });
    return;
  }

  const item = Office.context.mailbox.item;

  // Already tagged (e.g. via the compose-time banner, or inherited from replying to an
  // already-filed thread) -- let it through without nagging a second time. getAsync returns
  // CategoryDetails objects (.displayName), NOT the plain strings addAsync/removeAsync take --
  // different shape for input vs output, easy to get backwards.
  item.categories.getAsync((result) => {
    if (result.status === Office.AsyncResultStatus.Failed) {
      // Can't even tell -- same "never trap a send over our own error" philosophy as
      // everywhere else in this handler. Includes the known case of Outlook on the web/new
      // Outlook on Windows, where the categories API isn't available on a Compose-mode item
      // at all (confirmed Microsoft platform limitation, not a bug here).
      console.error("onMessageSendHandler: couldn't read categories, failing open:", result.error);
      event.completed({ allowEvent: true });
      return;
    }

    const alreadyFiled = (result.value || []).some((c) => PROJECT_CATEGORY_PATTERN.test(c.displayName || ""));
    if (alreadyFiled) {
      event.completed({ allowEvent: true });
      return;
    }

    event.completed({
      allowEvent: false,
      errorMessage: "File this email to a project before sending.",
      cancelLabel: "Choose project",
      commandId: "Summation.ComposeTaskpaneButton"
    });
  });
}

Office.actions.associate("onMessageSendHandler", onMessageSendHandler);

// SPIKE RETIRED, 2026-10-13: the SharedRuntime + Office.addin.showAsTaskpane() approach tried
// here (force the task pane open automatically from OnNewMessageCompose) doesn't work on
// Outlook -- confirmed empirically on both classic Windows Outlook and Outlook on the web
// (identical failure on both, ruling out a manifest-propagation delay). Root cause: Outlook
// doesn't support shared runtimes at all (each surface -- task pane, function command, event
// handler -- runs in its own separate runtime process), unlike Word/Excel/PowerPoint where
// showAsTaskpane() is designed to work. See CLAUDE.md's "File on Send is architecturally
// broken" section for the same underlying constraint. Replaced below by an InsightMessage
// notification + its native ShowTaskPane action, which opens the pane in response to an
// actual user click instead of trying to force it open programmatically.

// Fires on composing a new message (including reply/reply all/forward) AND on reopening an
// existing draft -- OnNewMessageCompose (the retired spike's event) misses drafts entirely,
// which is why this uses OnMessageCompose instead (Mailbox requirement set 1.12, already
// covered by this manifest's DefaultMinVersion 1.15).
function onMessageComposeHandler(event) {
  const item = Office.context.mailbox.item;

  function showPrompt() {
    try {
      item.notificationMessages.addAsync(
        "summation_file_prompt",
        {
          type: Office.MailboxEnums.ItemNotificationMessageType.InsightMessage,
          message: "File this email to a project",
          icon: "icon-16",
          actions: [
            {
              actionText: "Choose project",
              actionType: Office.MailboxEnums.ActionType.ShowTaskPane,
              // Matches Summation.ComposeTaskpaneButton's id in manifest2.xml's
              // MessageComposeCommandSurface -- that control's SourceLocation is
              // FileOnCompose.Url, which opens straight into the project picker.
              commandId: "Summation.ComposeTaskpaneButton"
            }
          ]
        },
        () => event.completed()
      );
    } catch (err) {
      console.error("onMessageComposeHandler: threw synchronously:", err);
      event.completed();
    }
  }

  // Already tagged (e.g. a reply/forward that inherited a category from the original) --
  // don't nag. If the check itself fails (including on Outlook on the web/new Outlook on
  // Windows, where the categories API isn't available on a Compose-mode item at all), default
  // to showing the prompt anyway -- unlike the send-time handler there's no send to protect
  // here, so erring toward "still visible" beats silently never offering to file it.
  item.categories.getAsync((result) => {
    const alreadyFiled = result.status === Office.AsyncResultStatus.Succeeded
      && (result.value || []).some((c) => PROJECT_CATEGORY_PATTERN.test(c.displayName || ""));
    if (alreadyFiled) {
      event.completed();
    } else {
      showPrompt();
    }
  });
}

Office.actions.associate("onMessageComposeHandler", onMessageComposeHandler);

// File Email's dedicated ribbon button (manifest2.xml's Summation.FileEmailButton) reverted
// to ShowTaskpane on 2026-10-16, after multi-select silently never resolved
// (getSelectedItemsAsync hanging) when invoked through this file's now-removed
// fileEmailDialogHandler -- see manifest2.xml's comment on that Control for the full history.
// The button now opens taskpane.html?view=fileEmail directly, the same dormant path the V1.0
// fallback already used throughout; no JS here needed any more.
