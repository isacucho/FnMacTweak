#ifndef FN_MOUSE_ROUTING_H
#define FN_MOUSE_ROUTING_H
#include <stdbool.h>

// Follow the input path chosen on press even when cursor/menu state changes
// before release. This prevents unmatched releases and stuck fire/aim buttons.
static inline bool fnRouteMouseButton(bool pressed, bool leftButton, bool locked,
                                     bool settingsOpen, bool active, bool *forwarded) {
    if (!pressed) {
        bool deliver = *forwarded;
        *forwarded = false;
        return deliver;
    }
    bool deliver = active && !settingsOpen && (locked || !leftButton);
    if (deliver) *forwarded = true;
    return deliver;
}

static inline bool fnMouseTouchIsDirect(bool indirectPointer, bool locked) {
    return indirectPointer && !locked;
}

static inline bool fnDropMouseTouch(bool indirectPointer, bool locked, bool settingsWindow) {
    return indirectPointer && locked && !settingsWindow;
}
#endif
