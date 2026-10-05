#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_THEOS="${THEOS:-$HOME/theos}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'macOS with Xcode iOS SDK and Theos is required. No .deb was built.' >&2
    exit 2
fi
command -v xcrun >/dev/null || { echo 'Missing Xcode command-line tools.' >&2; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
[[ -f "$TASK_THEOS/makefiles/common.mk" ]] || { echo 'Set THEOS to your Theos installation.' >&2; exit 2; }
cd "$TASK_ROOT"
# Browser uploads may discard executable permissions.
chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
make clean package FINALPACKAGE=1 THEOS="$TASK_THEOS"
echo 'Only a successful build produces installable .deb files under packages/.'
