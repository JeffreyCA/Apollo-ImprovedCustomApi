const assert = require("node:assert/strict");
const test = require("node:test");

const links = require("./link-utils.js");

const canonicalVariants = [
    "https://reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://www.reddit.com/r/apolloapp/comments/13rhvfe/title/commentid/?context=3",
    "https://old.reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://new.reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://np.reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://m.reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://de.reddit.com/r/apolloapp/comments/13rhvfe/title/",
    "https://reddit.com/comments/13rhvfe",
    "https://reddit.com/gallery/13rhvfe",
    "https://reddit.com/r/apolloapp/wiki/index",
    "https://reddit.com/u/username",
    "https://reddit.com/user/username/comments",
    "https://reddit.com/r/apolloapp/s/5Jba9qWfeT",
    "https://reddit.com/u/username/s/opaque-token",
    "https://redd.it/13rhvfe"
];

for (const value of canonicalVariants) {
    test(`accepts ${value}`, () => {
        assert.equal(links.redditURL(value)?.href, value);
        assert.match(links.toOpenerURL(value), /^https:\/\/open\.apolloreborn\.app\/open\?url=/);
    });
}

test("upgrades an HTTP Reddit page before building the Universal Link", () => {
    const source = "http://old.reddit.com/r/apolloapp/comments/13rhvfe/title/";
    const normalized = "https://old.reddit.com/r/apolloapp/comments/13rhvfe/title/";
    assert.equal(links.redditURL(source)?.href, normalized);
    assert.equal(
        links.toOpenerURL(source),
        `https://open.apolloreborn.app/open?url=${encodeURIComponent(normalized)}`
    );
});

test("does not treat Reddit media hosts as post short links", () => {
    for (const value of [
        "https://i.redd.it/image.jpg",
        "https://v.redd.it/video/DASHPlaylist.mpd",
        "https://preview.redd.it/image.png",
        "https://external-preview.redd.it/image.jpg"
    ]) {
        assert.equal(links.redditURL(value), null);
    }
});

test("rejects malformed redd.it paths", () => {
    assert.equal(links.toOpenerURL("https://redd.it/abc/extra"), null);
});

test("rejects roots, unsafe schemes, lookalikes, credentials, and fallback loops", () => {
    for (const value of [
        "https://reddit.com/",
        "ftp://reddit.com/r/apolloapp",
        "https://reddit.com.attacker.example/r/apolloapp",
        "https://redd.it.attacker.example/13rhvfe",
        "https://user@reddit.com/r/apolloapp",
        "https://reddit.com:444/r/apolloapp",
        "https://reddit.com/r/apolloapp?apollo_reborn_no_open=1",
        "https://reddit.app.link/opaque-without-an-original-url",
        "https://click.redditmail.com/CL0/example"
    ]) {
        assert.equal(links.redditURL(value), null);
    }
});
