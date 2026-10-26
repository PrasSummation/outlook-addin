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
 * The manifest's SendMode="PromptUser" (changed from "SoftBlock" 2026-10-21, manifest2.xml) means
 * Outlook's own Smart Alerts dialog offers a "Send Anyway" override in addition to this handler's
 * own Take Action button -- a real escape hatch if the categorize-and-file flow misbehaves,
 * which SoftBlock never provided (it only fails open if this handler itself throws, hangs, or
 * never calls event.completed() within Outlook's own platform timeout -- a different, narrower
 * safety net this code still leans on rather than duplicates).
 */
// RE-ENABLED 2026-10-21, step 2 of 2: manifest2.xml (1.0.0.20, SendMode="PromptUser") was
// uploaded to the Microsoft 365 admin center's Integrated Apps first (scoped to "Just me",
// Pras@summation.au) and the user restarted Outlook to pick it up, deliberately sequenced before
// this flip -- flipping both together would have risked a window where File on Send was active
// under the OLD SendMode="SoftBlock" still cached on the client, the same risky combination that
// caused the incident below. All the root causes found and fixed since the incident (a Graph GET
// 404 right after saveAsync(), the master-category cleanup race, the compose-mode item.subject
// object bug, and Save Both's dialog killing its own bridge request before it landed) are
// believed fixed. First live send-triggered test of this redesign is still outstanding -- watch
// for whether the native Smart Alert actually offers "Send Anyway" (confirms PromptUser is live,
// not a stale cached SoftBlock manifest) the next time a send is intercepted.
//
// EMERGENCY KILL SWITCH -- history: first tripped 2026-10-16 after a live-blocking incident --
// the Smart Alerts dialog showed correctly (Choose project / Don't Send), but there was no way
// to send through untagged (SendMode="SoftBlock" gave no "Send Anyway"), and "Choose project" ->
// task pane -> file-on-send-dialog.html -> categories.addAsync wasn't completing the
// categorization, leaving the user stuck unable to send at all. Flipping this to false restores
// "every send allowed through immediately, untagged" while a fix is worked out -- deploys in
// ~10 minutes via commands.js's own CDN cache, no manifest re-upload needed, since OnMessageSend's
// LaunchEvent registration itself doesn't need to change for this switch alone.
const FILE_ON_SEND_ENABLED = true;

// Shared by onMessageSendHandler and onMessageComposeHandler: matches the project-category
// naming convention this codebase already uses everywhere else (email-index's keywords.py,
// email-filing-sync's sync.ps1) -- 5 letters + 5 digits + "_" or "-", e.g. "SUPER26099_...".
const PROJECT_CATEGORY_PATTERN = /^[a-zA-Z]{5}\d{5}[_-]/;

// DIAGNOSTIC HELPERS, added 2026-10-16. The compose/send handlers below no longer call these --
// the compose-time filing chain they were added to debug is confirmed working end to end as of
// 2026-10-20 (see CLAUDE.md). Still used by fileEmailDialogHandlerDiag further down, which
// remains a live, separate diagnostic (File Email's multi-select question) -- remove this block
// too once that one is resolved and that diagnostic button comes out of the manifest.
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
      errorMessage: "Assign email to a project",
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
              commandId: "Summation.ComposeTaskpaneButton",
              // Confirmed live 2026-10-16: Outlook doesn't support a separate TaskpaneId per
              // control in Outlook (that element is explicitly "not supported in Outlook" per
              // the manifest Action docs), so if Summation Assistant's pane is already open from
              // earlier in the session, clicking this just brings it to the front WITHOUT
              // re-navigating to FileOnCompose.Url's query string -- the general menu shows
              // instead of the picker. contextData is Outlook's own documented fix for exactly
              // this ("InsightMessage notification... prevents an add-in from relaunching if
              // its task pane is already open"): the already-open pane gets this value via the
              // InitializationContextChanged event instead of a URL. taskpane.html checks both
              // paths -- the query string for a fresh open, this for an already-open one.
              //
              // REGRESSION FOUND 2026-10-19: this worked (banner visible, clickable) before
              // contextData was added here, and failed every test since -- clean before/after
              // split. Microsoft's own docs for this property explicitly describe a
              // JSON.stringify()/JSON.parse() round trip even though the type is just `string`;
              // a bare, non-JSON-encoded string was passed here instead. Theory: addAsync's own
              // validation is shallow (hence it still reported Succeeded), but the later
              // rendering pipeline silently chokes on a contextData value that isn't valid JSON.
              // JSON.stringify()'d here; taskpane.html must JSON.parse() it back on both the
              // getInitializationContextAsync() and InitializationContextChanged paths.
              contextData: JSON.stringify("fileOnCompose")
            }
          ]
        },
        (result) => {
          // The missing piece until 2026-10-19: this callback never checked result.status, so a
          // failed addAsync for the InsightMessage was indistinguishable from a successful one.
          if (result.status === Office.AsyncResultStatus.Failed) {
            console.error("onMessageComposeHandler: InsightMessage addAsync failed:", result.error);
          }
          event.completed();
        }
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
