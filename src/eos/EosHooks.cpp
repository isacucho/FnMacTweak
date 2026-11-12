/*
 * MSHookFunction hooks for EOSSDK.framework exported C symbols.
 *
 * DYLD_INTERPOSE no funciona porque EOSSDK carga antes que esta dylib
 * en el orden de LC_LOAD_DYLIB (posicion 959 vs 1300). MSHookFunction
 * parchea el prologo de la funcion en runtime, independientemente del
 * orden de carga.
 *
 * Goals:
 *  - Log BeginSession params and result to diagnose EAC session failures.
 *  - Force GetSystemRequirementStatus to EOS_Success / all-OK so macOS is
 *    not rejected as an unsupported platform (iOS binary running via JIT).
 *  - Suppress PollStatus violations to prevent EAC kick on macOS.
 */

#include "core/DiagLog.hpp"
#include <dlfcn.h>
#include <cstdint>
#include <cstring>

extern "C" void MSHookFunction(void* symbol, void* replace, void** result);

typedef void*   EOS_HAntiCheatClient;
typedef void*   EOS_HSessions;
typedef int32_t EOS_EResult;
static const EOS_EResult EOS_Success = 0;

typedef struct { int32_t ApiVersion; void* LocalUserId; int32_t Mode; } EOS_AntiCheatClient_BeginSessionOptions;
typedef struct { int32_t ApiVersion; } EOS_AntiCheatClient_GetSystemRequirementStatusOptions;
typedef struct { int32_t ApiVersion; int32_t MaxMessageCount; } EOS_AntiCheatClient_PollStatusOptions;
typedef struct { int32_t ApiVersion; const char* SessionName; } EOS_Sessions_EndSessionOptions;
typedef void (*EOS_Sessions_OnEndSessionCallback)(const void*);
typedef struct { int32_t ApiVersion; const char* SessionName; } EOS_Sessions_DestroySessionOptions;
typedef void (*EOS_Sessions_OnDestroySessionCallback)(const void*);

typedef EOS_EResult (*fn_BeginSession)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_BeginSessionOptions*);
typedef EOS_EResult (*fn_GetSysReq)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_GetSystemRequirementStatusOptions*, int32_t*, int32_t*);
typedef EOS_EResult (*fn_PollStatus)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_PollStatusOptions*, int32_t*, void**);
typedef EOS_EResult (*fn_EndSession)(EOS_HSessions, const EOS_Sessions_EndSessionOptions*, void*, EOS_Sessions_OnEndSessionCallback);
typedef EOS_EResult (*fn_DestroySession)(EOS_HSessions, const EOS_Sessions_DestroySessionOptions*, void*, EOS_Sessions_OnDestroySessionCallback);

static fn_BeginSession  orig_BeginSession  = nullptr;
static fn_GetSysReq     orig_GetSysReq     = nullptr;
static fn_PollStatus    orig_PollStatus    = nullptr;
static fn_EndSession    orig_EndSession    = nullptr;
static fn_DestroySession orig_DestroySession = nullptr;

static EOS_EResult my_BeginSession(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_BeginSessionOptions* Options)
{
    if (Options)
        fndiag::log_line("[EOS] BeginSession ApiVer=%d Mode=%d UserId=%p",
            Options->ApiVersion, Options->Mode, Options->LocalUserId);
    else
        fndiag::log_line("[EOS] BeginSession opts=null");

    EOS_EResult r = orig_BeginSession ? orig_BeginSession(Handle, Options) : EOS_Success;
    fndiag::log_line("[EOS] BeginSession -> result=%d (0=success)", (int)r);
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
    EOS_EResult r = orig_GetSysReq
        ? orig_GetSysReq(Handle, Options, OutSystemRequirementStatus, OutPlatformRequirementStatus)
        : EOS_Success;

    int32_t sys  = OutSystemRequirementStatus  ? *OutSystemRequirementStatus  : -1;
    int32_t plat = OutPlatformRequirementStatus ? *OutPlatformRequirementStatus : -1;
    fndiag::log_line("[EOS] GetSysReqStatus result=%d sys=%d plat=%d", (int)r, sys, plat);

    if (r != EOS_Success || sys != 0 || plat != 0) {
        fndiag::log_line("[EOS] GetSysReqStatus: overriding to EOS_Success/0/0");
        if (OutSystemRequirementStatus)   *OutSystemRequirementStatus  = 0;
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
    EOS_EResult r = orig_PollStatus
        ? orig_PollStatus(Handle, Options, OutViolationType, OutActionInfo)
        : EOS_Success;
    int32_t vtype = OutViolationType ? *OutViolationType : -1;
    if (r != EOS_Success || vtype != 0)
        fndiag::log_line("[EOS] PollStatus result=%d violation=%d -- suprimiendo", (int)r, vtype);
    if (OutViolationType) *OutViolationType = 0;
    if (OutActionInfo)    *OutActionInfo    = nullptr;
    return EOS_Success;
}

static EOS_EResult my_EndSession(
    EOS_HSessions Handle,
    const EOS_Sessions_EndSessionOptions* Options,
    void* ClientData,
    EOS_Sessions_OnEndSessionCallback CompletionDelegate)
{
    const char* name = (Options && Options->SessionName) ? Options->SessionName : "(null)";
    fndiag::log_line("[EOS] EndSession '%s' called", name);
    EOS_EResult r = orig_EndSession
        ? orig_EndSession(Handle, Options, ClientData, CompletionDelegate)
        : EOS_Success;
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
    EOS_EResult r = orig_DestroySession
        ? orig_DestroySession(Handle, Options, ClientData, CompletionDelegate)
        : EOS_Success;
    fndiag::log_line("[EOS] DestroySession '%s' returned result=%d", name, (int)r);
    return r;
}

void install_eos_hooks() {
    void* eossdk = dlopen("@rpath/EOSSDK.framework/EOSSDK", RTLD_LAZY | RTLD_NOLOAD);
    if (!eossdk) {
        fndiag::log_line("[EOS] dlopen EOSSDK(NOLOAD) failed: %s -- fallback RTLD_DEFAULT", dlerror());
        eossdk = RTLD_DEFAULT;
    }

    struct { const char* sym; void* replace; void** orig; } hooks[] = {
        { "EOS_AntiCheatClient_BeginSession",             (void*)my_BeginSession,              (void**)&orig_BeginSession  },
        { "EOS_AntiCheatClient_GetSystemRequirementStatus",(void*)my_GetSystemRequirementStatus,(void**)&orig_GetSysReq     },
        { "EOS_AntiCheatClient_PollStatus",               (void*)my_PollStatus,                (void**)&orig_PollStatus    },
        { "EOS_Sessions_EndSession",                      (void*)my_EndSession,                (void**)&orig_EndSession    },
        { "EOS_Sessions_DestroySession",                  (void*)my_DestroySession,            (void**)&orig_DestroySession},
    };

    for (auto& h : hooks) {
        void* fn = dlsym(eossdk, h.sym);
        if (!fn) { fndiag::log_line("[EOS] dlsym %s FAILED", h.sym); continue; }
        MSHookFunction(fn, h.replace, h.orig);
        fndiag::log_line("[EOS] hooked %s @ %p", h.sym, fn);
    }

    if (eossdk != RTLD_DEFAULT) dlclose(eossdk);
}
