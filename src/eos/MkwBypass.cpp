/*
 * DYLD_INTERPOSE hooks para MarketplaceKitWrapper.framework.
 *
 * El juego 43.x verifica que corre desde el EU Alternative Marketplace:
 *   MKW_GetEligibilityRegion  -> comprueba que el dispositivo esta en zona EU
 *   MKW_RequestCTToken        -> solicita el Core Technology token a Apple
 *   MKW_GetCurrent            -> obtiene el tipo de distribuidor activo
 *
 * Sin respuestas validas el servidor de Epic rechaza la sesion y lanza kick.
 * Interceptamos las tres y devolvemos respuestas de exito sinteticas.
 *
 * Firmas (demangle de los simbolos Swift T capitalized):
 *   void MKW_GetEligibilityRegion(void (*callback)(bool success, const char* msg))
 *   void MKW_RequestCTToken     (void (*callback)(bool success, const char* msg))
 *   void MKW_GetCurrent         (void (*callback)(long  type,   const char* msg))
 */

#include "core/DiagLog.hpp"
#include <cstdint>

#define DYLD_INTERPOSE(_replacement, _replacee)                             \
    __attribute__((used)) static struct {                                   \
        const void* replacement;                                            \
        const void* replacee;                                               \
    } _interpose_##_replacee                                                \
    __attribute__((section("__DATA,__interpose"))) = {                      \
        (const void*)(unsigned long)&(_replacement),                        \
        (const void*)(unsigned long)&(_replacee)                            \
    } /* DYLD_INTERPOSE */

typedef void (*MKWCallbackBool)(bool success, const char* msg);
typedef void (*MKWCallbackLong)(long  type,   const char* msg);

/*
 * MarketplaceKitWrapper exporta tanto los simbolos Swift-mangled como simbolos
 * C planos (_MKW_GetCurrent, etc.). El binario de Fortnite llama a los C planos.
 * DYLD_INTERPOSE debe apuntar a esos, no a los mangled Swift.
 */
extern "C" void MKW_GetEligibilityRegion(MKWCallbackBool cb);
extern "C" void MKW_RequestCTToken(MKWCallbackBool cb);
extern "C" void MKW_GetCurrent(MKWCallbackLong cb);

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

DYLD_INTERPOSE(my_MKW_GetEligibilityRegion, MKW_GetEligibilityRegion);
DYLD_INTERPOSE(my_MKW_RequestCTToken,      MKW_RequestCTToken);
DYLD_INTERPOSE(my_MKW_GetCurrent,          MKW_GetCurrent);
