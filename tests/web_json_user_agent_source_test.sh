#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$repo_root/src/ApolloWebJSON.m"

fail() {
    printf 'web_json_user_agent_source_test: %s\n' "$1" >&2
    exit 1
}

# Web JSON may consult the configured OAuth User-Agent only in the explicit
# real-OAuth branch of ApolloWebJSONFetchModernThingData. Every cookie-session
# request must use the browser identity or Reddit can classify it as Dystopia /
# RedReader Data API traffic and replace mature listings with a placeholder.
custom_user_agent_references=$(grep -c 'sUserAgent length' "$source_file" || true)
[ "$custom_user_agent_references" -eq 1 ] ||
    fail "expected one real-OAuth custom User-Agent branch, found $custom_user_agent_references"

browser_user_agent_references=$(grep -c 'setValue:ApolloWebJSONBrowserUserAgent()' "$source_file" || true)
[ "$browser_user_agent_references" -ge 6 ] ||
    fail "cookie-session requests are not consistently using the browser User-Agent"

printf 'web_json_user_agent_source_test passed\n'
