// Cloudflare Worker for open.apolloreborn.app — the Universal Link bounce host.
//
// Two jobs:
//  1. Serve the apple-app-site-association (AASA) file. Apple's CDN fetches it
//     at app-install time; it must be served over HTTPS, with a JSON content
//     type, and MUST NOT be behind a redirect.
//  2. For every other request (a human whose device doesn't have the router
//     app installed — Universal Links fall through to the browser in that
//     case), 302 back to the real reddit.com page so the link still works
//     for everyone.
//
// Deploy: wrangler deploy, with a route for open.apolloreborn.app/* — same
// setup pattern as the existing beat.apolloreborn.app Worker.
//
// After changing the AASA (e.g. a new TeamID.BundleID), note that Apple's CDN
// caches it for hours and devices refresh on app install/update — test with a
// fresh install, not an existing one.

const AASA = {
  applinks: {
    details: [
      {
        // Replace with the router app's real TeamID.BundleID before deploying.
        appIDs: ["TEAMID.com.example.linkhop"],
        components: [{ "/": "/*" }],
      },
    ],
  },
};

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (
      url.pathname === "/.well-known/apple-app-site-association" ||
      url.pathname === "/apple-app-site-association"
    ) {
      return new Response(JSON.stringify(AASA), {
        headers: {
          "content-type": "application/json",
          "cache-control": "max-age=3600",
        },
      });
    }

    // Browser fallback: reconstruct the canonical Reddit URL from the path.
    const dest = new URL(url.pathname + url.search, "https://www.reddit.com");
    return Response.redirect(dest.toString(), 302);
  },
};
