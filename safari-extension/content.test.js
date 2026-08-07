const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const links = require("./link-utils.js");
const source = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

function runContentScript(href) {
    const timers = [];
    const appended = [];
    let observerCallback = null;

    function element(tagName) {
        return {
            tagName,
            children: [],
            attributes: {},
            appendChild(child) {
                child.parentNode = this;
                this.children.push(child);
            },
            setAttribute(name, value) {
                this.attributes[name] = value;
            }
        };
    }

    const documentElement = element("html");
    documentElement.appendChild = function (child) {
        child.parentNode = this;
        this.children.push(child);
        appended.push(child);
    };
    documentElement.removeChild = function (child) {
        this.children = this.children.filter((candidate) => candidate !== child);
    };

    const window = {
        location: { href },
        addEventListener() {},
        setTimeout(callback, delay) {
            timers.push({ callback, delay, cancelled: false });
            return timers.length;
        },
        clearTimeout(identifier) {
            if (timers[identifier - 1]) {
                timers[identifier - 1].cancelled = true;
            }
        }
    };

    class MutationObserver {
        constructor(callback) {
            this.callback = callback;
            observerCallback = callback;
        }
        observe() {}
    }

    const sandbox = {
        ApolloRebornLinkUtils: links,
        MutationObserver,
        URL,
        document: {
            documentElement,
            createElement: element
        },
        window
    };

    vm.runInNewContext(source, sandbox);
    return {
        appended,
        timers,
        window,
        mutate() {
            observerCallback();
        }
    };
}

test("never navigates and waits before displaying the manual link", () => {
    const href = "https://www.reddit.com/r/apolloapp/comments/13rhvfe/title/";
    const execution = runContentScript(href);

    assert.equal(execution.window.location.href, href);
    assert.equal(execution.appended.length, 0);
    assert.equal(execution.timers.length, 1);
    assert.equal(execution.timers[0].delay, 750);

    for (let index = 0; index < 10; index += 1) {
        execution.mutate();
    }
    assert.equal(execution.timers.length, 1, "DOM hydration must not postpone the fallback");

    execution.timers[0].callback();
    assert.equal(execution.window.location.href, href);
    assert.equal(execution.appended.length, 1);

    const link = execution.appended[0].children[0];
    assert.equal(link.textContent, "Open in Apollo");
    assert.equal(link.href, links.toOpenerURL(href));
});

test("does not show a button for a Worker fallback URL", () => {
    const execution = runContentScript(
        "https://reddit.com/r/apolloapp?apollo_reborn_no_open=1"
    );
    execution.timers[0].callback();
    assert.equal(execution.appended.length, 0);
});

test("manifest is Reddit-only and has no automatic-routing permission", () => {
    const manifest = JSON.parse(
        fs.readFileSync(path.join(__dirname, "manifest.json"), "utf8")
    );
    const script = manifest.content_scripts[0];

    assert.equal(script.run_at, "document_end");
    assert.deepEqual(
        script.matches,
        ["*://reddit.com/*", "*://*.reddit.com/*", "*://redd.it/*"]
    );
    assert.equal(manifest.permissions, undefined);
    assert.doesNotMatch(source, /window\.stop|location\.replace|location\.assign/);
});
