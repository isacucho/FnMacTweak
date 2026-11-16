// Scans a chunk of the Unreal log for the game's cursor state changes.
// The game logs "Player bShowMouseCursor Changed, True -> False" when it
// hides the cursor (gameplay) and "... False -> True" when it shows it
// (menus). Returns the last state found in the chunk: 1 cursor shown,
// 0 cursor hidden, -1 no change in this chunk.
#ifndef FNKBM_LOGSCAN_H
#define FNKBM_LOGSCAN_H
#include <string.h>
#include <stddef.h>

static inline int fnkbmScanCursorState(const char *buf, size_t len) {
    static const char key[] = "bShowMouseCursor Changed, ";
    const size_t klen = sizeof(key) - 1, vlen = 13;  // "True -> False" / "False -> True"
    int last = -1;
    const char *p = buf, *end = buf + len;
    while ((size_t)(end - p) >= klen + vlen) {
        const char *hit = (const char *)memmem(p, (size_t)(end - p), key, klen);
        if (!hit || (size_t)(end - hit) < klen + vlen) break;
        const char *v = hit + klen;
        if (memcmp(v, "True -> False", vlen) == 0) last = 0;
        else if (memcmp(v, "False -> True", vlen) == 0) last = 1;
        p = v;
    }
    return last;
}

// Length of the prefix of buf that ends at the last newline (0 if none).
static inline size_t fnkbmCompleteLinesLength(const char *buf, size_t len) {
    while (len > 0 && buf[len - 1] != '\n') len--;
    return len;
}
#endif
