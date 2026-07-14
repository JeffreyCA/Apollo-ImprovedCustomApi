#!/bin/bash
# Backward-compatibility shim. The canonical implementation now lives in
# scripts/modules/strip-substrate-arm64e.sh. This file re-exports the same
# functions (including the legacy strip_arm64e_from_substrate_in_{app,ipa}
# names) so existing `source`rs keep working.

# shellcheck source=modules/strip-substrate-arm64e.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules/strip-substrate-arm64e.sh"
