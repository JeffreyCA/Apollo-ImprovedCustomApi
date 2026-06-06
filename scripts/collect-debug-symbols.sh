#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LABEL=""
OUTPUT_DIR="${REPO_DIR}/dist/symbols"

usage() {
    echo "Usage: $0 --label <name> [--output-dir <dir>]"
    echo ""
    echo "Copies Theos-generated .dSYM bundles into a labeled symbol staging folder."
}

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "${1#./}" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            LABEL="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$LABEL" ]]; then
    echo "Error: --label is required."
    usage
    exit 1
fi

OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
DEST_DIR="${OUTPUT_DIR}/${LABEL}"
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

found=0
for search_dir in "${REPO_DIR}/.theos/obj" "${REPO_DIR}/openin-extension/.theos/obj"; do
    [[ -d "$search_dir" ]] || continue
    while IFS= read -r -d '' dsym; do
        found=1
        dest_name="$(basename "$dsym")"
        if [[ -e "${DEST_DIR}/${dest_name}" ]]; then
            parent_name="$(basename "$(dirname "$dsym")")"
            dest_name="${parent_name}-${dest_name}"
        fi
        cp -R "$dsym" "${DEST_DIR}/${dest_name}"
        echo "Collected ${LABEL}/${dest_name}"
    done < <(find "$search_dir" -path '*/debug/*' -prune -o -name '*.dSYM' -type d -prune -print0)
done

if [[ "$found" -eq 0 ]]; then
    echo "Error: no .dSYM bundles found under Theos build directories."
    exit 1
fi
