#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

#include "core/DiagLog.hpp"
#include "core/LogSpoofer.hpp"
#include "core/SimulatorContext.hpp"
#include "update/KickPatcher.hpp"
#include "update/OtaUpdater.hpp"
#include "update/GameUpdater.hpp"
#include "core/Config.hpp"
#include "metadata/DeviceSpoof.hpp"
#include "eos/EosHooks.hpp"
#include "eos/MkwBypass.hpp"
#include "network/StatusCodeFix.hpp"
#include "update/UpdateHooks.hpp"
#include "update/CustomizationPatcher.hpp"

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
        // NSHomeDirectory() devuelve el container real del proceso iOS sideloaded
        // (~/Library/Containers/<UUID>/Data). getenv("HOME") puede devolver el home
        // del shell de macOS en contextos DYLD_INSERT_LIBRARIES, que es incorrecto.
        std::string container = [NSHomeDirectory() UTF8String];

        iOSSimulatorContext::getInstance().emulateiOSDirectories(container);
        BOOT_PROBE("2_sim_done");
        fndiag::log_init(container + "/Documents/FnDiag.log");
        BOOT_PROBE("3_log_init_done");
        fndiag::write_log_key_file(container);
        BOOT_PROBE("4_logkey_done");

        install_status_code_fix();
        BOOT_PROBE("5_statusfix_done");
        fndiag::install_engine_hooks();
        BOOT_PROBE("6_engine_hooks_done");
        installSpoofHooks();
        BOOT_PROBE("7_spoof_done");
        dispatch_async(dispatch_get_main_queue(), ^{
            fndiag::install_validation_patch();
            BOOT_PROBE("8_validation_done_async");
        });
        install_eos_hooks();
        BOOT_PROBE("9_eos_hooks_done");
        install_mkw_hooks();
        BOOT_PROBE("10_mkw_hooks_done");
        fndiag::install_kick_bypass();
        BOOT_PROBE("11_kickbypass_done");
        fndiag::install_customization_patch();
        BOOT_PROBE("12_custompatch_done");
        fndiag::install_game_updater();
        BOOT_PROBE("13_gameupdater_done");

        if (fndiag::config().autoupdate) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                OtaUpdater::getInstance().setConfig(UPDATE_MANIFEST_URL, MODULE_VERSION);
                OtaUpdater::getInstance().checkForUpdates();
            });
        }
    }
}
