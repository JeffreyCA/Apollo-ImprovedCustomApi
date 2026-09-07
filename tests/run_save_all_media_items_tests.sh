#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-save-all-media-tests.XXXXXX")
test_binary="$test_build_dir/save_all_media_items_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/tests/save_all_media_items_tests.m" \
    "$test_repo_root/src/ApolloMediaMetadata.m" \
    "$test_repo_root/src/ApolloWebTextDecoding.m" \
    -o "$test_binary"
"$test_binary"
