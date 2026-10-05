#ifndef MM_HOTKEY_H
#define MM_HOTKEY_H
typedef struct { double upTime; int armed; } MMHotkey;
/* 1 = volume up, -1 = volume down. Return 1 when up -> down is complete. */
int mm_hotkey_press(MMHotkey *state, int button, double seconds);
#endif
