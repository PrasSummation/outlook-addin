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

/*
 * File Email, launched directly from the ribbon's dedicated "File Email" button
 * (manifest2.xml's V1.1 Summation.FileEmailButton, ActionType="ExecuteFunction" as of
 * 2026-10-06 -- it used to be ActionType="ShowTaskpane", deep-linking into taskpane.html).
 * Changed because a task pane Outlook opens *fresh* wasn't reliably getting real OS
 * keyboard focus for the picker's search box -- confirmed in real Outlook, even after
 * retrying .focus() on a timer and on window focus/visibilitychange events. Running this
 * from here instead bypasses the task pane for this entry point entirely: it detects the
 * selection the exact same way taskpane.html's own File Email tile does (duplicated, not
 * shared -- this file and taskpane.html can't share a JS module, same as every other
 * duplicated constant/helper across this app's pages), then opens the same dialog,
 * file-email-dialog.html, which is where the actual picker UI, Confirm, and the
 * categorize+move batch all live now (see that file's own header comment).
 *
 * Selection tracking while the dialog is open: registers its own SelectedItemsChanged
 * listener (separate from taskpane.html's) for as long as this one dialog is open, removed
 * again once it closes. Whether that listener keeps firing for the full time the dialog
 * stays open depends on whether this host keeps a function-command's execution context
 * alive after event.completed() -- confirmed true for classic Outlook on Windows (its
 * JS-only runtime persists across invocations in practice), not independently confirmed
 * for every other client. If it turns out a given host tears this down early, picking a
 * different email while the dialog opened from the *ribbon button* specifically is open
 * just wouldn't update it there -- the dialog itself, and the taskpane tile's own path,
 * aren't affected either way.
 */

function officeAsyncCmd(target, method) {
  const args = Array.prototype.slice.call(arguments, 2);
  return new Promise((resolve, reject) => {
    target[method].apply(target, args.concat([(result) => {
      if (result.status === Office.AsyncResultStatus.Succeeded) resolve(result.value);
      else reject(result.error || new Error(method + " failed"));
    }]));
  });
}

function detectFileEmailSelectionCmd() {
  return officeAsyncCmd(Office.context.mailbox, "getSelectedItemsAsync").then((selected) => {
    const messages = (selected || []).filter((i) => (i.itemType || "").toLowerCase() === "message");
    if (messages.length > 0) {
      return {
        mode: messages.length > 1 ? "multi" : "single",
        items: messages.map((i) => ({
          restId: Office.context.mailbox.convertToRestId(i.itemId, Office.MailboxEnums.RestVersion.v2_0),
          subject: i.subject || "(no subject)"
        }))
      };
    }
    return detectFileEmailSelectionFromSingleItem();
  }, (err) => {
    console.error("Could not read the current multi-selection:", err);
    return detectFileEmailSelectionFromSingleItem();
  });
}

function detectFileEmailSelectionFromSingleItem() {
  const singleItem = Office.context.mailbox.item;
  if (singleItem && singleItem.itemType === Office.MailboxEnums.ItemType.Message) {
    return {
      mode: "single",
      items: [{
        restId: Office.context.mailbox.convertToRestId(singleItem.itemId, Office.MailboxEnums.RestVersion.v2_0),
        subject: singleItem.subject || "(no subject)"
      }]
    };
  }
  return { mode: "none", items: [] };
}

function fileEmailDialogHandler(event) {
  detectFileEmailSelectionCmd().then((context) => {
    const url = "https://prassummation.github.io/outlook-addin/file-email-dialog.html?context=" +
      encodeURIComponent(JSON.stringify(context));

    Office.context.ui.displayDialogAsync(url, { height: 70, width: 40 }, (asyncResult) => {
      if (asyncResult.status === Office.AsyncResultStatus.Failed) {
        console.error("Could not open File Email dialog:", asyncResult.error);
        event.completed();
        return;
      }

      const dialog = asyncResult.value;
      let selectionHandlerRegistered = false;

      function forward() {
        detectFileEmailSelectionCmd().then((updated) => {
          try { dialog.messageChild(JSON.stringify(updated)); } catch (err) { /* dialog likely closed */ }
        });
      }

      if (Office.context.mailbox.addHandlerAsync) {
        Office.context.mailbox.addHandlerAsync(Office.EventType.SelectedItemsChanged, forward, (res) => {
          selectionHandlerRegistered = res.status === Office.AsyncResultStatus.Succeeded;
        });
      }

      // Parent-initiated close, same reasoning as taskpane.html's entry point: the
      // dialog's own closeContainer() call on itself turned out to be the unreliable part,
      // confirmed live -- manually closing the dialog window after Confirm always let the
      // batch finish filing correctly regardless. dialog.close() from here, on this
      // host-held handle, is the same kind of close as that manual one.
      dialog.addEventHandler(Office.EventType.DialogMessageReceived, (arg) => {
        try {
          const message = JSON.parse(arg.message);
          if (message.action === "close") dialog.close();
        } catch (err) { /* ignore malformed messages */ }
      });

      dialog.addEventHandler(Office.EventType.DialogEventReceived, () => {
        if (selectionHandlerRegistered && Office.context.mailbox.removeHandlerAsync) {
          Office.context.mailbox.removeHandlerAsync(Office.EventType.SelectedItemsChanged, { handler: forward });
        }
      });

      event.completed();
    });
  }).catch((err) => {
    console.error("File Email ribbon handler failed:", err);
    event.completed();
  });
}

Office.actions.associate("fileEmailDialogHandler", fileEmailDialogHandler);
