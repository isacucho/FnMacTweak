#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

#include "core/DiagLog.hpp"
#include "core/SimulatorContext.hpp"
#include "update/KickPatcher.hpp"
#include "network/EacHooks.hpp"
#include "update/UpdateHooks.hpp"

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
        BOOT_PROBE("2_simulator_ctx_done");
        fndiag::log_init(container + "/Documents/FnDiag.log");
        BOOT_PROBE("3_log_init_done");

        fndiag::install_validation_patch();
        BOOT_PROBE("4_validation_patch_done");

        // EAC registration fix: account_id injection en verify/event + observador NSURLSession.
        // EosHooks (GetSystemRequirementStatus -> 0) corre automaticamente via DYLD_INTERPOSE.
        installNetHooks();
        fndiag::install_network_hooks();
        BOOT_PROBE("5_network_hooks_done");
    }
}
