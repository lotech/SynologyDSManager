// background.js
//
// Service worker for the Synology DS Manager Safari Web Extension.
// Registers a right-click context-menu item on links, and forwards
// the chosen URL to the containing app's SafariWebExtensionHandler
// via `browser.runtime.sendNativeMessage`. The handler in turn opens
// an XPC connection to the main app's authorisation-gated listener
// (see SynologyBridgeListener / ClientAuthorization in the main
// target).
//
// Wire format (JS → Swift):
//   { "action": "enqueueDownload", "url": "https://…/ubuntu.iso" }
//
// Reply shape (Swift → JS):
//   { "ok": true }
//   { "ok": false, "error": "…" }
//
// Safari passes the first argument to sendNativeMessage as the
// "application identifier" — we use the containing app's bundle ID
// here; Safari routes the message to its extension's handler
// regardless, but being explicit documents intent.

const NATIVE_APP_ID = "com.skavans.synologyDSManager";
const MENU_ITEM_ID = "synology-dsmanager-download";

browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({
        id: MENU_ITEM_ID,
        title: browser.i18n.getMessage("context_menu_download") || "Download with Synology DS Manager",
        contexts: ["link"]
    });
});

browser.contextMenus.onClicked.addListener(async (info, _tab) => {
    if (info.menuItemId !== MENU_ITEM_ID) return;

    // `info.linkUrl` is present because we registered the menu with
    // `contexts: ["link"]`. Safari walks up the DOM to find the
    // enclosing <a> automatically, which replaces the old content-
    // script trick of climbing from the raw click target.
    const url = info.linkUrl;
    if (!url) return;

    try {
        const reply = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
            action: "enqueueDownload",
            url: url
        });

        if (!reply || reply.ok !== true) {
            // Keep errors out of the page — log them to the service
            // worker's console only. A future UX polish could surface
            // them via browser.notifications (needs the permission).
            console.error("[DSManager] enqueue failed:", reply?.error ?? "unknown error");
        }
    } catch (err) {
        console.error("[DSManager] native message threw:", err);
    }
});
