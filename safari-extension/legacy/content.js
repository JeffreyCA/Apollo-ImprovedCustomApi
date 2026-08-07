// Apollo-Reborn — legacy automatic "Open in Apollo" Safari content script.
//
// This preserves the automatic behavior shipped before Link Companion became
// the preferred owner of Safari routing. It is packaged under a separate,
// clearly labelled extension so users can opt into it without losing the safe
// manual fallback. Do not enable it alongside the Companion extension: both
// would try to handle the same navigation.

(function () {
    "use strict";

    var links = globalThis.ApolloRebornLinkUtils;
    var lastHandledURL = "";

    function consumeWorkerFallback(href) {
        var url;
        try {
            url = new URL(href);
        } catch (error) {
            return false;
        }

        if (!url.searchParams.has(links.fallbackMarker)) {
            return false;
        }

        url.searchParams.delete(links.fallbackMarker);
        try {
            window.history.replaceState(null, "", url.href);
        } catch (error) {
            // Cleaning the address bar is cosmetic; suppressing the loop is not.
        }
        lastHandledURL = url.href;
        return true;
    }

    function runCheck() {
        var href = window.location.href;
        if (href === lastHandledURL || consumeWorkerFallback(href)) {
            return;
        }

        var openerURL = links.toOpenerURL(href);
        if (!openerURL) {
            return;
        }

        lastHandledURL = href;
        window.stop();
        window.location.replace(openerURL);
    }

    function start(isAutomatic) {
        if (isAutomatic === false) {
            return;
        }

        runCheck();
        window.addEventListener("popstate", runCheck);

        var observer = new MutationObserver(runCheck);
        observer.observe(document.documentElement || document, {
            childList: true,
            subtree: true
        });
    }

    function startFromStorage(item) {
        var automaticObj = item && item.automaticObj;
        start(!automaticObj || automaticObj.isAutomatic !== false);
    }

    try {
        var pending = browser.storage.local.get("automaticObj");
        if (pending && typeof pending.then === "function") {
            pending.then(startFromStorage, function () { start(true); });
        } else {
            browser.storage.local.get(startFromStorage);
        }
    } catch (error) {
        start(true);
    }
})();
