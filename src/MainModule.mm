#import <Foundation/Foundation.h>
#import "Updater.hpp"
#import "Logger.hpp"
#import "iOSSimulatorContext.hpp"
#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"

#ifndef MODULE_VERSION
#define MODULE_VERSION "0.1.0"
#endif

#define UPDATE_MANIFEST_URL "https://github.com/AlexGRDev/FnMacUpdateFix/releases/latest/download/manifest.json"

__attribute__((constructor)) static void initializer() {
    @autoreleasepool {
        const char *home = getenv("HOME");
        std::string container = home ? home : [NSHomeDirectory() UTF8String];

        // Documents debe existir antes de abrir el log.
        iOSSimulatorContext::getInstance().emulateiOSDirectories(container);
        fndiag::log_init(container + "/Documents/FnDiag.log");

        const fndiag::Config &cfg = fndiag::config();
        LOG_I("MainModule", "FnMacUpdateFix v%s cargada (foreground=%d isolate=%d create_dirs=%d relative=%d patch_status=%d unlock_fps=%d(%d) verbose=%d "
              "autoupdate=%d)",
              MODULE_VERSION, cfg.foreground_sessions, cfg.isolate_sessions, cfg.create_dirs, cfg.relative_paths, cfg.patch_status,
              cfg.unlock_fps, cfg.fps_target, cfg.verbose, cfg.autoupdate);

        fndiag::install_file_hooks();
        fndiag::install_network_hooks();
        fndiag::install_engine_hooks();
        fndiag::install_session_override();
        fndiag::install_fps_hooks();
        fndiag::install_input_probe();
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
