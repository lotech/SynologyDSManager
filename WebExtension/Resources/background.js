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
// ## Why every API touch is wrapped in try/catch
//
// In Safari's MV3 service-worker model, the worker is started
// on-demand whenever an event it has registered for fires. If any
// top-level module code throws — e.g. reading a property of an API
// namespace that Safari didn't expose for whatever reason — the
// worker dies before it finishes initialising, Safari marks it
// failed, and after a few repeat failures stops offering to load
// it at all (the extension disappears from Safari's
// Develop → Web Extension Background Content submenu). Guarding
// every addListener / registration call prevents a single missing
// API from taking down the whole worker and leaves a diagnostic
// trail in the service worker's Console.

const NATIVE_APP_ID = "com.skavans.synologyDSManager";
const MENU_ITEM_ID  = "synology-dsmanager-download";

// Early diagnostic — tells us what APIs are actually wired when the
// worker starts. Visible in Safari → Develop → Web Extension
// Background Content → Synology DS Manager → Console.
try {
    console.log("[DSManager] background.js loaded");
    console.log("[DSManager] browser keys:", Object.keys(globalThis.browser || {}).sort());
    if (globalThis.browser?.runtime) {
        console.log("[DSManager] runtime keys:",
                    Object.keys(globalThis.browser.runtime).sort());
    }
} catch (err) {
    // Even console.log on a missing browser shouldn't ever throw, but
    // leave the diagnostic bullet-proof anyway.
}

/** Idempotent context-menu registration. Called at multiple lifecycle
 *  points so we re-register whenever Safari restarts us.
 */
async function registerContextMenu() {
    try {
        if (!browser?.contextMenus) {
            console.warn("[DSManager] browser.contextMenus is unavailable; can't register menu");
            return;
        }
        await browser.contextMenus.removeAll();
        const title = (browser.i18n?.getMessage?.("context_menu_download")) ||
                      "Download with Synology DS Manager";
        browser.contextMenus.create({
            id: MENU_ITEM_ID,
            title,
            contexts: ["link"]
        });
        console.log("[DSManager] context menu registered");
    } catch (err) {
        console.error("[DSManager] registerContextMenu failed:", err);
    }
}

// Fire on every lifecycle event we can hang off. Each registration is
// guarded so a missing listener API doesn't terminate the module.
try {
    browser?.runtime?.onInstalled?.addListener?.(registerContextMenu);
} catch (err) {
    console.error("[DSManager] onInstalled registration failed:", err);
}

try {
    browser?.runtime?.onStartup?.addListener?.(registerContextMenu);
} catch (err) {
    console.error("[DSManager] onStartup registration failed:", err);
}

// Also try once at module load. If the API is present on this
// start-up, the menu is there immediately without waiting for
// Safari to fire any lifecycle event at us.
registerContextMenu();

// Toolbar-button handler. The button itself is declared in
// manifest.json's `action` block and doesn't need to do anything —
// its mere presence is what makes Safari treat us as an
// "interactive" extension and reliably start the service worker on
// install/update. Logging the click is useful during development
// because it's a guaranteed way to wake the worker from the user's
// side (handy when the `onInstalled` / `onStartup` triggers didn't
// fire for whatever reason).
try {
    browser?.action?.onClicked?.addListener?.(() => {
        console.log("[DSManager] toolbar action clicked; worker is alive");
        // Re-register the menu in case something ate the previous
        // registration. Idempotent.
        registerContextMenu();
    });
} catch (err) {
    console.error("[DSManager] action.onClicked registration failed:", err);
}

// Menu-click handler. Same defensive pattern — guard the
// addListener call itself, keep the handler body inside try/catch.
try {
    browser?.contextMenus?.onClicked?.addListener?.(async (info, _tab) => {
        try {
            if (info.menuItemId !== MENU_ITEM_ID) return;
            const url = info.linkUrl;
            if (!url) return;

            console.log("[DSManager] enqueue:", url);
            const reply = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
                action: "enqueueDownload",
                url
            });

            if (!reply || reply.ok !== true) {
                console.error("[DSManager] enqueue failed:", reply?.error ?? "unknown error");
            } else {
                console.log("[DSManager] enqueue ok");
            }
        } catch (err) {
            console.error("[DSManager] onClicked handler threw:", err);
        }
    });
} catch (err) {
    console.error("[DSManager] onClicked registration failed:", err);
}
