#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gallery-video-manifest-tests.XXXXXX")
test_binary="$test_build_dir/gallery_video_manifest_tests"
test_production_include="$test_build_dir/ApolloGalleryVideoManifestProduction.inc"
trap 'rm -f -- "$test_binary" "$test_production_include"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

# Extract the actual production parser between stable, existing section marks.
# A renamed/missing/duplicate marker fails the runner instead of accidentally
# testing an empty section or silently leaving a stale implementation behind.
python3 - "$test_repo_root/src/ApolloGalleryVideoExport.xm" "$test_production_include" <<'PY_EXTRACT'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start_marker = "#pragma mark - DASH manifest\n"
end_marker = "#pragma mark - Small helpers\n"
if source.count(start_marker) != 1 or source.count(end_marker) != 1:
    raise SystemExit("Cannot uniquely locate the production DASH parser section")
start = source.index(start_marker) + len(start_marker)
end = source.index(end_marker)
if end <= start:
    raise SystemExit("Production DASH parser markers are out of order")
Path(sys.argv[2]).write_text(source[start:end])
PY_EXTRACT

xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Werror \
    -framework Foundation -I "$test_build_dir" \
    "$test_repo_root/tests/gallery_video_manifest_tests.mm" \
    -o "$test_binary"
"$test_binary"
