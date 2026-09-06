#!/bin/sh

set -eu

# Build the actual feature module as a macOS Foundation executable. Each named
# scenario runs in its own process to isolate the production module's statics.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-per-account-favorites-tests.XXXXXX")
test_binary="$test_build_dir/per_account_favorites_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -DAPOLLO_PER_ACCOUNT_FAVORITES_TESTING \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloPerAccountFavorites.m" \
    "$test_repo_root/src/ApolloFavoritesSorting.m" \
    "$test_repo_root/tests/per_account_favorites_tests.m" \
    -o "$test_binary"

test_failures=0
for test_scenario in \
    internal-refresh-switch \
    internal-refresh-disable \
    native-write-switch \
    native-write-disable \
    reentrant-native-write \
    unmarked-native-notification \
    feature-off \
    first-enable \
    sorting-toggle \
    sorting-native-add-remove \
    sorting-account-switch-pending \
    sorting-shared-preference \
    sorting-unknown-identity \
    sorting-restore-pending \
    sorting-refresh-idempotent \
    sorting-unmarked-notification \
    sorting-settings-account-switch \
    sorting-settings-identity-availability \
    sorting-settings-coalesced-switches \
    sorting-settings-unchanged-scope \
    sorting-invalid-store-native-write \
    sorting-invalid-store-native-notification \
    sorting-unsupported-store-native-write \
    sorting-unsupported-store-native-notification; do
    if ! "$test_binary" "$test_scenario"; then
        test_failures=$((test_failures + 1))
    fi
done

if [ "$test_failures" -ne 0 ]; then
    printf 'per_account_favorites_tests: %s scenario(s) failed\n' "$test_failures" >&2
    exit 1
fi
printf 'per_account_favorites_tests: all 24 scenarios passed\n'
