#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-save-all-bridge-tests.XXXXXX")
test_object="$test_build_dir/bridge_tests.o"
test_binary="$test_build_dir/bridge_tests"
trap 'rm -f -- "$test_object" "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -c -fobjc-arc -Wall -Wextra -Werror \
    "$test_repo_root/tests/save_all_media_bridge_tests.m" -o "$test_object"
xcrun --sdk macosx swiftc -parse-as-library \
    "$test_repo_root/src/ApolloSaveAllMediaBridge.swift" \
    "$test_repo_root/tests/save_all_media_bridge_fixtures.swift" \
    "$test_object" -o "$test_binary"
"$test_binary"
