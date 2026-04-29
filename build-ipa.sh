#!/bin/bash
set -euo pipefail

IPA_PATH=""
DEB_PATH=""
OUTPUT_IPA="Apollo-Tweaked.ipa"

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> [--deb <packages/*.deb>] [-o <output.ipa>]"
    echo ""
    echo "Options:"
    echo "  --ipa <file>      Path to base Apollo IPA (required)"
    echo "  --deb <file>      Path to tweak .deb (default: newest in packages/)"
    echo "  -o, --output      Output IPA filename (default: Apollo-Tweaked.ipa)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --ipa ./Apollo.ipa"
    echo "  $0 --ipa ./Apollo.ipa --deb ./packages/ca.jeffrey.apollo-improvedcustomapi_*.deb -o ./packages/Apollo-Tweaked.ipa"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa)
            IPA_PATH="$2"
            shift 2
            ;;
        --deb)
            DEB_PATH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_IPA="$2"
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

if [[ -z "$IPA_PATH" ]]; then
    echo "Error: --ipa is required"
    usage
    exit 1
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

if [[ -z "$DEB_PATH" ]]; then
    latest_deb=$(ls -1t packages/*.deb 2>/dev/null | head -1 || true)
    if [[ -z "$latest_deb" ]]; then
        echo "Error: No .deb found in packages/. Run 'make package' first or pass --deb."
        exit 1
    fi
    DEB_PATH="$latest_deb"
fi

if [[ ! -f "$DEB_PATH" ]]; then
    echo "Error: .deb not found: $DEB_PATH"
    exit 1
fi

echo "Base IPA : $IPA_PATH"
echo "Tweak DEB: $DEB_PATH"
echo "Output   : $OUTPUT_IPA"

if command -v azule >/dev/null 2>&1; then
    echo "Using azule for injection..."

    if azule -i "$IPA_PATH" -f "$DEB_PATH" -o "$OUTPUT_IPA"; then
        echo "Injected IPA created at: $OUTPUT_IPA"
        exit 0
    fi

    echo "azule command failed with -o syntax, retrying fallback syntax..."
    azule -i "$IPA_PATH" -f "$DEB_PATH"

    generated=$(ls -1t ./*.ipa 2>/dev/null | head -1 || true)
    if [[ -z "$generated" ]]; then
        echo "Error: azule did not produce an IPA."
        exit 1
    fi

    if [[ "$generated" != "$OUTPUT_IPA" ]]; then
        mv -f "$generated" "$OUTPUT_IPA"
    fi

    echo "Injected IPA created at: $OUTPUT_IPA"
    exit 0
fi

if command -v cyan >/dev/null 2>&1; then
    echo "Using cyan for injection..."

    if cyan -i "$IPA_PATH" -d "$DEB_PATH" -o "$OUTPUT_IPA"; then
        echo "Injected IPA created at: $OUTPUT_IPA"
        exit 0
    fi

    echo "Error: cyan injection failed."
    exit 1
fi

echo "Error: Neither 'azule' nor 'cyan' is installed."
echo "Install one of them, then rerun this script."
exit 1
