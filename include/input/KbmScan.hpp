#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

// Localiza en el __TEXT arm64 de FortniteClient-IOS-Shipping la instruccion
// `bl <predicado>` de FortSettingEditCondition_WhenPlatformSupportsMouseAndKeyboard.
// Se firma por el literal UTF-16 "Platform does not support mouse settings" que aparece
// justo despues, sin usar offsets fijos: valido para cualquier build que conserve el patron.
// Cabecera pura (sin dependencias de Mach-O): usable desde la dylib y desde tools/kbm_check.

namespace fndiag {
namespace kbm {

constexpr uint32_t kMovW0One = 0x52800020; // mov w0, #1

inline bool is_bl(uint32_t i)             { return (i & 0xfc000000) == 0x94000000; }
inline bool is_tbnz_w0_bit0(uint32_t i)  { return (i & 0x7ff8001f) == 0x37000000; }
inline bool is_adrp(uint32_t i)          { return (i & 0x9f000000) == 0x90000000; }
inline bool is_add_imm64(uint32_t i)     { return (i & 0xffc00000) == 0x91000000; }

// Direcciones VA del literal UTF-16 `lit` dentro de `ustr`.
inline std::vector<uint64_t> find_wide_literal(const uint8_t* ustr, size_t sz,
                                                uint64_t va, const char* lit) {
    std::vector<uint64_t> out;
    std::vector<uint8_t> pat;
    for (const char* c = lit; *c; c++) { pat.push_back((uint8_t)*c); pat.push_back(0); }
    pat.push_back(0); pat.push_back(0);
    if (sz < pat.size()) return out;
    for (size_t o = 0; o + pat.size() <= sz; o += 2) {
        if (memcmp(ustr + o, pat.data(), pat.size()) != 0) continue;
        if (o >= 2 && (ustr[o-2] != 0 || ustr[o-1] != 0)) continue;
        out.push_back(va + o);
    }
    return out;
}

// Indices (en palabras) de cada `bl` seguido de tbnz+adrp+add al literal `lit_va`.
inline std::vector<size_t> find_bl_before_literal(const uint32_t* text, size_t nwords,
                                                   uint64_t text_va, uint64_t lit_va) {
    std::vector<size_t> out;
    for (size_t i = 2; i + 1 < nwords; i++) {
        uint32_t adrp = text[i];
        if (!is_adrp(adrp)) continue;
        uint32_t add = text[i + 1];
        int rd = adrp & 31;
        if (!is_add_imm64(add) || (int)((add >> 5) & 31) != rd || (int)(add & 31) != rd) continue;
        int64_t imm = (int64_t)((((adrp >> 5) & 0x7ffff) << 2) | ((adrp >> 29) & 3));
        if (imm & 0x100000) imm -= 0x200000;
        uint64_t pc     = text_va + i * 4;
        uint64_t target = (pc & ~0xfffULL) + (uint64_t)(imm << 12) + ((add >> 10) & 0xfff);
        if (target != lit_va) continue;
        if (is_tbnz_w0_bit0(text[i-1]) && is_bl(text[i-2]))
            out.push_back(i - 2);
    }
    return out;
}

constexpr const char* kMouseSettingsReason = "Platform does not support mouse settings";

} // namespace kbm
} // namespace fndiag
