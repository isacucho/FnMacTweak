#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

#include "core/DiagLog.hpp"
#include "core/LogSpoofer.hpp"
#include "core/SimulatorContext.hpp"
#include "update/KickPatcher.hpp"
#include "update/CustomizationPatcher.hpp"
#include "metadata/DeviceSpoof.hpp"
#include "eos/EosHooks.hpp"
#include "eos/MkwBypass.hpp"

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
        fndiag::write_log_key_file(container);
        BOOT_PROBE("4_logkey_done");

        installSpoofHooks();
        BOOT_PROBE("5_spoof_done");
        // ValidationPatch: diferido al main queue para que el constructor de JadedFix
        // (tambien dylib, carga antes de que el main queue drene) patche slot1 primero.
        // Si JadedFix no esta presente, slot1 sigue con fn1_va original y lo parcheamos
        // nosotros. patch_vtable_entry detecta current!=expected y salta si ya fue
        // parchado por JadedFix.
        dispatch_async(dispatch_get_main_queue(), ^{
            fndiag::install_validation_patch();
            BOOT_PROBE("6_validation_done_async");
        });
        install_eos_hooks();
        BOOT_PROBE("7_eos_hooks_done");
        install_mkw_hooks();
        BOOT_PROBE("8_mkw_hooks_done");
        fndiag::install_kick_bypass();
        BOOT_PROBE("9_kickbypass_done");
        fndiag::install_customization_patch();
        BOOT_PROBE("10_custompatch_done");
    }
}
