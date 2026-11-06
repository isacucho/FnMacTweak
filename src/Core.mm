#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <cstdlib>

#include "core/Logger.hpp"
#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "core/SimulatorContext.hpp"
#include "core/DebugCanvas.hpp"
#include "core/Logger.hpp"
#include "network/EacHooks.hpp"
#include "update/TerrainPatcher.hpp"
#include "update/KickPatcher.hpp"
#include "update/NmtPatcher.hpp"
#include "update/UpdateHooks.hpp"
#include "update/Updater.hpp"
#include "input/InputHooks.hpp"

#ifndef MODULE_VERSION
#define MODULE_VERSION "1.0.0"
#endif

#ifndef UPDATE_MANIFEST_URL
#define UPDATE_MANIFEST_URL "https://github.com/AlexGRDev/FnMacKickFix/releases/latest/download/manifest.json"
#endif

__attribute__((constructor)) static void fncompat_init() {
    @autoreleasepool {
        const char *home = getenv("HOME");
        std::string container = home ? home : [NSHomeDirectory() UTF8String];

        iOSSimulatorContext::getInstance().emulateiOSDirectories(container);
        fndiag::log_init(container + "/Documents/FnDiag.log");

        LOG_E("Core", "=========================================");
        LOG_E("Core", "FnMacKickFix v" MODULE_VERSION " iniciado");
        LOG_E("Core", "Subsystem: com.alexgrdev.fnmackickfix");
        LOG_E("Core", "=========================================");

        const fndiag::Config& cfg = fndiag::config();
        LOG_I("Core", "config: foreground=%d isolate=%d create_dirs=%d relative=%d "
              "patch_status=%d unlock_fps=%d(%d) input_ini=%d native_kbm=%d "
              "verbose=%d autoupdate=%d",
              cfg.foreground_sessions, cfg.isolate_sessions, cfg.create_dirs,
              cfg.relative_paths, cfg.patch_status, cfg.unlock_fps, cfg.fps_target,
              cfg.input_ini, cfg.native_kbm, cfg.verbose, cfg.autoupdate);

        fndiag::install_terrain_patch(container);
        // KickPatcher v2: 18 vtable entries in __DATA_CONST pointing to
        // ClientWasKicked_Implementation are replaced with kick_bypass_stub via
        // vm_protect(rw) + write + vm_protect(r). The stub suppresses reason 1/3/5
        // (GenericKick/EncryptionRequired/ClientIdRestriction = ValidationFailed/EAC)
        // and calls the original only for 2/4 (WasBanned/CrossPlayRestriction).
        fndiag::install_kick_bypass();
        fndiag::install_nmt_patch();

        installSpoofHooks();

        fndiag::install_input_ini(container);
        fndiag::install_file_hooks();
        fndiag::install_network_hooks();
        fndiag::install_engine_hooks();
        fndiag::install_session_override();

        installNetHooks();

        fndiag::install_fps_hooks();
        fndiag::install_input_probe();
        fndiag::install_native_kbm();

#ifndef PRODUCTION
        DebugCanvas::getInstance().addText("FnMacKickFix v" MODULE_VERSION, 10.0f, 20.0f, 0xFF00FF00);
#endif

        if (cfg.mirror_log)
            fndiag::start_game_log_mirror(container);

        if (cfg.autoupdate) {
            Updater::getInstance().setUpdateConfig(UPDATE_MANIFEST_URL, MODULE_VERSION);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                Updater::getInstance().checkForUpdates();
            });
        }
    }
}
