#import "update/GameUpdater.hpp"
#import "core/DiagLog.hpp"
#import <Foundation/Foundation.h>
#include <cstdlib>

namespace fndiag {
namespace {

const char* buildLabel(uint32_t bid) {
    switch (bid) {
        case 59596594u: return "43.00";
        case 60278837u: return "43.10";
        default:        return nullptr;
    }
}

} // namespace

void install_game_updater() {
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* ver = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (!ver) {
        log_line("[GameUpdater] CFBundleVersion no encontrada en el bundle principal");
        return;
    }
    uint32_t bid = (uint32_t)[ver integerValue];
    const char* label = buildLabel(bid);
    if (label) {
        log_line("[GameUpdater] build %u (%s) — soportado", bid, label);
    } else {
        log_line("[GameUpdater] build %u — DESCONOCIDO (dylib puede no funcionar correctamente)", bid);
    }
}

} // namespace fndiag
