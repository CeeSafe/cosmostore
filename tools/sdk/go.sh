#!/bin/sh
# The AWS SDK for Go v2 against `cosmostore serve` (M3 SDK matrix): tools/sdk/go/main.go, then fsck.
# usage: tools/sdk/go.sh   (needs Go; the first run downloads the SDK modules)
. "$(dirname "$0")/common.sh"
(cd "$(dirname "$0")/go" && go run .) || failed=1
check "no extents left" "$(ls "$work/store/extents" | wc -l | tr -d ' ')" 0
finish "go"
