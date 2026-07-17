// Apollo-Reborn — "Open in Apollo" Safari Web Extension content script.
//
// Redirects Reddit web pages to Apollo Reborn's Universal Link. iOS validates
// that HTTPS link against open.apolloreborn.app's AASA file and can hand it to
// Apollo without the confirmation sheet that custom apollo:// navigations show.
//
// Why this differs from the stock Apollo extension: the stock "Automatic" mode
// routed through an external interstitial page whose auto-open relied on an iOS
// Smart App Banner bound to the App Store build (app id 979274575). A sideloaded
// Apollo-Reborn is not that App Store app, so the banner never recognized it and
// users were stranded on the interstitial. The new endpoint is owned by the
// project and has a safe Reddit redirect when no matching app is installed.

(function () {
    "use strict";

    // Guards against re-redirecting the same URL (e.g. when the SPA mutates the
    // DOM after we've already kicked off navigation).
    var lastHandledURL = "";

    var universalLinkOrigin = "https://open.apolloreborn.app";
    var fallbackMarker = "apollo_reborn_no_open";

    // Returns an Apollo Reborn Universal Link, or null if this isn't a Reddit
    // content link. The original URL is carried verbatim so redd.it short links,
    // queries, and future Reddit path shapes don't need special-case parsing.
    function toApolloURL(href) {
        var url;
        try {
            url = new URL(href);
        } catch (e) {
            return null;
        }

        var host = url.hostname.toLowerCase();
        if (!(host === "reddit.com" || host.endsWith(".reddit.com") ||
              host === "redd.it" || host.endsWith(".redd.it"))) {
            return null;
        }

        // The Worker adds this marker before its browser fallback redirects to
        // Reddit. Consume it once so an install whose signer stripped Associated
        // Domains doesn't bounce forever between Reddit and the Worker.
        if (url.searchParams.has(fallbackMarker)) {
            url.searchParams.delete(fallbackMarker);
            try {
                window.history.replaceState(null, "", url.href);
            } catch (e) {
                // Cleaning the address bar is cosmetic; suppressing the loop is not.
            }
            // The MutationObserver below may run after replaceState while Reddit
            // is still rendering. Remember the cleaned URL so that observer
            // cannot immediately send the same fallback back to the Worker.
            lastHandledURL = url.href;
            return null;
        }

        // Don't hijack a bare host (e.g. https://reddit.com/ or the homepage);
        // only act on actual content paths (/r/..., /u/..., /user/..., etc.).
        var path = url.pathname || "/";
        if (path === "" || path === "/") {
            return null;
        }

        url.protocol = "https:";
        return universalLinkOrigin + "/open?url=" + encodeURIComponent(url.href);
    }

    function runCheck() {
        var href = window.location.href;
        if (href === lastHandledURL) {
            return; // already handled this URL
        }

        var apolloURL = toApolloURL(href);
        if (!apolloURL) {
            return;
        }

        lastHandledURL = href;
        window.stop();
        window.location.replace(apolloURL);
    }

    function start(isAutomatic) {
        // The popup lets the user turn auto-open off. When off, leave the page
        // alone (the toolbar action and the iOS Share sheet still work).
        if (isAutomatic === false) {
            return;
        }

        runCheck();

        // Reddit is a single-page app: the URL can change without a full
        // navigation. Re-check on history changes and DOM mutations. This
        // replaces the deprecated DOMNodeInserted listener the stock script used.
        window.addEventListener("popstate", runCheck);

        var observer = new MutationObserver(function () {
            runCheck();
        });
        observer.observe(document.documentElement || document, {
            childList: true,
            subtree: true
        });
    }

    // The popup stores { automaticObj: { isAutomatic: bool } }; default true.
    // Safari has shipped both callback and Promise forms of the WebExtension
    // storage API. Support both: waiting forever for an unsupported callback
    // form means the content script silently never runs.
    function startFromStorage(item) {
        var automaticObj = item && item.automaticObj;
        var isAutomatic = (automaticObj === undefined || automaticObj === null)
            ? true
            : automaticObj.isAutomatic;
        start(isAutomatic);
    }

    try {
        var pending = browser.storage.local.get("automaticObj");
        if (pending && typeof pending.then === "function") {
            pending.then(startFromStorage, function () { start(true); });
        } else {
            browser.storage.local.get(startFromStorage);
        }
    } catch (e) {
        // If storage is unavailable for any reason, default to automatic.
        start(true);
    }
})();
