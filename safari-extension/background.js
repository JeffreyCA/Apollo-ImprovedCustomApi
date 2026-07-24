// Apollo-Reborn — "Open in Apollo" background script.
//
// Keeps the declarativeNetRequest ruleset in sync with the popup's "Automatic"
// toggle. The DNR redirect rewrites Reddit navigations to the
// open.apolloreborn.app Universal Link at the network layer, before Safari
// fetches or renders anything from Reddit. The content script remains as a
// fallback for Safari versions without DNR redirect support (< 15.4) and for
// Reddit's in-page SPA navigations, which DNR cannot observe.
//
// Storage access mirrors content.js: Safari has shipped both Promise- and
// callback-based storage APIs, so support both.

(function () {
    "use strict";

    var RULESET_ID = "auto_open";

    function applyAutomatic(item) {
        var automaticObj = item && item.automaticObj;
        var isAutomatic = (automaticObj === undefined || automaticObj === null)
            ? true
            : automaticObj.isAutomatic !== false;

        var change = isAutomatic
            ? { enableRulesetIds: [RULESET_ID] }
            : { disableRulesetIds: [RULESET_ID] };

        try {
            var promise = browser.declarativeNetRequest.updateEnabledRulesets(change);
            if (promise && promise.catch) {
                promise.catch(function () {
                    // DNR unavailable (old Safari): the content script still
                    // honors the Automatic toggle on its own.
                });
            }
        } catch (e) {
            // Same: fall back silently to the content-script-only flow.
        }
    }

    function syncFromStorage() {
        try {
            var promise = browser.storage.local.get("automaticObj");
            if (promise && promise.then) {
                promise.then(applyAutomatic, function () { applyAutomatic(null); });
                return;
            }
        } catch (e) {
            // Fall through to the callback form.
        }
        try {
            browser.storage.local.get("automaticObj", applyAutomatic);
        } catch (e) {
            applyAutomatic(null);
        }
    }

    browser.storage.onChanged.addListener(function (changes, areaName) {
        if (areaName === "local" && changes.automaticObj) {
            syncFromStorage();
        }
    });

    syncFromStorage();
})();
