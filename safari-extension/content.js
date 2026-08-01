// Apollo Reborn — manual fallback Safari Web Extension.
//
// Automatic routing belongs exclusively to the Safari extension embedded in
// Apollo Reborn Link Companion. Keeping this extension passive is important:
// old sideloaded Apollo builds cannot reliably own a Universal Link domain, and
// two automatic extensions racing to navigate the same document recreates the
// flaky behavior this fallback is intended to recover from.
//
// This script therefore does exactly one thing: if a Reddit page remains in
// Safari long enough for the companion handoff not to have happened, it adds a
// real user-tappable Universal Link. It never stops the page, changes location,
// rewrites another link, synthesizes a click, or performs a network request.
(function () {
    "use strict";

    var linkUtils = globalThis.ApolloRebornLinkUtils;
    if (!linkUtils) {
        return;
    }

    var promptDelayMilliseconds = 750;
    var promptTimer = null;
    var promptHost = null;
    var promptLink = null;

    function removePrompt() {
        if (promptHost && promptHost.parentNode) {
            promptHost.parentNode.removeChild(promptHost);
        }
        promptHost = null;
        promptLink = null;
    }

    function renderPrompt() {
        promptTimer = null;

        var openerURL = linkUtils.toOpenerURL(window.location.href);
        if (!openerURL || !document.documentElement) {
            removePrompt();
            return;
        }

        if (!promptHost) {
            promptHost = document.createElement("div");
            promptHost.id = "apollo-reborn-open-prompt";

            promptLink = document.createElement("a");
            promptLink.id = "apollo-reborn-open-link";
            promptLink.textContent = "Open in Apollo";
            promptLink.setAttribute("aria-label", "Open this Reddit link in Apollo");

            promptHost.appendChild(promptLink);
            document.documentElement.appendChild(promptHost);
        }

        promptLink.href = openerURL;
    }

    function schedulePrompt() {
        // Once visible, keep the link current across Reddit's SPA navigation.
        // The initial delay is only to prevent a distracting flash during the
        // companion extension's normal automatic handoff.
        if (promptHost) {
            renderPrompt();
            return;
        }

        // Reddit can mutate the document continuously while hydrating. Never
        // restart an existing timer here or a busy page could postpone the
        // fallback forever.
        if (promptTimer !== null) {
            return;
        }

        promptTimer = window.setTimeout(renderPrompt, promptDelayMilliseconds);
    }

    window.addEventListener("popstate", schedulePrompt);

    var observer = new MutationObserver(function () {
        schedulePrompt();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });

    schedulePrompt();
})();
