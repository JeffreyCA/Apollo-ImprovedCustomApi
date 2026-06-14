// ==UserScript==
// @name         Apollo Reddit OAuth Code Helper
// @namespace    apollo-reborn
// @version      1.2.0
// @description  On the Reddit "would like to connect to your account" page, captures the OAuth authorization code so you can paste it into Apollo. Works with both the legacy (/api/v1/authorize) and modern shreddit (/svc/shreddit/oauth-grant) consent flows. For iOS browsers (e.g. Reynard) where the apollo:// (or any custom URL scheme) app callback can't be handed off.
// @author       Apollo-Reborn
// @match        *://old.reddit.com/api/v1/authorize*
// @match        *://www.reddit.com/api/v1/authorize*
// @match        *://reddit.com/api/v1/authorize*
// @run-at       document-idle
// @grant        GM_xmlhttpRequest
// @grant        GM_setClipboard
// @connect      old.reddit.com
// @connect      www.reddit.com
// @connect      reddit.com
// ==/UserScript==

/*
 * How it works
 * ------------
 * Tapping "Allow" does a full-page form POST. Reddit replies with a 302 whose
 * Location is the app callback, e.g.
 *     Location: apollo://reddit-oauth?state=RedditKit&code=rd-XXXX#_
 * On iOS the browser can't open that custom scheme, so the code is lost.
 *
 * Two consent flows exist:
 *   - legacy old.reddit:  POST /api/v1/authorize       (authorize=Allow, uh=...)
 *   - modern shreddit:    POST /svc/shreddit/oauth-grant (authorize=ALLOW, csrf_token=...)
 * We don't hardcode either — we serialize whatever the real consent form is and
 * POST to its own action.
 *
 * Reading the 302 callback from script is the hard part: page fetch() with
 * redirect:"manual" returns an opaque response (no headers/body). We use the
 * privileged GM_xmlhttpRequest and look for the callback in EVERY place it can
 * appear — the Location header, the response body ("Redirecting to ..."), and
 * finalUrl — first with redirect:"manual", then falling back to redirect:"follow"
 * (where the engine often exposes the custom-scheme target as finalUrl). If all
 * of that still fails, we dump diagnostics into the overlay so it can be
 * reported back.
 */

(function () {
    "use strict";

    const LOG = (...a) => console.log("[Apollo OAuth Helper]", ...a);

    // ---- callback detection ----------------------------------------------

    function isCustomCallback(u) {
        return !!u &&
            /^[a-z][\w+.-]*:\/\//i.test(u) &&
            !/^https?:/i.test(u) &&
            /[?&#]code=/.test(u);
    }

    function findLocationHeader(headers) {
        if (!headers) return null;
        const m = /^location:\s*(.+)$/im.exec(headers);
        if (!m) return null;
        const val = m[1].trim();
        return isCustomCallback(val) ? val : (/[?&#]code=/.test(val) ? val : null);
    }

    // Scan arbitrary text (headers blob, or the "Redirecting to ..." body) for a
    // custom-scheme URL carrying ?code=. HTML-escapes &amp; back to & first.
    function findCallbackInText(text) {
        if (!text) return null;
        const decoded = text.replace(/&amp;/g, "&");
        const m = /([a-z][\w+.-]*:\/\/[^\s"'<>]*[?&#]code=[^\s"'<>]+)/i.exec(decoded);
        if (!m) return null;
        let url = m[1].replace(/[.\s]+$/, ""); // trim trailing period/space from prose
        return /^https?:/i.test(url) ? null : url;
    }

    function extractCallback(res) {
        const headers = (res && res.responseHeaders) || "";
        const text = (res && res.responseText) || "";
        const finalUrl = res && res.finalUrl;
        return (
            findLocationHeader(headers) ||
            (isCustomCallback(finalUrl) ? finalUrl : null) ||
            findCallbackInText(headers) ||
            findCallbackInText(text) ||
            null
        );
    }

    function parseCallback(raw) {
        const out = { code: null, state: null, error: null };
        const grab = (re) => { const x = re.exec(raw); return x ? decodeURIComponent(x[1]) : null; };
        out.code = grab(/[?&#]code=([^&#]+)/);
        out.state = grab(/[?&#]state=([^&#]+)/);
        out.error = grab(/[?&#]error=([^&#]+)/);
        return out;
    }

    // ---- form location + replay ------------------------------------------

    function findConsentForm() {
        const forms = Array.from(document.querySelectorAll("form"));
        return forms.find(f =>
            f.querySelector('[name="client_id"]') ||
            f.querySelector('[name="redirect_uri"]') ||
            f.querySelector('[name="authorize"]') ||
            f.querySelector('[name="csrf_token"]')
        ) || null;
    }

    function looksLikeAllow(submitter) {
        if (!submitter) return true; // no info -> assume Allow
        const text = (submitter.value || submitter.textContent || "").trim();
        if (/decline|deny|cancel/i.test(text)) return false;
        return /allow|accept|authorize/i.test(text) || true;
    }

    function getCookie(name) {
        const m = document.cookie.match(new RegExp("(?:^|;\\s*)" + name + "=([^;]*)"));
        return m ? decodeURIComponent(m[1]) : null;
    }

    function captureCode(form, submitter) {
        const action = form.getAttribute("action") || location.href;
        const url = new URL(action, location.href).href;

        const params = new URLSearchParams();
        new FormData(form).forEach((v, k) => params.append(k, v));
        if (submitter && submitter.name) {
            if (!params.has(submitter.name)) params.append(submitter.name, submitter.value || "");
        } else if (!params.has("authorize")) {
            params.append("authorize", "Allow");
        }

        // CSRF: the modern /svc/shreddit/oauth-grant endpoint uses a double-submit
        // token — the body csrf_token must match the csrf_token cookie, and it
        // checks Origin/Referer. From the extension context the SameSite=Strict
        // csrf cookie isn't attached and Origin/Referer differ, so the grant 400s
        // before issuing the redirect. The csrf cookie is NOT HttpOnly, so read it
        // and force both sides to agree (and set Origin/Referer in doGrant).
        const csrf = getCookie("csrf_token");
        if (csrf) {
            params.set("csrf_token", csrf);
            LOG("using csrf_token cookie:", csrf.slice(0, 8) + "…");
        } else {
            LOG("no csrf_token cookie found in document.cookie");
        }

        LOG("captured consent form -> action:", url);
        showOverlay({ loading: true });
        doGrant(url, params.toString(), csrf, "manual", /*allowFallback*/ true);
    }

    function doGrant(url, body, csrf, mode, allowFallback) {
        LOG("POST", url, "redirect:", mode);
        const req = {
            method: "POST",
            url: url,
            redirect: mode,
            anonymous: false, // include the browser's cookies (session, etc.)
            headers: {
                "Content-Type": "application/x-www-form-urlencoded",
                "Origin": location.origin,
                "Referer": location.href
            },
            data: body,
            onload: (r) => handleResponse(r, url, body, csrf, mode, allowFallback),
            onerror: (r) => handleResponse(r, url, body, csrf, mode, allowFallback),
            ontimeout: (r) => handleResponse(r, url, body, csrf, mode, allowFallback)
        };
        // Patch the csrf cookie into the request in case SameSite=Strict stops the
        // engine attaching it from the jar.
        if (csrf) req.cookie = "csrf_token=" + csrf;
        GM_xmlhttpRequest(req);
    }

    function handleResponse(res, url, body, csrf, mode, allowFallback) {
        const status = res && res.status;
        const finalUrl = res && res.finalUrl;
        const headers = (res && res.responseHeaders) || "";
        const text = (res && res.responseText) || "";
        LOG("response [" + mode + "]", { status, finalUrl, headersLen: headers.length, bodyLen: text.length });
        LOG("headers:\n" + headers);
        LOG("body (first 500):\n" + text.slice(0, 500));

        const callback = extractCallback(res);

        if (!callback && allowFallback && mode === "manual") {
            LOG("manual mode found nothing — retrying with redirect:follow");
            doGrant(url, body, csrf, "follow", /*allowFallback*/ false);
            return;
        }

        if (!callback) {
            showOverlay({ diag: { status, finalUrl, headers, text } });
            return;
        }

        LOG("callback:", callback);
        const parsed = parseCallback(callback);
        if (parsed.error) {
            showOverlay({ error: "Reddit returned an error: " + parsed.error });
        } else if (parsed.code) {
            showOverlay({ code: parsed.code, state: parsed.state, callback });
        } else {
            showOverlay({ error: "Callback had no authorization code:\n" + callback });
        }
    }

    // ---- overlay UI -------------------------------------------------------

    function button(label, bg, fg) {
        const b = document.createElement("button");
        b.textContent = label;
        b.setAttribute("style", [
            "appearance:none", "border:none", "border-radius:10px",
            "background:" + bg, "color:" + fg, "font:600 16px -apple-system,system-ui,sans-serif",
            "padding:13px 16px", "width:100%", "margin-top:8px", "cursor:pointer"
        ].join(";"));
        return b;
    }

    function copyButton(label, getText, statusEl, bg, fg) {
        const b = button(label, bg, fg);
        b.addEventListener("click", () => {
            try { GM_setClipboard(getText()); statusEl.textContent = "Copied!"; }
            catch (e) { statusEl.textContent = "Long-press the box above to copy."; }
        });
        return b;
    }

    function showOverlay(opts) {
        const { loading, error, code, state, callback, diag } = opts;
        let host = document.getElementById("apollo-oauth-overlay");
        if (host) host.remove();
        host = document.createElement("div");
        host.id = "apollo-oauth-overlay";

        const box = document.createElement("div");
        box.setAttribute("style", [
            "position:fixed", "inset:0", "z-index:2147483647",
            "background:rgba(0,0,0,0.6)", "display:flex",
            "align-items:center", "justify-content:center", "padding:18px"
        ].join(";"));

        const card = document.createElement("div");
        card.setAttribute("style", [
            "background:#fff", "color:#111", "max-width:480px", "width:100%",
            "max-height:88vh", "overflow:auto", "border-radius:16px", "padding:22px",
            "box-sizing:border-box", "font:16px/1.45 -apple-system,system-ui,sans-serif",
            "box-shadow:0 10px 40px rgba(0,0,0,0.35)"
        ].join(";"));

        const status = document.createElement("div");
        status.setAttribute("style", "min-height:1.2em;color:#1a8a1a;font-size:.85rem;margin:8px 0 0");

        if (loading) {
            card.innerHTML = "<h2 style='margin:0 0 8px;font-size:1.15rem'>Getting your code…</h2>" +
                "<p style='margin:0;opacity:.7'>Confirming authorization with Reddit.</p>";
        } else if (error) {
            card.innerHTML = "<h2 style='margin:0 0 10px;font-size:1.15rem;color:#c0392b'>Something went wrong</h2>" +
                "<pre style='white-space:pre-wrap;word-break:break-word;margin:0 0 14px;font:13px ui-monospace,monospace'></pre>";
            card.querySelector("pre").textContent = error;
            card.appendChild(closeButton(host));
        } else if (diag) {
            const dump =
                "status: " + diag.status + "\n" +
                "finalUrl: " + diag.finalUrl + "\n\n" +
                "--- responseHeaders ---\n" + (diag.headers || "(empty)") + "\n\n" +
                "--- body (first 1000) ---\n" + ((diag.text || "(empty)").slice(0, 1000));
            card.innerHTML =
                "<h2 style='margin:0 0 6px;font-size:1.15rem;color:#c0392b'>Couldn't read the callback</h2>" +
                "<p style='margin:0 0 12px;opacity:.7;font-size:.9rem'>The Allow request went through, but the code wasn't in the header, body, or final URL. Copy this diagnostic and send it to the developer.</p>" +
                "<pre style='white-space:pre-wrap;word-break:break-all;margin:0 0 8px;font:11px ui-monospace,monospace;background:#f1f1f1;border-radius:10px;padding:10px;max-height:40vh;overflow:auto'></pre>";
            card.querySelector("pre").textContent = dump;
            card.appendChild(copyButton("Copy diagnostics", () => dump, status, "#d93900", "#fff"));
            card.appendChild(status);
            card.appendChild(closeButton(host));
        } else {
            card.innerHTML =
                "<h2 style='margin:0 0 4px;font-size:1.2rem'>Authorization code</h2>" +
                "<p style='margin:0 0 16px;opacity:.7;font-size:.92rem'>Copy this and paste it into Apollo to finish signing in.</p>" +
                "<div style='font:600 12px/1 ui-monospace,monospace;text-transform:uppercase;letter-spacing:.04em;opacity:.55;margin-bottom:6px'>CODE</div>" +
                "<div id='apollo-code' style='font:15px ui-monospace,monospace;word-break:break-all;background:#f1f1f1;border-radius:10px;padding:12px 14px;user-select:all;-webkit-user-select:all'></div>";
            card.querySelector("#apollo-code").textContent = code;
            card.appendChild(copyButton("Copy code", () => code, status, "#d93900", "#fff"));
            if (callback) {
                card.appendChild(copyButton("Copy full callback URL", () => callback, status, "#e8e8e8", "#111"));
            }
            card.appendChild(status);
            card.appendChild(closeButton(host));
        }

        box.appendChild(card);
        host.appendChild(box);
        document.documentElement.appendChild(host);
    }

    function closeButton(host) {
        const b = button("Close", "transparent", "#888");
        b.addEventListener("click", () => host.remove());
        return b;
    }

    // ---- wire up the form -------------------------------------------------

    function attach() {
        const form = findConsentForm();
        if (!form || form.dataset.apolloHooked) return false;
        form.dataset.apolloHooked = "1";
        LOG("hooked consent form, action =", form.getAttribute("action"));

        form.addEventListener("submit", (e) => {
            const submitter = e.submitter;
            if (!looksLikeAllow(submitter)) {
                LOG("non-Allow submit, ignoring");
                return; // let Decline behave normally
            }
            e.preventDefault();
            e.stopImmediatePropagation();
            captureCode(form, submitter);
        }, true);
        return true;
    }

    if (!attach()) {
        const obs = new MutationObserver(() => { if (attach()) obs.disconnect(); });
        obs.observe(document.documentElement, { childList: true, subtree: true });
        setTimeout(() => obs.disconnect(), 10000);
    }
})();
