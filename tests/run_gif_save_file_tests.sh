#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gif-save.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
python3 - "$test_root/src/ApolloGIFSaveActivity.xm" "$test_dir/GIFSaveFile.inc" <<'EXTRACT'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
def method(start,end):
 a=s.index(start);return s[a:s.index(end,a)]
Path(sys.argv[2]).write_text('@implementation ApolloGIFSaveActivityContext\n'+method('- (void)dealloc {','- (void)reportError:')+method('- (BOOL)prepareFile {','- (void)save {')+'@end\n')
EXTRACT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -I "$test_dir" "$test_root/tests/gif_save_file_tests.m" -o "$test_dir/test"
"$test_dir/test"
