// Pure Reddit URL validation shared by the fallback content script and tests.
(function (root, factory) {
    "use strict";

    var api = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    }
    root.ApolloRebornLinkUtils = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
    "use strict";

    var fallbackMarker = "apollo_reborn_no_open";
    var universalLinkOrigin = "https://open.apolloreborn.app";

    function isHostOrSubdomain(host, domain) {
        host = (host || "").toLowerCase();
        return host === domain || host.endsWith("." + domain);
    }

    function isRedditWebHost(host) {
        return isHostOrSubdomain(host, "reddit.com");
    }

    // Only bare redd.it is a post shortener. Its media subdomains are not
    // navigable Reddit posts and must never be sent through Link Companion.
    function isRedditShortHost(host) {
        return (host || "").toLowerCase() === "redd.it";
    }

    function redditURL(value) {
        var url;
        try {
            url = new URL(value);
        } catch (error) {
            return null;
        }

        if ((url.protocol !== "http:" && url.protocol !== "https:") ||
            url.username || url.password || url.port) {
            return null;
        }
        if (!isRedditWebHost(url.hostname) && !isRedditShortHost(url.hostname)) {
            return null;
        }
        if (!url.pathname || url.pathname === "/" || url.searchParams.has(fallbackMarker)) {
            return null;
        }
        if (isRedditShortHost(url.hostname) && url.pathname.split("/").filter(Boolean).length !== 1) {
            return null;
        }

        url.protocol = "https:";
        return url;
    }

    function toOpenerURL(value) {
        var url = redditURL(value);
        return url ? universalLinkOrigin + "/open?url=" + encodeURIComponent(url.href) : null;
    }

    return {
        fallbackMarker: fallbackMarker,
        isRedditWebHost: isRedditWebHost,
        isRedditShortHost: isRedditShortHost,
        redditURL: redditURL,
        toOpenerURL: toOpenerURL
    };
});
