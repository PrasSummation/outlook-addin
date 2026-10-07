/*
 * File on Send -- go-live build, 2026-10-06. Replaces the earlier phase-1 probe (which
 * only proved OnMessageSend fires and always allowed the send through unchanged) with the
 * real picker, built from the separately-approved mockup:
 * https://claude.ai/artifact/EqTMRsGos3VHXtspmZPXpp
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
 * Neither path has a DOM or network stack guaranteed (confirmed: no document, no fetch,
 * no way to load MSAL via a <script> tag, on the classic-Windows runtime) -- which is why
 * everything requiring Graph/SharePoint access (the project list, finding "the original"
 * message) lives in file-on-send-dialog.html instead, a normal web page opened via
 * Office.context.ui.displayDialogAsync. This file only ever does plain Office.js:
 * detecting compose context, opening that dialog, and -- once it reports back a choice --
 * tagging the outgoing item's categories and calling event.completed().
 *
 * The manifest's SendMode="SoftBlock" means Outlook itself lets the send through if this
 * handler throws, hangs, or never calls event.completed() within its own platform timeout
 * -- a deliberate safety net this code leans on rather than duplicates. Every path below
 * still calls event.completed() itself (don't rely on that net as the normal path), and
 * always with allowEvent:true unless the user explicitly chose "Back to email".
 */

// EMERGENCY KILL SWITCH, 2026-10-07: flip to true to re-enable. Team reported sends
// hanging on Outlook's own "add-in taking longer than expected" / "Don't Send" warning
// for a classic-Windows-Outlook user right after this went live -- root cause not yet
// found. The manifest's LaunchEvent wiring itself is slow to change (sideloaded/admin
// manifest updates can take hours to propagate), but commands.js is fetched fresh by
// Outlook at send time from GitHub Pages on a 10-minute CDN cache -- much faster to
// actually take effect. While this is false, every send is allowed through immediately,
// untagged, without ever trying to open the dialog.
const FILE_ON_SEND_ENABLED = false;

function onMessageSendHandler(event) {
  if (!FILE_ON_SEND_ENABLED) {
    event.completed({ allowEvent: true });
    return;
  }

  const item = Office.context.mailbox.item;

  item.getComposeTypeAsync((composeTypeResult) => {
    const composeType = (composeTypeResult.status === Office.AsyncResultStatus.Succeeded && composeTypeResult.value)
      ? composeTypeResult.value.composeType // "newMail" | "reply" | "replyAll" | "forward"
      : "newMail";

    const context = {
      composeType: composeType,
      subject: item.subject || "(no subject)",
      conversationId: item.conversationId || null
    };

    const url = "https://prassummation.github.io/outlook-addin/file-on-send-dialog.html?context=" +
      encodeURIComponent(JSON.stringify(context));

    Office.context.ui.displayDialogAsync(url, { height: 70, width: 40 }, (asyncResult) => {
      if (asyncResult.status === Office.AsyncResultStatus.Failed) {
        // Couldn't open the dialog at all -- fail open, never trap a send over this.
        console.error("Could not open File on Send dialog:", asyncResult.error);
        event.completed({ allowEvent: true });
        return;
      }

      const dialog = asyncResult.value;
      let settled = false;

      function finish(allowEvent) {
        if (settled) return;
        settled = true;
        clearTimeout(readyTimeoutId);
        try { dialog.close(); } catch (err) { /* already closing/closed on its own */ }
        event.completed({ allowEvent: allowEvent });
      }

      // Bounded safety net, added 2026-10-07 after a live incident: a teammate's send sat
      // on Outlook's own "taking longer than expected" warning indefinitely (root cause:
      // a missing AppDomains entry made an MSAL call inside the dialog hang instead of
      // erroring -- see manifest2.xml's AppDomains comment). Outlook's own SendMode=
      // SoftBlock timeout is the ultimate backstop, but its exact duration isn't
      // documented and evidently isn't tight enough for good UX -- this is deliberately
      // duplicated now, not left to that net alone.
      //
      // This only guards the dialog actually coming alive -- it does NOT cap how long a
      // user gets to pick a project. The dialog pings back {action:"ready"} the moment it
      // renders anything real (sign-in prompt or the picker), which clears this; from then
      // on the user has as much time as they want, same as before.
      const readyTimeoutId = setTimeout(() => {
        console.error("File on Send dialog never confirmed it loaded -- failing open.");
        finish(true);
      }, 20000);

      dialog.addEventHandler(Office.EventType.DialogMessageReceived, (arg) => {
        let message;
        try {
          message = JSON.parse(arg.message);
        } catch (err) {
          finish(true);
          return;
        }

        if (message.action === "ready") {
          clearTimeout(readyTimeoutId);
          return;
        }

        if (message.action === "cancel") {
          finish(false);
          return;
        }

        if (message.action === "skip") {
          // User explicitly chose to send without filing -- let it through untagged,
          // same as any other unrecognized/no-category message below, just named.
          finish(true);
          return;
        }

        if (message.action === "save" && message.categoryName) {
          // The one thing only this context can do -- dialogs have no
          // Office.context.mailbox at all. Everything else (filing "the original", if
          // asked) is already running independently, kicked off by the dialog itself
          // before it messaged back.
          item.categories.addAsync([message.categoryName], () => finish(true));
          return;
        }

        finish(true);
      });

      // Dialog closed some other way (its own OS close control, host recycling it, etc.)
      // without an explicit Save/Cancel -- fail open rather than silently trap the send.
      dialog.addEventHandler(Office.EventType.DialogEventReceived, () => finish(true));
    });
  });
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
