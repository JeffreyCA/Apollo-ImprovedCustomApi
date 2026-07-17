// ==UserScript==
// @name         Open in Apollo (Apollo-Reborn)
// @namespace    https://github.com/Apollo-Reborn/Apollo-Reborn
// @version      1.1.0
// @description  Open Reddit links in Apollo on iOS through Apollo Reborn's Universal Link, without a custom-scheme confirmation popup.
// @author       Apollo-Reborn
// @match        *://*.reddit.com/*
// @match        *://*.redd.it/*
// @match        *://www.google.com/*
// @match        *://www.bing.com/*
// @match        *://duckduckgo.com/*
// @run-at       document-start
// @grant        none
// @homepageURL  https://github.com/Apollo-Reborn/Apollo-Reborn
// ==/UserScript==
//
// This is an app-independent alternative to Apollo's bundled Safari extension —
// useful for the "no-extensions" IPA variant (where Apollofari.appex is stripped)
// and jailbreak/.deb installs. Install it via the free "Userscripts" app on the
// App Store (a Safari extension). Like Apollo's own extension, it is Safari-only
// on iOS: Chrome/Firefox/etc. on iOS can't run extensions or userscript managers.
//
// The redirect carries the complete Reddit URL in a URL-encoded query item. The
// tweak validates it and then passes it to Apollo's native URL parser, so comment
// permalinks, profiles, redd.it links, and /s/ share links all work.
//
// The search-result rewriting idea is borrowed from AnthonyGress's userscript:
// https://github.com/AnthonyGress/Open-In-Apollo (reimplemented here, with /s/
// share-link support added).

(function () {
    "use strict";

    var universalLinkOrigin = "https://open.apolloreborn.app";
    var fallbackMarker = "apollo_reborn_no_open";

    // Returns an Apollo Reborn Universal Link for a Reddit content link.
    function toApolloURL(href) {
        var url;
        try {
            url = new URL(href, window.location.href);
        } catch (e) {
            return null;
        }

        var host = url.hostname.toLowerCase();
        if (!(host === "reddit.com" || host.endsWith(".reddit.com") ||
              host === "redd.it" || host.endsWith(".redd.it"))) {
            return null;
        }

        if (url.searchParams.has(fallbackMarker)) {
            url.searchParams.delete(fallbackMarker);
            try {
                window.history.replaceState(null, "", url.href);
            } catch (e) {
                // Cosmetic only; returning null is what prevents a fallback loop.
            }
            return null;
        }

        var path = url.pathname || "/";
        if (path === "" || path === "/") {
            return null;
        }

        url.protocol = "https:";
        return universalLinkOrigin + "/open?url=" + encodeURIComponent(url.href);
    }

    // Some search engines wrap result links in a redirector. Unwrap the common
    // ones so we see the real destination.
    function unwrapSearchHref(href) {
        var url;
        try {
            url = new URL(href, window.location.href);
        } catch (e) {
            return href;
        }
        var host = url.hostname.toLowerCase();
        // Google: https://www.google.com/url?q=<real>
        if (host.indexOf("google.") !== -1 && url.pathname === "/url") {
            return url.searchParams.get("q") || url.searchParams.get("url") || href;
        }
        // DuckDuckGo: https://duckduckgo.com/l/?uddg=<encoded real>
        if (host.indexOf("duckduckgo.com") !== -1 && url.pathname === "/l/") {
            return url.searchParams.get("uddg") || href;
        }
        return href;
    }

    // ---- Mode A: we're on reddit.com — auto-redirect into Apollo. ----

    var lastHandledURL = "";

    function redirectCheck() {
        var href = window.location.href;
        if (href === lastHandledURL) {
            return;
        }
        var apolloURL = toApolloURL(href);
        if (!apolloURL) {
            return;
        }
        lastHandledURL = href;
        window.stop();
        window.location.replace(apolloURL);
    }

    // ---- Mode B: we're on a search engine — rewrite Reddit result links. ----

    function rewriteResultLinks() {
        var anchors = document.querySelectorAll("a[href]");
        for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i];
            if (a.dataset && a.dataset.apolloRewritten === "1") {
                continue;
            }
            var target = unwrapSearchHref(a.href);
            var apolloURL = toApolloURL(target);
            if (apolloURL) {
                a.href = apolloURL;
                if (a.dataset) {
                    a.dataset.apolloRewritten = "1";
                }
            }
        }
    }

    function observe(callback) {
        callback();
        var observer = new MutationObserver(function () {
            callback();
        });
        var root = document.documentElement || document;
        observer.observe(root, { childList: true, subtree: true });
        window.addEventListener("popstate", callback);
    }

    var onReddit = /(^|\.)reddit\.com$/i.test(window.location.hostname) ||
                   /(^|\.)redd\.it$/i.test(window.location.hostname);

    if (onReddit) {
        observe(redirectCheck);
    } else {
        // Search-result pages render after document-start; wait for DOM.
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", function () {
                observe(rewriteResultLinks);
            });
        } else {
            observe(rewriteResultLinks);
        }
    }
})();
