// ==UserScript==
// @name         Open in Apollo (Apollo-Reborn)
// @namespace    https://github.com/Apollo-Reborn/Apollo-Reborn
// @version      2.0.0
// @description  Open Reddit links in Apollo through Apollo Reborn's gesture-preserving Universal Link.
// @author       Apollo-Reborn
// @match        *://*/*
// @run-at       document-start
// @grant        none
// @homepageURL  https://github.com/Apollo-Reborn/Apollo-Reborn
// ==/UserScript==
//
// App-independent counterpart to Apollo's bundled Safari extension, intended
// for the no-extensions IPA and jailbreak/.deb installs. All-sites access is
// required because Reddit links may appear on any page. This script only reads
// anchor destinations, performs no network requests, and only rewrites a link
// after its final destination has been validated as Reddit.

(function () {
    "use strict";

    var openerOrigin = "https://open.apolloreborn.app";
    var fallbackMarker = "apollo_reborn_no_open";
    var rewrittenAttribute = "data-apollo-reborn-userscript-opener";
    var prompt = null;
    var suppressedURL = "";

    function isHostOrSubdomain(host, domain) {
        host = (host || "").toLowerCase();
        return host === domain || host.endsWith("." + domain);
    }

    function isRedditHost(host) {
        return isHostOrSubdomain(host, "reddit.com") ||
               (host || "").toLowerCase() === "redd.it";
    }

    function parseURL(value, base) {
        try {
            return new URL(value, base);
        } catch (error) {
            return null;
        }
    }

    function repeatedlyDecode(value) {
        var result = value;
        for (var i = 0; i < 3 && typeof result === "string"; i++) {
            if (/^https?:\/\//i.test(result)) {
                return result;
            }
            try {
                var decoded = decodeURIComponent(result);
                if (decoded === result) break;
                result = decoded;
            } catch (error) {
                break;
            }
        }
        return result;
    }

    function decodeBase64URL(value) {
        if (!value || typeof atob !== "function") return null;
        var normalized = value.replace(/-/g, "+").replace(/_/g, "/");
        while (normalized.length % 4) normalized += "=";
        try {
            return atob(normalized);
        } catch (error) {
            return null;
        }
    }

    function unwrapOnce(value) {
        var url = parseURL(value, window.location.href);
        if (!url) return value;
        var host = url.hostname.toLowerCase();

        if (isHostOrSubdomain(host, "google.com") || /(^|\.)google\.[a-z.]+$/i.test(host)) {
            if (url.pathname === "/url") {
                return url.searchParams.get("q") || url.searchParams.get("url") || value;
            }
            if (url.pathname.indexOf("/amp/s/") === 0) {
                return "https://" + url.pathname.substring(7) + url.search + url.hash;
            }
            if (url.pathname.indexOf("/amp/") === 0) {
                return repeatedlyDecode(url.pathname.substring(5)) || value;
            }
        }

        if (isHostOrSubdomain(host, "duckduckgo.com") && url.pathname === "/l/") {
            return url.searchParams.get("uddg") || value;
        }

        if (isHostOrSubdomain(host, "bing.com") && url.pathname === "/ck/a") {
            var bingValue = url.searchParams.get("u");
            if (bingValue && bingValue.indexOf("a1") === 0) {
                return decodeBase64URL(bingValue.substring(2)) || value;
            }
        }

        if (host.indexOf(".search.yahoo.") !== -1 || host.indexOf("r.search.yahoo.") === 0) {
            var yahooMatch = url.pathname.match(/\/RU=([^/]+)\/(?:RK|RS|RV)=/i);
            if (yahooMatch) return repeatedlyDecode(yahooMatch[1]) || value;
        }

        if (host === "reddit.app.link") {
            var original = url.searchParams.get("$original_url") ||
                           url.searchParams.get("original_url") ||
                           url.searchParams.get("url");
            return original ? repeatedlyDecode(original) : value;
        }

        if (host === "click.redditmail.com" && url.pathname.indexOf("/CL0/") === 0) {
            return repeatedlyDecode(url.pathname.substring(5).split("/")[0]) || value;
        }

        return value;
    }

    function unwrapKnownRedirect(value) {
        var current = value;
        for (var i = 0; i < 5; i++) {
            var next = unwrapOnce(current);
            if (!next || next === current) break;
            current = next;
        }
        return current;
    }

    function toOpenerURL(value) {
        var url = parseURL(unwrapKnownRedirect(value), window.location.href);
        if (!url || (url.protocol !== "http:" && url.protocol !== "https:") ||
            url.username || url.password || url.port || !isRedditHost(url.hostname) ||
            !url.pathname || url.pathname === "/" || url.searchParams.has(fallbackMarker)) {
            return null;
        }

        if (url.hostname.toLowerCase() === "redd.it" &&
            url.pathname.split("/").filter(Boolean).length !== 1) {
            return null;
        }

        // Bare redd.it is the shortener. Media hosts such as i.redd.it and
        // v.redd.it intentionally fail isRedditHost and remain in the browser.
        url.protocol = "https:";
        return openerOrigin + "/open?url=" + encodeURIComponent(url.href);
    }

    function rewriteAnchor(anchor) {
        if (!anchor || !anchor.href) return;
        if (anchor.getAttribute(rewrittenAttribute) === anchor.href) return;
        var openerURL = toOpenerURL(anchor.href);
        if (!openerURL) return;
        anchor.href = openerURL;
        anchor.setAttribute(rewrittenAttribute, anchor.href);
    }

    function rewriteTree(root) {
        if (!root) return;
        if (root.matches && root.matches("a[href]")) rewriteAnchor(root);
        if (!root.querySelectorAll) return;
        var anchors = root.querySelectorAll("a[href]");
        for (var i = 0; i < anchors.length; i++) rewriteAnchor(anchors[i]);
    }

    function anchorForEvent(event) {
        var path = event.composedPath ? event.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
            if (path[i] && path[i].matches && path[i].matches("a[href]")) return path[i];
        }
        var node = event.target;
        while (node && node !== document) {
            if (node.matches && node.matches("a[href]")) return node;
            node = node.parentNode;
        }
        return null;
    }

    function consumeFallbackMarker() {
        var url = parseURL(window.location.href);
        if (!url || !isRedditHost(url.hostname) || !url.searchParams.has(fallbackMarker)) return;
        url.searchParams.delete(fallbackMarker);
        suppressedURL = url.href;
        try {
            history.replaceState(null, "", url.href);
        } catch (error) {
            // Cosmetic only; suppressedURL is the loop guard.
        }
    }

    function updatePrompt() {
        var openerURL = toOpenerURL(window.location.href);
        if (!openerURL || window.location.href === suppressedURL) {
            if (prompt && prompt.parentNode) prompt.parentNode.removeChild(prompt);
            prompt = null;
            return;
        }
        if (!document.documentElement) return;
        if (!prompt) {
            prompt = document.createElement("a");
            prompt.textContent = "Open in Apollo";
            prompt.setAttribute("aria-label", "Open this Reddit link in Apollo");
            prompt.style.cssText = "position:fixed;z-index:2147483647;right:14px;bottom:14px;padding:11px 16px;border-radius:999px;background:#ff4500;color:#fff;font:600 15px -apple-system,BlinkMacSystemFont,sans-serif;text-decoration:none;box-shadow:0 3px 14px rgba(0,0,0,.3)";
            document.documentElement.appendChild(prompt);
        }
        prompt.href = openerURL;
    }

    consumeFallbackMarker();
    document.addEventListener("pointerdown", function (event) {
        if (typeof event.button !== "number" || event.button === 0) rewriteAnchor(anchorForEvent(event));
    }, true);
    document.addEventListener("click", function (event) {
        if (typeof event.button !== "number" || event.button === 0) rewriteAnchor(anchorForEvent(event));
    }, true);
    window.addEventListener("popstate", updatePrompt);

    var observer = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
            for (var j = 0; j < mutations[i].addedNodes.length; j++) {
                rewriteTree(mutations[i].addedNodes[j]);
            }
        }
        updatePrompt();
    });
    observer.observe(document.documentElement || document, { childList: true, subtree: true });
    rewriteTree(document);
    updatePrompt();
})();
