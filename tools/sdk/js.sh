#!/bin/sh
# The AWS SDK for JavaScript v3 against `cosmostore serve` (M3 SDK matrix): tools/sdk/js/check.mjs, then fsck.
# usage: JS_SDK_DIR=<dir with node_modules/@aws-sdk/{client-s3,lib-storage,s3-request-presigner}> tools/sdk/js.sh
. "$(dirname "$0")/common.sh"
here=$(cd "$(dirname "$0")" && pwd)
# ESM resolves packages from the script's directory upwards, so the check runs from a copy next to node_modules.
cp "$here/js/check.mjs" "${JS_SDK_DIR:?set JS_SDK_DIR}/check.mjs"
node "$JS_SDK_DIR/check.mjs" || failed=1
check "no extents left" "$(ls "$work/store/extents" | wc -l | tr -d ' ')" 0
finish "js"
