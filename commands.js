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

// EMERGENCY KILL SWITCH, 2026-10-07, re-tripped 2026-10-11 twice -- ACTUAL ROOT CAUSE FOUND
// 2026-10-11, and it's architectural, not a bug: Office.context.ui.displayDialogAsync cannot
// be called from an event-based handler in Outlook at all. Confirmed deterministic (every
// single send, not intermittent) via the 2/4 checkpoint marker added to diagnose this --
// displayDialogAsync's own callback never fires, every time, no error, nothing. Microsoft's
// own Outlook-Add-in-SSO-events sample states this explicitly ("It's not possible to open a
// dialog from an event in Outlook") and their Dialog API guidance says dialogs are only
// supported "from a task pane, content add-in, or add-in command" -- OnMessageSend is none of
// those. The 2026-10-07 AppDomains fix and the 2026-10-11 watchdog widening were both real,
// correct fixes for real problems, but neither could have made this actually work, because
// the dialog this code tries to open can never open from here on any client that enforces
// this rule. DO NOT re-enable this flag again until file-on-send-dialog.html's whole approach
// is redesigned to not require displayDialogAsync from this handler -- see CLAUDE.md for
// options under consideration. While this is false, every send is allowed through
// immediately, untagged, without ever trying to open the dialog.
const FILE_ON_SEND_ENABLED = false;

function onMessageSendHandler(event) {
  if (!FILE_ON_SEND_ENABLED) {
    event.completed({ allowEvent: true });
    return;
  }

  let settled = false;
  let dialog = null;

  function finish(allowEvent) {
    if (settled) return;
    settled = true;
    clearTimeout(watchdogId);
    if (dialog) {
      try { dialog.close(); } catch (err) { /* already closing/closed on its own */ }
    }
    event.completed({ allowEvent: allowEvent });
  }

  // Bounded safety net, added 2026-10-07 after a live incident, WIDENED 2026-10-11 after a
  // second one: a teammate's send sat on Outlook's own "taking longer than expected"
  // warning indefinitely. The original fix (a missing AppDomains entry letting an MSAL call
  // inside the dialog hang instead of erroring -- see manifest2.xml's AppDomains comment)
  // only armed its 20s timeout *inside* displayDialogAsync's own callback, after the dialog
  // had already opened -- leaving item.getComposeTypeAsync and displayDialogAsync's own
  // callback completely unguarded. A live retest of that fix reproduced the exact same
  // symptom (Outlook's own generic warning, never this code's own dialog UI), meaning the
  // hang happens before either of those ever completes on at least one real client (classic
  // Windows Outlook, the same client type both times). This timer now covers the handler
  // from its very first async call onward, as the single source of truth for "fail this
  // send open" -- not two separately-armed timers, one of which can't even start ticking
  // until past the point where the hang apparently occurs.
  //
  // Outlook's own SendMode=SoftBlock timeout remains the ultimate backstop, but its exact
  // duration isn't documented and evidently isn't tight enough for good UX on its own.
  //
  // This does NOT cap how long a user gets to pick a project once the dialog is actually
  // alive -- the dialog pings back {action:"ready"} the moment it renders anything real
  // (sign-in prompt or the picker), which clears this; from then on the user has as much
  // time as they want, same as always.
  const watchdogId = setTimeout(() => {
    console.error("onMessageSendHandler: hard timeout before the dialog confirmed it loaded -- failing open.");
    finish(true);
  }, 20000);

  const item = Office.context.mailbox.item;

  item.getComposeTypeAsync((composeTypeResult) => {
    if (settled) return; // watchdog already fired before this callback got a chance to run

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
      if (settled) {
        // Watchdog already fired and allowed the send through. If the dialog went ahead
        // and opened anyway after all that, close it rather than leave it orphaned --
        // event.completed() must never be called a second time, though.
        if (asyncResult.status !== Office.AsyncResultStatus.Failed) {
          try { asyncResult.value.close(); } catch (err) { /* ignore */ }
        }
        return;
      }

      if (asyncResult.status === Office.AsyncResultStatus.Failed) {
        // Couldn't open the dialog at all -- fail open, never trap a send over this.
        console.error("Could not open File on Send dialog:", asyncResult.error);
        finish(true);
        return;
      }

      dialog = asyncResult.value;

      dialog.addEventHandler(Office.EventType.DialogMessageReceived, (arg) => {
        let message;
        try {
          message = JSON.parse(arg.message);
        } catch (err) {
          finish(true);
          return;
        }

        if (message.action === "ready") {
          clearTimeout(watchdogId);
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
  try {
    Office.context.mailbox.item.notificationMessages.addAsync(
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
            // MessageComposeCommandSurface -- that control is already ActionType="ShowTaskpane"
            // pointed at Taskpane.Url, which is all this action needs to reuse.
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
