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
 * Simbolos Swift originales exportados por MarketplaceKitWrapper.framework.
 * Los nombres Swift contienen '$' que no es valido en C++, asi que usamos
 * __asm__ para mapear identificadores C a los simbolos reales del linker.
 */
extern "C" void mkw_orig_eligibility(MKWCallbackBool cb)
    __asm__("_$s21MarketplaceKitWrapper24MKW_GetEligibilityRegionyyySb_SPys4Int8VGSgtXCF");
extern "C" void mkw_orig_cttoken(MKWCallbackBool cb)
    __asm__("_$s21MarketplaceKitWrapper18MKW_RequestCTTokenyyySb_SPys4Int8VGSgtXCF");
extern "C" void mkw_orig_getcurrent(MKWCallbackLong cb)
    __asm__("_$s21MarketplaceKitWrapper14MKW_GetCurrentyyySi_SPys4Int8VGSgtXCF");

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

DYLD_INTERPOSE(my_MKW_GetEligibilityRegion, mkw_orig_eligibility);
DYLD_INTERPOSE(my_MKW_RequestCTToken,      mkw_orig_cttoken);
DYLD_INTERPOSE(my_MKW_GetCurrent,          mkw_orig_getcurrent);
