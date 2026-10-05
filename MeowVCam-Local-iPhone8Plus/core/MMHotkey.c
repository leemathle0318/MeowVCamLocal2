#include "MMHotkey.h"
#include <math.h>
int mm_hotkey_press(MMHotkey *s, int button, double time) {
    if (!isfinite(time)) { s->armed = 0; return 0; }
    if (button == 1) { s->upTime = time; s->armed = 1; return 0; }
    if (button == -1) {
        int trigger = s->armed && time >= s->upTime && time - s->upTime <= 1.5;
        s->armed = 0; return trigger;
    }
    s->armed = 0; return 0;
}
