/*
 * DYLD_INTERPOSE hooks for EOSSDK.framework exported C symbols.
 *
 * Loaded before the main binary via DYLD_INSERT_LIBRARIES, so dyld routes
 * every call to these wrappers before dispatching to the real vtable thunks.
 *
 * Goals:
 *  - Log BeginSession params and result to diagnose EAC session failures.
 *  - Force GetSystemRequirementStatus to EOS_Success / all-OK so macOS is
 *    not rejected as an unsupported platform (iOS binary running via JIT).
 *  - Log PollStatus violations so we know what EAC is complaining about.
 */

#include "core/DiagLog.hpp"
#include <cstdint>
#include <cstring>

#define DYLD_INTERPOSE(_replacement, _replacee)                             \
    __attribute__((used)) static struct {                                   \
        const void* replacement;                                            \
        const void* replacee;                                               \
    } _interpose_##_replacee                                                \
    __attribute__((section("__DATA,__interpose"))) = {                      \
        (const void*)(unsigned long)&(_replacement),                        \
        (const void*)(unsigned long)&(_replacee)                            \
    } /* DYLD_INTERPOSE */

/* Opaque handle types */
typedef void*   EOS_HAntiCheatClient;
typedef void*   EOS_HSessions;
typedef int32_t EOS_EResult;
static const EOS_EResult EOS_Success = 0;

/* BeginSession options (ApiVersion 1) */
typedef struct {
    int32_t ApiVersion;   /* = 1 */
    void*   LocalUserId;  /* EOS_ProductUserId */
    int32_t Mode;         /* 1=ClientServer, 2=PeerToPeer */
} EOS_AntiCheatClient_BeginSessionOptions;

/* GetSystemRequirementStatus options (ApiVersion 1) */
typedef struct {
    int32_t ApiVersion;
} EOS_AntiCheatClient_GetSystemRequirementStatusOptions;

/* PollStatus options (ApiVersion 1) */
typedef struct {
    int32_t ApiVersion;
    int32_t MaxMessageCount;
} EOS_AntiCheatClient_PollStatusOptions;

/* EOS_Sessions_EndSession options (ApiVersion 1) */
typedef struct {
    int32_t     ApiVersion;
    const char* SessionName;
} EOS_Sessions_EndSessionOptions;
typedef void (*EOS_Sessions_OnEndSessionCallback)(const void* Data);

/* EOS_Sessions_DestroySession options (ApiVersion 1) */
typedef struct {
    int32_t     ApiVersion;
    const char* SessionName;
} EOS_Sessions_DestroySessionOptions;
typedef void (*EOS_Sessions_OnDestroySessionCallback)(const void* Data);

/* Declared extern "C" so the linker resolves them from EOSSDK.framework at
   runtime; -Wl,-undefined,dynamic_lookup keeps the build happy. */
extern "C" {
EOS_EResult EOS_AntiCheatClient_BeginSession(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_BeginSessionOptions* Options);

EOS_EResult EOS_AntiCheatClient_GetSystemRequirementStatus(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_GetSystemRequirementStatusOptions* Options,
    int32_t* OutSystemRequirementStatus,
    int32_t* OutPlatformRequirementStatus);

EOS_EResult EOS_AntiCheatClient_PollStatus(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_PollStatusOptions* Options,
    int32_t* OutViolationType,
    void**   OutActionInfo);

EOS_EResult EOS_Sessions_EndSession(
    EOS_HSessions Handle,
    const EOS_Sessions_EndSessionOptions* Options,
    void* ClientData,
    EOS_Sessions_OnEndSessionCallback CompletionDelegate);

EOS_EResult EOS_Sessions_DestroySession(
    EOS_HSessions Handle,
    const EOS_Sessions_DestroySessionOptions* Options,
    void* ClientData,
    EOS_Sessions_OnDestroySessionCallback CompletionDelegate);
}

static EOS_EResult my_BeginSession(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_BeginSessionOptions* Options)
{
    if (Options) {
        fndiag::log_line("[EOS] BeginSession ApiVer=%d Mode=%d UserId=%p",
            Options->ApiVersion, Options->Mode, Options->LocalUserId);
    } else {
        fndiag::log_line("[EOS] BeginSession opts=null");
    }
    EOS_EResult r = EOS_AntiCheatClient_BeginSession(Handle, Options);
    fndiag::log_line("[EOS] BeginSession -> result=%d (0=success)", (int)r);
    /* En macOS ejecutando un binario iOS el EAC server rechaza el cliente.
       Forzar EOS_Success para que el juego no muestre "Client failed to
       register with server" (errors.com.epicgames.common.processing). */
    if (r != EOS_Success) {
        fndiag::log_line("[EOS] BeginSession: overriding result to EOS_Success");
        return EOS_Success;
    }
    return r;
}

static EOS_EResult my_GetSystemRequirementStatus(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_GetSystemRequirementStatusOptions* Options,
    int32_t* OutSystemRequirementStatus,
    int32_t* OutPlatformRequirementStatus)
{
    EOS_EResult r = EOS_AntiCheatClient_GetSystemRequirementStatus(
        Handle, Options, OutSystemRequirementStatus, OutPlatformRequirementStatus);

    int32_t sys  = OutSystemRequirementStatus  ? *OutSystemRequirementStatus  : -1;
    int32_t plat = OutPlatformRequirementStatus ? *OutPlatformRequirementStatus : -1;

    fndiag::log_line("[EOS] GetSysReqStatus result=%d sys=%d plat=%d",
        (int)r, sys, plat);

    /* Force success: on macOS running an iOS binary the platform check fails.
       Overriding both output statuses to 0 (OK) lets EAC proceed normally. */
    if (r != EOS_Success || sys != 0 || plat != 0) {
        fndiag::log_line("[EOS] GetSysReqStatus: overriding to EOS_Success/0/0");
        if (OutSystemRequirementStatus)  *OutSystemRequirementStatus  = 0;
        if (OutPlatformRequirementStatus) *OutPlatformRequirementStatus = 0;
        return EOS_Success;
    }
    return r;
}

static EOS_EResult my_PollStatus(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_PollStatusOptions* Options,
    int32_t* OutViolationType,
    void**   OutActionInfo)
{
    EOS_EResult r = EOS_AntiCheatClient_PollStatus(
        Handle, Options, OutViolationType, OutActionInfo);
    int32_t vtype = OutViolationType ? *OutViolationType : -1;
    if (r != EOS_Success || vtype != 0) {
        fndiag::log_line("[EOS] PollStatus result=%d violation=%d -- suprimiendo", (int)r, vtype);
    }
    /* Suprimir cualquier violation para evitar kick por EAC en macOS. */
    if (OutViolationType) *OutViolationType = 0;
    if (OutActionInfo)    *OutActionInfo    = nullptr;
    return EOS_Success;
}

/* Diagnostic hooks for EOS session teardown.
 * Goal: determine order relative to ClientWasKicked in FnDiag.log:
 *   [EOS] EndSession 'X' called  <-- fires before or after [KickBypass] ClientWasKicked?
 *   [EOS] DestroySession 'X' called
 * If EndSession fires BEFORE ClientWasKicked, V2.6.6 will call g_orig_rejoin here
 * while the EOS session object (slot2+0xd68) is still alive and state < 5.
 */

static EOS_EResult my_EndSession(
    EOS_HSessions Handle,
    const EOS_Sessions_EndSessionOptions* Options,
    void* ClientData,
    EOS_Sessions_OnEndSessionCallback CompletionDelegate)
{
    const char* name = (Options && Options->SessionName) ? Options->SessionName : "(null)";
    fndiag::log_line("[EOS] EndSession '%s' called", name);
    EOS_EResult r = EOS_Sessions_EndSession(Handle, Options, ClientData, CompletionDelegate);
    fndiag::log_line("[EOS] EndSession '%s' returned result=%d", name, (int)r);
    return r;
}

static EOS_EResult my_DestroySession(
    EOS_HSessions Handle,
    const EOS_Sessions_DestroySessionOptions* Options,
    void* ClientData,
    EOS_Sessions_OnDestroySessionCallback CompletionDelegate)
{
    const char* name = (Options && Options->SessionName) ? Options->SessionName : "(null)";
    fndiag::log_line("[EOS] DestroySession '%s' called", name);
    EOS_EResult r = EOS_Sessions_DestroySession(Handle, Options, ClientData, CompletionDelegate);
    fndiag::log_line("[EOS] DestroySession '%s' returned result=%d", name, (int)r);
    return r;
}

DYLD_INTERPOSE(my_BeginSession,                  EOS_AntiCheatClient_BeginSession);
DYLD_INTERPOSE(my_GetSystemRequirementStatus,    EOS_AntiCheatClient_GetSystemRequirementStatus);
DYLD_INTERPOSE(my_PollStatus,                    EOS_AntiCheatClient_PollStatus);
DYLD_INTERPOSE(my_EndSession,                    EOS_Sessions_EndSession);
DYLD_INTERPOSE(my_DestroySession,                EOS_Sessions_DestroySession);
