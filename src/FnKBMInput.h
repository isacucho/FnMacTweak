#ifndef FNKBM_INPUT_H
#define FNKBM_INPUT_H

#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif
void fnReleaseNativeInputs(void);
#ifdef __cplusplus
}
#endif

// Return the last cursor state in complete log lines: shown=1, hidden=0.
static inline int fnkbmScanCursorState(const char *buf, size_t len) {
    static const char marker[] = "bShowMouseCursor Changed, ";
    const size_t markerLen = sizeof(marker) - 1;
    int state = -1;
    const char *cursor = buf, *end = buf + len;
    while ((size_t)(end - cursor) >= markerLen + 13) {
        const char *found = (const char *)memmem(cursor, (size_t)(end - cursor), marker, markerLen);
        if (!found || (size_t)(end - found) < markerLen + 13) break;
        const char *value = found + markerLen;
        if (!memcmp(value, "True -> False", 13)) state = 0;
        else if (!memcmp(value, "False -> True", 13)) state = 1;
        cursor = value;
    }
    return state;
}

static inline size_t fnkbmCompleteLinesLength(const char *buf, size_t len) {
    while (len && buf[len - 1] != '\n') --len;
    return len;
}

#endif
