#import <Foundation/Foundation.h>
#include "core/DiagLog.hpp"
#include "eos/CompatReport.hpp"
#include "eos/EosHooks.hpp"
#include "metadata/DeviceSpoof.hpp"
#include "update/UpdateHooks.hpp"
#include "update/ContentPatch.hpp"
#include "update/KickPatcher.hpp"
#include "update/NmtPatcher.hpp"
#include "update/CustomizationPatcher.hpp"
#include "network/StatusCodeFix.hpp"
#include "core/OsLogInterceptor.hpp"
#include "gpu/MetalPurge.hpp"

__attribute__((constructor)) static void fncompat_init() {
    @autoreleasepool {
        NSString* home = NSHomeDirectory();
        if (!home) return;
        std::string container = [home UTF8String];
        fndiag::log_init(container + "/Documents/FnDiag.log");
        fndiag::install_oslog_interceptor();
        installSpoofHooks();
        install_eos_hooks();
        fndiag::install_engine_hooks();
        fndiag::install_content_patch();
        fndiag::install_kick_bypass();
        fndiag::install_nmt_patch();
        fndiag::install_customization_patch();
        install_status_code_fix();
        fndiag::install_compat_report();
        fndiag::install_metal_purge();
    }
}
