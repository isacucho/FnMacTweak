/*
 * MSHookFunction hooks para MarketplaceKitWrapper.framework.
 *
 * DYLD_INTERPOSE no funciona porque MarketplaceKitWrapper carga antes que
 * esta dylib (posicion 966 vs 1300 en LC_LOAD_DYLIB). MSHookFunction
 * parchea el prologo en runtime, independientemente del orden de carga.
 *
 * El juego 43.x verifica que corre desde el EU Alternative Marketplace:
 *   MKW_GetEligibilityRegion  -> comprueba que el dispositivo esta en zona EU
 *   MKW_RequestCTToken        -> solicita el Core Technology token a Apple
 *   MKW_GetCurrent            -> obtiene el tipo de distribuidor activo
 *
 * Interceptamos las tres y devolvemos respuestas de exito sinteticas.
 */

#include "core/DiagLog.hpp"
#include <dlfcn.h>

extern "C" void MSHookFunction(void* symbol, void* replace, void** result);

typedef void (*MKWCallbackBool)(bool success, const char* msg);
typedef void (*MKWCallbackLong)(long  type,   const char* msg);

static void my_MKW_GetEligibilityRegion(MKWCallbackBool cb) {
    fndiag::log_line("[MkwBypass] GetEligibilityRegion -> EU eligible");
    if (cb) cb(true, "EU");
}

static void my_MKW_RequestCTToken(MKWCallbackBool cb) {
    fndiag::log_line("[MkwBypass] RequestCTToken -> mock token");
    if (cb) cb(true, "mock_ct_token_fnmac_bypass");
}

/* AppDistributorType: 0=appStore 1=testFlight 2=web 3=marketplace 4=other */
static void my_MKW_GetCurrent(MKWCallbackLong cb) {
    fndiag::log_line("[MkwBypass] GetCurrent -> marketplace(3)");
    if (cb) cb(3, "marketplace");
}

void install_mkw_hooks() {
    void* mkw = dlopen("@rpath/MarketplaceKitWrapper.framework/MarketplaceKitWrapper", RTLD_LAZY | RTLD_NOLOAD);
    if (!mkw) {
        fndiag::log_line("[MkwBypass] dlopen MKW(NOLOAD) failed: %s", dlerror());
        return;
    }

    struct { const char* sym; void* replace; } hooks[] = {
        { "MKW_GetEligibilityRegion", (void*)my_MKW_GetEligibilityRegion },
        { "MKW_RequestCTToken",       (void*)my_MKW_RequestCTToken       },
        { "MKW_GetCurrent",           (void*)my_MKW_GetCurrent           },
    };

    for (auto& h : hooks) {
        void* fn = dlsym(mkw, h.sym);
        if (!fn) { fndiag::log_line("[MkwBypass] dlsym %s FAILED", h.sym); continue; }
        MSHookFunction(fn, h.replace, nullptr);
        fndiag::log_line("[MkwBypass] hooked %s @ %p", h.sym, fn);
    }

    dlclose(mkw);
}
