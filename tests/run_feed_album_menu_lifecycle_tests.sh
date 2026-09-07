#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-feed-album-lifecycle.XXXXXX")
test_binary="$test_build_dir/feed_album_menu_lifecycle_tests"
test_include="$test_build_dir/FeedAlbumMenuLifecycle.inc"
trap 'rm -f -- "$test_binary" "$test_include"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root/src/ApolloFeedAlbumMenus.xm" "$test_include" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

context = between('@interface ApolloFeedAlbumMenuContext', 'static char kApolloFeedAlbumMenuContext')
defer = between('static void ApolloFeedAlbumAfterMenu(', 'static void ApolloFeedAlbumResolve(')
action = between('static UIAction *ApolloFeedAlbumAction(', 'static UIMenu *ApolloFeedAlbumMenu(')
end_method = between('- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:',
                     '- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willPerformPreviewAction')
finish = end_method[end_method.index('    dispatch_block_t finish = ^{'):]
Path(sys.argv[2]).write_text(context + '\n' + defer + '\n' + action +
    '\nstatic void QAEndMenu(ApolloFeedAlbumMenuContext *context, id<UIContextMenuInteractionAnimating> animator) {\n' + finish)
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_build_dir" \
    "$test_repo_root/tests/feed_album_menu_lifecycle_tests.m" -o "$test_binary"
"$test_binary"
