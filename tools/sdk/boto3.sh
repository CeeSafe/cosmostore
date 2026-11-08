#!/bin/sh
# boto3 against `cosmostore serve` (M3 SDK matrix): tools/sdk/boto3_check.py, then fsck.
# usage: BOTO3_PYTHON=/path/to/python-with-boto3 tools/sdk/boto3.sh   (default: python3)
. "$(dirname "$0")/common.sh"
"${BOTO3_PYTHON:-python3}" -I "$(cd "$(dirname "$0")" && pwd)/boto3_check.py" || failed=1
check "no extents left" "$(ls "$work/store/extents" | wc -l | tr -d ' ')" 0
finish "boto3"
