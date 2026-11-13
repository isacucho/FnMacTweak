#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

#include "core/DiagLog.hpp"
#include "core/LogSpoofer.hpp"
#include "core/SimulatorContext.hpp"
#include "update/KickPatcher.hpp"
#include "update/NetFailurePatcher.hpp"
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

        // ValidationPatch: suprime la deteccion sideload/JIT en vtable 0xcd32e18 y
        // 0xcd32df8. El stub devuelve 0 antes de que se active el dispatch de kick.
        installSpoofHooks();
        BOOT_PROBE("5_spoof_done");
        fndiag::install_validation_patch();
        BOOT_PROBE("6_validation_done");
        install_eos_hooks();
        BOOT_PROBE("7_eos_hooks_done");
        install_mkw_hooks();
        BOOT_PROBE("8_mkw_hooks_done");
        fndiag::install_net_failure_patch();
        BOOT_PROBE("9_netfail_done");
        fndiag::install_kick_bypass();
        BOOT_PROBE("10_kickbypass_done");
    }
}
