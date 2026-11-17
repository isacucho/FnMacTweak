#ifndef FN_KBM_PATCH_H
#define FN_KBM_PATCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    FnKBMStatusNotAttempted = 0,
    FnKBMStatusReady,
    FnKBMStatusInstalled,
    FnKBMStatusAlreadyPatched,
    FnKBMStatusUnsupported,
    FnKBMStatusMixedState,
    FnKBMStatusProtectionDenied,
    FnKBMStatusWriteFailed,
    FnKBMStatusRollbackFailed
} FnKBMStatus;

typedef struct {
    FnKBMStatus status;
    bool active;
    bool changed;
    char detail[256];
} FnKBMResult;

typedef enum { FnKBMImageFile, FnKBMImageMapped } FnKBMImageLayout;
typedef struct {
    uint64_t vmAddress;
    size_t imageOffset;
    uint32_t original;
    uint32_t replacement;
} FnKBMPatch;
typedef struct {
    FnKBMPatch patches[6];
    size_t count;
    bool alreadyPatched;
    uint64_t preferredBase;
} FnKBMPlan;

/// Read-only structural analysis of a thin ARM64 Mach-O. No file or memory writes.
/// Mapped layout uses offsets from the image's preferred __TEXT address.
bool FnKBMBuildPlan(const void *bytes, size_t length, FnKBMImageLayout layout,
                    FnKBMPlan *out, FnKBMResult *result);

/// Call on the main thread during the tweak's early constructor, before input
/// hooks and before game code runs. Never retries a failed transaction.
FnKBMResult FnKBMInstallEarly(void);
FnKBMResult FnKBMCurrentResult(void);
const char *FnKBMStatusName(FnKBMStatus status);

#ifdef __cplusplus
}
#endif
#endif
