#!/bin/bash
# Build (if needed) and run the host-side Apple translation bridge for
# simulator testing. See scripts/apple-translate-bridge.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .sim
if [ ! -x .sim/apple-bridge ] || [ scripts/apple-translate-bridge.swift -nt .sim/apple-bridge ]; then
    echo "compiling apple-translate-bridge…"
    swiftc -O -parse-as-library scripts/apple-translate-bridge.swift -o .sim/apple-bridge
fi
exec .sim/apple-bridge
