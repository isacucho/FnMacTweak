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

typedef void*   EOS_HPlatform;
typedef void* (*fn_GetACClientIface)(EOS_HPlatform);
typedef EOS_EResult (*fn_BeginSession)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_BeginSessionOptions*);
typedef EOS_EResult (*fn_GetSysReq)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_GetSystemRequirementStatusOptions*, int32_t*, int32_t*);
typedef EOS_EResult (*fn_PollStatus)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_PollStatusOptions*, int32_t*, void**);
typedef EOS_EResult (*fn_EndSession)(EOS_HSessions, const EOS_Sessions_EndSessionOptions*, void*, EOS_Sessions_OnEndSessionCallback);
typedef EOS_EResult (*fn_DestroySession)(EOS_HSessions, const EOS_Sessions_DestroySessionOptions*, void*, EOS_Sessions_OnDestroySessionCallback);
typedef struct { int32_t ApiVersion; const void* Data; uint32_t DataLengthBytes; } EOS_AntiCheatClient_ReceiveMessageFromServerOptions;
typedef EOS_EResult (*fn_RecvMsg)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_ReceiveMessageFromServerOptions*);

typedef void (*EOS_AntiCheatClient_OnMessageToServerCallback)(const void*, const void*, uint32_t);
typedef struct { int32_t ApiVersion; EOS_AntiCheatClient_OnMessageToServerCallback NotificationFn; void* ClientData; } EOS_AntiCheatClient_AddNotifyMessageToServerOptions;
typedef EOS_EResult (*fn_AddNotifyMsgToServer)(EOS_HAntiCheatClient, const EOS_AntiCheatClient_AddNotifyMessageToServerOptions*);

static fn_GetACClientIface orig_GetACClientIface = nullptr;
static fn_AddNotifyMsgToServer orig_AddNotifyMsgToServer = nullptr;
static fn_BeginSession  orig_BeginSession  = nullptr;
static fn_GetSysReq     orig_GetSysReq     = nullptr;
static fn_PollStatus    orig_PollStatus    = nullptr;
static fn_EndSession    orig_EndSession    = nullptr;
static fn_DestroySession orig_DestroySession = nullptr;
static fn_RecvMsg       orig_RecvMsg       = nullptr;

static void* my_GetACClientIface(EOS_HPlatform Handle)
{
    void* r = orig_GetACClientIface ? orig_GetACClientIface(Handle) : nullptr;
    fndiag::log_line("[EOS] Platform_GetAntiCheatClientInterface platform=%p -> client=%p", Handle, r);
    return r;
}

// EAC message type bytes (first byte of payload).
// 0x01xx = platform/system integrity report - triggers server-side ghost mode on macOS.
// We register a no-op callback so the game proceeds without blocking, but we never
// forward these messages to the server (the server never learns the platform is macOS).
static EOS_AntiCheatClient_OnMessageToServerCallback g_original_eac_cb = nullptr;
static void* g_original_eac_cd = nullptr;

static void eac_msg_to_server_interceptor(const void* /*ctx*/, const void* data, uint32_t len) {
    uint8_t msg_type = (len >= 1) ? ((const uint8_t*)data)[0] : 0xFF;
    // Log all outgoing EAC messages; suppress platform integrity reports (0x01)
    // which cause the server to ghost-mode the client on non-iOS platforms.
    if (msg_type == 0x01) {
        fndiag::log_line("[EOS] AddNotify->server type=0x%02x len=%u SUPPRESSED (platform report)",
                         msg_type, len);
        return; // do not forward to original callback
    }
    fndiag::log_line("[EOS] AddNotify->server type=0x%02x len=%u", msg_type, len);
    if (g_original_eac_cb)
        g_original_eac_cb(g_original_eac_cd, data, len);
}

static EOS_EResult my_AddNotifyMsgToServer(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_AddNotifyMessageToServerOptions* Options)
{
    if (!Options) {
        fndiag::log_line("[EOS] AddNotifyMessageToServer opts=null");
        return orig_AddNotifyMsgToServer ? orig_AddNotifyMsgToServer(Handle, Options) : EOS_Success;
    }
    // Save original callback and substitute our interceptor
    g_original_eac_cb = Options->NotificationFn;
    g_original_eac_cd = Options->ClientData;

    EOS_AntiCheatClient_AddNotifyMessageToServerOptions patched = *Options;
    patched.NotificationFn = eac_msg_to_server_interceptor;
    patched.ClientData     = nullptr;

    fndiag::log_line("[EOS] AddNotifyMessageToServer ApiVer=%d (interceptor installed)",
        Options->ApiVersion);
    return orig_AddNotifyMsgToServer ? orig_AddNotifyMsgToServer(Handle, &patched) : EOS_Success;
}

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
    fndiag::log_line("[EOS] BeginSession returned %d", (int)r);
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

static EOS_EResult my_RecvMsgFromServer(
    EOS_HAntiCheatClient Handle,
    const EOS_AntiCheatClient_ReceiveMessageFromServerOptions* Options)
{
    if (Options)
        fndiag::log_line("[EOS] ReceiveMessageFromServer len=%u first4=%02x%02x%02x%02x",
            Options->DataLengthBytes,
            Options->DataLengthBytes >= 1 ? ((const uint8_t*)Options->Data)[0] : 0,
            Options->DataLengthBytes >= 2 ? ((const uint8_t*)Options->Data)[1] : 0,
            Options->DataLengthBytes >= 3 ? ((const uint8_t*)Options->Data)[2] : 0,
            Options->DataLengthBytes >= 4 ? ((const uint8_t*)Options->Data)[3] : 0);
    return orig_RecvMsg ? orig_RecvMsg(Handle, Options) : EOS_Success;
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
        { "EOS_Platform_GetAntiCheatClientInterface",     (void*)my_GetACClientIface,          (void**)&orig_GetACClientIface          },
        { "EOS_AntiCheatClient_AddNotifyMessageToServer", (void*)my_AddNotifyMsgToServer,      (void**)&orig_AddNotifyMsgToServer      },
        { "EOS_AntiCheatClient_BeginSession",             (void*)my_BeginSession,              (void**)&orig_BeginSession  },
        { "EOS_AntiCheatClient_GetSystemRequirementStatus",(void*)my_GetSystemRequirementStatus,(void**)&orig_GetSysReq     },
        { "EOS_AntiCheatClient_PollStatus",               (void*)my_PollStatus,                (void**)&orig_PollStatus    },
        { "EOS_AntiCheatClient_ReceiveMessageFromServer", (void*)my_RecvMsgFromServer,         (void**)&orig_RecvMsg       },
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
