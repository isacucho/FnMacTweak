#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

#include "core/DiagLog.hpp"
#include "core/SimulatorContext.hpp"
#include "core/OsLogInterceptor.hpp"
#include "update/KickPatcher.hpp"
#include "network/EacHooks.hpp"
#include "update/UpdateHooks.hpp"
#include "metadata/DeviceSpoof.hpp"

// Resto de modulos: compilados pero no llamados desde el constructor.
// Sirven como backup activo; reintroducirlos no requiere reconstruir el dylib.
// (KickBypass, NmtPatcher, CustomizationPatcher, NetFailurePatcher, etc.)

#ifndef MODULE_VERSION
#define MODULE_VERSION "1.0.0"
#endif

#define BOOT_PROBE(msg) do { \
    int _fd = open("/tmp/fnmac_boot.log", O_WRONLY|O_CREAT|O_APPEND, 0644); \
    if (_fd >= 0) { const char _m[] = msg "\n"; write(_fd, _m, sizeof(_m)-1); close(_fd); } \
} while(0)

__attribute__((constructor)) static void fncompat_init() {
    BOOT_PROBE("1_constructor_start v" MODULE_VERSION);
    @autoreleasepool {
        const char *home = getenv("HOME");
        std::string container = home ? home : [NSHomeDirectory() UTF8String];

        iOSSimulatorContext::getInstance().emulateiOSDirectories(container);
        BOOT_PROBE("2_sim_done");
        fndiag::log_init(container + "/Documents/FnDiag.log");
        BOOT_PROBE("3_log_init_done");

        // Interceptor de os_log y NSLog: captura mensajes del juego con campos
        // <private> antes del filtro del sistema. Ver OsLogInterceptor.hpp.
        fndiag::install_oslog_interceptor();
        BOOT_PROBE("4_oslog_done");

        // DeviceSpoof: fingerprint iPad14,3 / iOS 17.5 + parche isiOSAppOnMac en EOSSDK.
        // Debe instalarse antes de cualquier llamada al EOSSDK.
        installSpoofHooks();
        BOOT_PROBE("5_spoof_done");

        // Validation patch: reemplaza vtable 0xcd32e18 y 0xcd32df8 con un stub
        // que siempre pasa, evitando el kick por performance counters (reasons 10/6).
        // Solo toca __DATA_CONST; EAC no hashea esta seccion.
        fndiag::install_validation_patch();
        BOOT_PROBE("6_validation_done");

        // EAC registration hooks:
        //   - MSHookFunction en EOSSDK (ReceiveMessageFromServer, BeginSession):
        //     parchea el prologo de la funcion directamente; unico metodo que funciona
        //     porque el binario del juego no tiene stubs PLT para EOS_AntiCheatClient_*.
        //   - Supresion de mensajes tipo {5,19,23,49} con indicador=1 (causa del error
        //     "Client failed to register with server").
        //   - Spoof de respuestas verify/match y verify/event (HTTP layer).
        //   - EosHooks (GetSystemRequirementStatus -> 0) via DYLD_INTERPOSE en EosHooks.cpp.
        installNetHooks();
        fndiag::install_network_hooks();
        BOOT_PROBE("7_nethooks_done");
    }
}
