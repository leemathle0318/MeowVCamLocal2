#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
TASK_TEMP="$(mktemp -d)"
cc -std=c11 -O2 -Wall -Wextra -Werror -pthread \
    "$TASK_ROOT/core/MMTimeline.c" "$TASK_ROOT/tests/timeline_test.c" \
    -lm -o "$TASK_TEMP/timeline-test"
"$TASK_TEMP/timeline-test"
cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$TASK_ROOT/core/MMHotkey.c" "$TASK_ROOT/tests/hotkey_test.c" \
    -lm -o "$TASK_TEMP/hotkey-test"
"$TASK_TEMP/hotkey-test"
cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$TASK_ROOT/core/MMIPC.c" "$TASK_ROOT/tests/ipc_test.c" \
    -lm -o "$TASK_TEMP/ipc-test"
"$TASK_TEMP/ipc-test"
cc -std=c11 -O2 -Wall -Wextra -Werror -pthread \
    "$TASK_ROOT/core/MMTimeline.c" "$TASK_ROOT/core/MMAudioMix.c" "$TASK_ROOT/tests/audio_mix_test.c" \
    -lm -o "$TASK_TEMP/audio-mix-test"
"$TASK_TEMP/audio-mix-test"
bash -n "$TASK_ROOT/scripts/build-macos.sh"
bash -n "$TASK_ROOT/scripts/setup-ci-macos.sh"
sh -n "$TASK_ROOT/layout/DEBIAN/postinst"
sh -n "$TASK_ROOT/layout/DEBIAN/prerm"
echo 'Portable checks passed. iOS compilation and device compatibility are NOT verified.'
