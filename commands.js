/*
 * File-on-send, phase 1 probe.
 *
 * This exact file is loaded two different ways depending on the Outlook client:
 *   - Classic Outlook on Windows loads it directly in a JavaScript-only runtime: no HTML,
 *     no office.js <script> tag, no imports, and Office.onReady/Office.initialize never run
 *     here (per https://learn.microsoft.com/office/dev/add-ins/develop/event-based-activation).
 *   - Every other client (web, new Outlook on Windows, Mac) loads it via an ordinary
 *     <script src="commands.js"> tag inside commands.html, after office.js has already
 *     loaded there, so the Office global already exists by the time this file runs.
 * Both paths land here with an already-usable Office global, which is why there's no
 * Office.onReady wrapper below -- adding one would just never fire on classic Windows.
 *
 * This only proves OnMessageSend actually fires before any send-blocking picker logic is
 * built on top of it (see the separately-approved File on Send dialog mockup). It never
 * blocks or delays a send -- every path calls event.completed({ allowEvent: true }), and
 * the manifest's SendMode="SoftBlock" means Outlook itself lets the send through even if
 * this code throws or never completes at all. The one visible effect is a notification
 * banner on the item, so firing can be confirmed just by sending mail.
 */

function onMessageSendHandler(event) {
  try {
    Office.context.mailbox.item.notificationMessages.replaceAsync(
      "summationFileOnSendProbe",
      {
        type: Office.MailboxEnums.ItemNotificationMessageType.InformationalMessage,
        message: "Summation: File on Send handler fired (phase 1 probe -- not blocking this send).",
        icon: "Icon.16x16",
        persistent: false
      },
      () => event.completed({ allowEvent: true })
    );
  } catch (err) {
    event.completed({ allowEvent: true });
  }
}

Office.actions.associate("onMessageSendHandler", onMessageSendHandler);

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
