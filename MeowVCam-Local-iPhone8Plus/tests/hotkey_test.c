#include "../core/MMHotkey.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    MMHotkey s = {0};
    assert(!mm_hotkey_press(&s, -1, 10));
    assert(!mm_hotkey_press(&s, 1, 11));
    assert(mm_hotkey_press(&s, -1, 11.5));
    assert(!mm_hotkey_press(&s, -1, 11.6));
    assert(!mm_hotkey_press(&s, 1, 12));
    assert(!mm_hotkey_press(&s, -1, 14));
    assert(!mm_hotkey_press(&s, 1, 15));
    assert(!mm_hotkey_press(&s, -1, 14));
    assert(!mm_hotkey_press(&s, 1, 16));
    assert(!mm_hotkey_press(&s, 0, 16.1));
    assert(!mm_hotkey_press(&s, -1, 16.2));
    assert(!mm_hotkey_press(&s, 1, 17));
    assert(!mm_hotkey_press(&s, -1, NAN));
    assert(!mm_hotkey_press(&s, 1, 20));
    assert(!mm_hotkey_press(&s, 1, 20.9));
    assert(mm_hotkey_press(&s, -1, 22.0));
    puts("Volume sequence checks passed: ordering, timeout, reset, repeat, invalid time.");
    return 0;
}
