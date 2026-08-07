const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const links = require("../link-utils.js");
const source = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

function runContentScript(href, isAutomatic = true) {
    const replacements = [];
    let stopped = 0;
    let observerCallback = null;

    const location = {
        href,
        replace(value) {
            replacements.push(value);
            this.href = value;
        }
    };

    const window = {
        location,
        history: {
            replaceState(_state, _title, value) {
                location.href = value;
            }
        },
        addEventListener() {},
        stop() {
            stopped += 1;
        }
    };

    class MutationObserver {
        constructor(callback) {
            observerCallback = callback;
        }
        observe() {}
    }

    const stored = { automaticObj: { isAutomatic } };
    const browser = {
        storage: {
            local: {
                get(argument) {
                    if (typeof argument === "function") {
                        argument(stored);
                    }
                    return undefined;
                }
            }
        }
    };

    const sandbox = {
        ApolloRebornLinkUtils: links,
        MutationObserver,
        URL,
        browser,
        document: { documentElement: {} },
        window
    };

    vm.runInNewContext(source, sandbox);
    return {
        location,
        replacements,
        stopped,
        observerInstalled: observerCallback !== null
    };
}

test("automatically routes an eligible Reddit URL through the Reborn opener", () => {
    const href = "https://www.reddit.com/r/apolloapp/comments/13rhvfe/title/";
    const execution = runContentScript(href);

    assert.equal(execution.stopped, 1);
    assert.deepEqual(execution.replacements, [links.toOpenerURL(href)]);
    assert.equal(execution.observerInstalled, true);
});

test("does nothing when the automatic toggle is off", () => {
    const execution = runContentScript(
        "https://www.reddit.com/r/apolloapp/comments/13rhvfe/title/",
        false
    );

    assert.equal(execution.stopped, 0);
    assert.deepEqual(execution.replacements, []);
    assert.equal(execution.observerInstalled, false);
});

test("consumes the Worker fallback marker without reopening", () => {
    const execution = runContentScript(
        "https://reddit.com/r/apolloapp?apollo_reborn_no_open=1"
    );

    assert.equal(execution.location.href, "https://reddit.com/r/apolloapp");
    assert.equal(execution.stopped, 0);
    assert.deepEqual(execution.replacements, []);
});

test("manifest is clearly labelled, Reddit-only, and storage-backed", () => {
    const manifest = JSON.parse(
        fs.readFileSync(path.join(__dirname, "manifest.json"), "utf8")
    );
    const script = manifest.content_scripts[0];

    assert.equal(manifest.name, "Open in Apollo (Legacy)");
    assert.equal(script.run_at, "document_end");
    assert.deepEqual(
        script.matches,
        ["*://reddit.com/*", "*://*.reddit.com/*", "*://redd.it/*"]
    );
    assert.deepEqual(manifest.permissions, ["storage"]);
});
