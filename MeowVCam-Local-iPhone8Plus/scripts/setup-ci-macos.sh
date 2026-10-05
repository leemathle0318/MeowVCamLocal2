#!/bin/bash
set -euo pipefail

# For an ephemeral GitHub macOS runner with full Xcode already installed.
[[ "$(uname -s)" == Darwin ]] || { echo 'This CI setup requires macOS.' >&2; exit 2; }
[[ -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || {
  echo 'This setup script is intended for GitHub Actions.' >&2
  exit 2
}
TASK_THEOS="$RUNNER_TEMP/meowvcam-theos"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
brew install ldid xz
git clone --recursive --depth 1 https://github.com/theos/theos.git "$TASK_THEOS"
export THEOS="$TASK_THEOS"
# Use the installed public Xcode SDK; avoid install-sdk's GitHub API lookup.
TASK_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
TASK_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
mkdir -p "$TASK_THEOS/sdks"
ln -s "$TASK_SDK_PATH" "$TASK_THEOS/sdks/iPhoneOS${TASK_SDK_VERSION}.sdk"
[[ -f "$TASK_THEOS/makefiles/common.mk" ]]
echo "THEOS=$TASK_THEOS" >> "$GITHUB_ENV"
git -C "$TASK_THEOS" rev-parse HEAD
echo 'Theos setup completed. This does not verify device compatibility.'
