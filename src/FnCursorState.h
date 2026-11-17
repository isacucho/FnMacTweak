#ifndef FN_CURSOR_STATE_H
#define FN_CURSOR_STATE_H
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// Cursor compatibility only: follow Unreal's menu/gameplay state, without
// synthesizing input or changing the user's bindings.
typedef struct {
    bool haveGameState;
    bool gameCursorShown;
    bool active;
    bool menuOpen;
    int manualLock; // -1 follows the game, 0/1 is a temporary shortcut override
} FnCursorState;

static inline bool fnCursorWantsLock(const FnCursorState *state) {
    if (!state->active || state->menuOpen) return false;
    if (state->manualLock >= 0) return state->manualLock != 0;
    return state->haveGameState && !state->gameCursorShown;
}

// Only consume complete lines so a transition split across reads is retained.
static inline size_t fnCursorCompleteLines(const char *bytes, size_t length) {
    while (length && bytes[length - 1] != '\n') length--;
    return length;
}

static inline int fnCursorScanLog(const char *bytes, size_t length) {
    static const char marker[] = "bShowMouseCursor Changed, ";
    const size_t markerLength = sizeof(marker) - 1, valueLength = 13;
    int result = -1;
    for (size_t i = 0; i + markerLength + valueLength <= length; i++) {
        if (memcmp(bytes + i, marker, markerLength)) continue;
        const char *value = bytes + i + markerLength;
        if (!memcmp(value, "True -> False", valueLength)) result = 0;
        else if (!memcmp(value, "False -> True", valueLength)) result = 1;
        i += markerLength - 1;
    }
    return result;
}
#endif
