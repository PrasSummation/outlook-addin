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
// EMERGENCY KILL SWITCH, re-tripped 2026-10-16: live-blocking incident confirmed -- the Smart
// Alerts dialog shows correctly (Choose project / Don't Send), but there's no way to send
// through untagged (SendMode="SoftBlock" gives no "Send Anyway"), and "Choose project" ->
// task pane -> file-on-send-dialog.html -> categories.addAsync isn't completing the
// categorization, leaving the user stuck unable to send at all. Flipping this back to false
// restores "every send allowed through immediately, untagged" while the categorize-then-send
// path gets fixed -- deploys in ~10 minutes via commands.js's own CDN cache, no manifest
// re-upload needed, since OnMessageSend's LaunchEvent registration itself hasn't changed.
const FILE_ON_SEND_ENABLED = false;

// Shared by onMessageSendHandler and onMessageComposeHandler: matches the project-category
// naming convention this codebase already uses everywhere else (email-index's keywords.py,
// email-filing-sync's sync.ps1) -- 5 letters + 5 digits + "_" or "-", e.g. "SUPER26099_...".
const PROJECT_CATEGORY_PATTERN = /^[a-zA-Z]{5}\d{5}[_-]/;

// DIAGNOSTIC HELPERS, added 2026-10-16 -- temporary, remove once the two things below are
// settled one way or the other: (1) whether File Email's ExecuteFunction+multi-select+dialog
// combo can be made to work at all (fileEmailDialogHandlerDiag, below), (2) whether the Smart
// Alerts File on Send redesign (onMessageSendHandler, above) actually reaches and shows its
// Take Action button live. Classic Outlook's event/function-command runtime has no DevTools and
// runtime logging doesn't capture this add-in's own console output (confirmed earlier this
// session) -- notificationMessages banners on the live item are the one channel proven to
// actually show up without either of those.
//
// FIXED 2026-10-16: originally gave each marker its own key so they'd stack into a visible
// history -- but Outlook caps notifications at 5 per message, and that stacking silently ate
// the InsightMessage prompt's own slot (confirmed live: 5 DIAG banners appeared, the real
// "Choose project" prompt never did, no error anywhere since nothing checks that addAsync's own
// result). Now reuses one fixed key via replaceAsync once it exists, so diagnostics always
// occupy exactly one slot no matter how many steps get logged, leaving four free for real
// content. If you need the pre-replace behavior back to see the stepped history, read it from
// console.log on a client that has DevTools (web/new Outlook/Mac) instead of changing this back.
let diagNotificationExists = false;
function diagNotify(message) {
  console.log("DIAG:", message); // free on clients that do have a console (web/new Outlook/Mac)
  try {
    const item = Office.context.mailbox.item;
    if (!item || !item.notificationMessages) return;
    const details = {
      type: Office.MailboxEnums.ItemNotificationMessageType.InformationalMessage,
      message: "DIAG: " + message,
      icon: "icon-16",
      persistent: true
    };
    if (diagNotificationExists) {
      item.notificationMessages.replaceAsync("summation_diag", details);
    } else {
      item.notificationMessages.addAsync("summation_diag", details, (result) => {
        if (result.status === Office.AsyncResultStatus.Succeeded) diagNotificationExists = true;
      });
    }
  } catch (err) {
    console.error("diagNotify threw:", err);
  }
}

// Races a promise against a timer so a diagnostic run fails fast and visibly instead of
// hanging until Outlook's own multi-minute platform timeout -- the exact failure mode that
// made the original File Email multi-select bug look like total silence.
function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(label + " did not resolve within " + ms + "ms")), ms);
    promise.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); }
    );
  });
}

function onMessageSendHandler(event) {
  diagNotificationExists = false; // notifications are per-item -- this invocation is a fresh item
  diagNotify("onMessageSendHandler invoked, FILE_ON_SEND_ENABLED=" + FILE_ON_SEND_ENABLED);

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
      diagNotify("categories.getAsync FAILED: " + (result.error && result.error.message) + " -- allowing send");
      console.error("onMessageSendHandler: couldn't read categories, failing open:", result.error);
      event.completed({ allowEvent: true });
      return;
    }

    const names = (result.value || []).map((c) => c.displayName).join(", ") || "(none)";
    const alreadyFiled = (result.value || []).some((c) => PROJECT_CATEGORY_PATTERN.test(c.displayName || ""));
    diagNotify("categories.getAsync resolved: [" + names + "] -- alreadyFiled=" + alreadyFiled);

    if (alreadyFiled) {
      event.completed({ allowEvent: true });
      return;
    }

    diagNotify("calling event.completed() with Take Action commandId -- watch for Outlook's own Smart Alerts dialog now");
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
  diagNotificationExists = false; // notifications are per-item -- this invocation is a fresh item
  diagNotify("onMessageComposeHandler invoked");

  // RESOLVED 2026-10-16, diagnostic removed: direct-called Office.context.ui.displayDialogAsync
  // from this exact handler to re-test whether it works specifically on OnMessageCompose (the
  // "architecturally broken" finding and Microsoft's "Unsupported APIs" table originally covered
  // OnMessageSend only). Result was more decisive than expected: it threw synchronously with
  // "Office.context.ui.displayDialogAsync is not a function" -- the API isn't merely restricted
  // at runtime here, it doesn't exist at all in this execution context. Confirms, with direct
  // evidence rather than inference, that auto-opening a dialog from a compose event handler is
  // not possible on this client. Not revisiting without new information.

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
    const names = result.status === Office.AsyncResultStatus.Succeeded
      ? (result.value || []).map((c) => c.displayName).join(", ") || "(none)"
      : "FAILED: " + (result.error && result.error.message);
    const alreadyFiled = result.status === Office.AsyncResultStatus.Succeeded
      && (result.value || []).some((c) => PROJECT_CATEGORY_PATTERN.test(c.displayName || ""));
    diagNotify("categories.getAsync: [" + names + "] -- alreadyFiled=" + alreadyFiled);

    if (alreadyFiled) {
      diagNotify("already filed -- skipping the InsightMessage prompt");
      event.completed();
    } else {
      diagNotify("not filed -- calling notificationMessages.addAsync for the InsightMessage prompt now");
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

// DIAGNOSTIC, 2026-10-16: re-tests the retired ExecuteFunction + multi-select + displayDialogAsync
// combo in isolation, with bounded timeouts and diagNotify markers at every step, to pin down
// exactly where it hangs rather than rely on inference from Microsoft's docs alone. Wired to a
// separate, clearly-labeled diagnostic-only ribbon button (Summation.FileEmailDiagButton,
// manifest2.xml) so the real File Email button stays on its fixed ShowTaskpane path throughout
// this test -- selecting multiple messages and clicking THIS button is the test; the regular
// File Email button is not involved. Remove this function, its associate() call, and its
// manifest button together once the multi-select question is settled either way.
function fileEmailDialogHandlerDiag(event) {
  diagNotificationExists = false; // notifications are per-item -- this invocation is a fresh item
  diagNotify("fileEmailDialogHandlerDiag invoked");

  const getSelected = new Promise((resolve, reject) => {
    Office.context.mailbox.getSelectedItemsAsync((result) => {
      if (result.status === Office.AsyncResultStatus.Succeeded) resolve(result.value);
      else reject(result.error || new Error("getSelectedItemsAsync failed"));
    });
  });

  withTimeout(getSelected, 8000, "getSelectedItemsAsync")
    .then((selected) => {
      const count = (selected || []).length;
      diagNotify("getSelectedItemsAsync resolved with " + count + " item(s)");

      const url = "https://prassummation.github.io/outlook-addin/file-email-dialog.html?context=" +
        encodeURIComponent(JSON.stringify({ mode: count > 1 ? "multi" : "single", items: [] }));

      const openDialog = new Promise((resolve, reject) => {
        Office.context.ui.displayDialogAsync(url, { height: 70, width: 40 }, (asyncResult) => {
          if (asyncResult.status === Office.AsyncResultStatus.Failed) reject(asyncResult.error);
          else resolve(asyncResult.value);
        });
      });
      return withTimeout(openDialog, 8000, "displayDialogAsync");
    })
    .then((dialog) => {
      diagNotify("displayDialogAsync succeeded -- dialog opened, closing it now (diagnostic only)");
      try { dialog.close(); } catch (err) { /* ignore */ }
      event.completed();
    })
    .catch((err) => {
      diagNotify("FAILED: " + (err && err.message ? err.message : String(err)));
      event.completed();
    });
}

Office.actions.associate("fileEmailDialogHandlerDiag", fileEmailDialogHandlerDiag);
