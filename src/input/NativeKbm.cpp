#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "input/InputHooks.hpp"
#include "input/KbmScan.hpp"

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <cstdint>
#include <vector>

namespace fndiag {

void install_native_kbm() {
    if (!config().native_kbm) return;
    const struct mach_header_64* mh = (const struct mach_header_64*)_dyld_get_image_header(0);
    if (!mh) { log_line("[KBM] sin imagen principal"); return; }

    unsigned long text_size = 0, ustr_size = 0;
    uint8_t* text = getsectiondata(mh, "__TEXT", "__text",    &text_size);
    uint8_t* ustr = getsectiondata(mh, "__TEXT", "__ustring", &ustr_size);
    if (!text || !ustr) { log_line("[KBM] faltan __text o __ustring"); return; }

    auto lits = kbm::find_wide_literal(ustr, ustr_size, (uint64_t)ustr, kbm::kMouseSettingsReason);
    std::vector<size_t> sites;
    for (uint64_t lva : lits) {
        auto s = kbm::find_bl_before_literal((const uint32_t*)text, text_size / 4, (uint64_t)text, lva);
        sites.insert(sites.end(), s.begin(), s.end());
    }
    if (sites.size() != 1) {
        log_line("[KBM] patron no encontrado (literales=%zu sitios=%zu): build no compatible", lits.size(), sites.size());
        return;
    }
    const uint32_t* site = (const uint32_t*)text + sites[0];
    log_line("[KBM] sitio rva 0x%llx palabra 0x%08x: %s",
             (unsigned long long)((const uint8_t*)site - (const uint8_t*)mh), *site,
             *site == kbm::kMovW0One ? "binario ya parcheado" :
             "SIN parchear (parchear el Mach-O con tools/kbm_check --patch antes de firmar)");
}

} // namespace fndiag
