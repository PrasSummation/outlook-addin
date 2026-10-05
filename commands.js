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
