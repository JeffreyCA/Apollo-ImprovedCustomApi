#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-inline-video.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root/src/ApolloMediaDownloadActions.xm" "$test_build_dir/InlineVideo.inc" <<'EXTRACT'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
context=source[source.index('@interface ApolloInlineVideoActionContext'):source.index('static char kApolloInlineVideoActionContext')]
helpers=source[source.index('static NSURL *ApolloInlineVideoPreviewURL'):source.index('%hook _TtC6Apollo19PostCellActionTaker')]
finish=source[source.index('    dispatch_block_t finish = ^{'):source.index('\n%end')]
model=Path(sys.argv[1]).with_name("ApolloSaveAllMediaItems.m").read_text()
item=model[model.index("@implementation ApolloSaveAllMediaItem"):model.index("\nstatic NSString *ApolloAllString")]
Path(sys.argv[2]).write_text(item+context+helpers+'\nstatic void QAEndMenu(ApolloInlineVideoActionContext *context, id<UIContextMenuInteractionAnimating> animator) {\n'+finish)
EXTRACT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
 -I "$test_build_dir" -I "$test_repo_root/src" "$test_repo_root/tests/inline_video_menu_tests.m" \
 -o "$test_build_dir/tests"
"$test_build_dir/tests"
