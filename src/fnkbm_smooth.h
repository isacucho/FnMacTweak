// Mouse movement smoothing. Plain C, no dependencies, so it can be tested on its own.
//
// A mouse that reports about 125 times a second does not line up with a game
// drawing 120 frames a second: some frames get no report and some get two, and
// the view moves in steps that look like a low frame rate. Here each report's
// movement is released evenly over the time until the next report is due, so
// every frame gets a share in proportion to its length.
//
// Nothing is smoothed when it would not help: a mouse that reports faster than
// every 2.5 ms goes straight through, and so does a single count of movement.
#ifndef FNKBM_SMOOTH_H
#define FNKBM_SMOOTH_H
#include <math.h>
#include <string.h>

#define FNKBM_SMOOTH_DIRECT_MS 2.5   // reports closer together than this are passed straight on
#define FNKBM_SMOOTH_MAX_MS    12.0  // longest report interval that is smoothed over
#define FNKBM_SMOOTH_SPREAD    1.25  // release window, in report intervals (the extra absorbs late reports)

typedef struct {
    double pendX, pendY;   // movement not yet passed on
    double rateX, rateY;   // release speed, counts per millisecond
    double interval;       // usual time between reports while moving, milliseconds
    double lastArrival;    // milliseconds
    double lastTick;       // milliseconds
} FnkbmSmooth;

static inline void fnkbmSmoothInit(FnkbmSmooth *s) {
    memset(s, 0, sizeof(*s));
    s->interval = 8.0;
}

// A report arrived. Returns 1 when movement goes straight through (in outX/outY),
// 0 when it is held and released by fnkbmSmoothTick.
static inline int fnkbmSmoothAdd(FnkbmSmooth *s, double nowMs, double dx, double dy, double *outX, double *outY) {
    double gap = nowMs - s->lastArrival;
    s->lastArrival = nowMs;
    // Under 0.05 ms is the second axis of the same report; over 20 ms is a pause.
    if (gap >= 0.05 && gap <= 20.0) s->interval += (gap - s->interval) * 0.1;
    if (s->pendX == 0 && s->pendY == 0) s->lastTick = nowMs;
    s->pendX += dx; s->pendY += dy;
    if (s->interval < FNKBM_SMOOTH_DIRECT_MS || (fabs(s->pendX) <= 1.0 && fabs(s->pendY) <= 1.0)) {
        *outX = s->pendX; *outY = s->pendY;
        s->pendX = s->pendY = s->rateX = s->rateY = 0;
        return 1;
    }
    double window = fmin(s->interval, FNKBM_SMOOTH_MAX_MS) * FNKBM_SMOOTH_SPREAD;
    s->rateX = s->pendX / window; s->rateY = s->pendY / window;
    return 0;
}

// Called about once a millisecond. Gives the movement to pass on now.
static inline void fnkbmSmoothTick(FnkbmSmooth *s, double nowMs, double *outX, double *outY) {
    double elapsed = nowMs - s->lastTick;
    s->lastTick = nowMs;
    if (elapsed < 0) elapsed = 0;
    double x = s->rateX * elapsed, y = s->rateY * elapsed;
    if (fabs(x) >= fabs(s->pendX)) x = s->pendX;
    if (fabs(y) >= fabs(s->pendY)) y = s->pendY;
    s->pendX -= x; s->pendY -= y;
    *outX = x; *outY = y;
}

#endif
