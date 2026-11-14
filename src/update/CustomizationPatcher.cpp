#include "update/CustomizationPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstdint>
#include <cstring>

namespace fndiag {
namespace {

// Replacement for execHandleCustomizationFailed. Returns immediately so
// NumLoadCustomizationFailed is never incremented and the server never sends
// reason=144 kicks. ARM64 ABI: ignores all arguments, void return.
static void __attribute__((noinline, used)) customization_failed_stub() {}

// Find a C string needle in any __TEXT section; return its runtime VA or 0.
static uintptr_t find_cstring_va(const mach_header_64* mh, uintptr_t slide,
                                  const char* needle) {
    size_t nlen = strlen(needle);
    const uint8_t* p = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                const section_64* sec = reinterpret_cast<const section_64*>(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j, ++sec) {
                    uintptr_t start = sec->addr + slide;
                    uintptr_t end   = start + sec->size;
                    for (uintptr_t a = start; a + nlen < end; ++a) {
                        if (memcmp(reinterpret_cast<const void*>(a), needle, nlen) == 0 &&
                            *reinterpret_cast<const char*>(a + nlen) == '\0')
                            return a;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    return 0;
}

// Scan all __TEXT executable sections for ADRP+ADD pair loading str_va,
// then walk back to the nearest function entry (any STP pre-index or SUB SP).
// Returns 0 on failure.
static uintptr_t find_fn_via_string(const mach_header_64* mh, uintptr_t slide,
                                     uintptr_t str_va, uint32_t /*fn_prologue*/) {
    uintptr_t str_page = str_va & ~0xFFFULL;
    uint32_t  str_off  = static_cast<uint32_t>(str_va & 0xFFF);

    const uint8_t* p = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                uintptr_t seg_va   = seg->vmaddr + slide;
                uintptr_t seg_end  = seg_va + seg->vmsize;
                // Scan all sections in __TEXT that look like code (align >= 2)
                const section_64* sec = reinterpret_cast<const section_64*>(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j, ++sec) {
                    if (sec->size < 8) continue;
                    // Skip pure-data sections (strings, unwind, etc.)
                    uint32_t stype = sec->flags & 0xFF;
                    if (stype != 0x00 && stype != 0x08 && stype != 0x0A) continue;
                    uintptr_t sect_start = sec->addr + slide;
                    uintptr_t sect_end   = sect_start + sec->size;
                    if (sect_end > seg_end) sect_end = seg_end;

                    for (uintptr_t pc = sect_start; pc + 8 <= sect_end; pc += 4) {
                        const uint32_t insn = *reinterpret_cast<const volatile uint32_t*>(pc);
                        if ((insn & 0x9F000000U) != 0x90000000U) continue;

                        uint8_t  rd    = insn & 0x1FU;
                        uint32_t immhi = (insn >> 5) & 0x7FFFFU;
                        uint32_t immlo = (insn >> 29) & 0x3U;
                        int64_t  imm21 = static_cast<int64_t>(
                                            static_cast<int32_t>(((immhi << 2) | immlo) << 11)) >> 11;
                        uintptr_t adrp_res = (pc & ~0xFFFULL) + (imm21 << 12);
                        if (adrp_res != str_page) continue;

                        // ADD Xd, Xrd, #str_off or LDR Xd,[Xrd,#str_off*8]
                        bool ref_found = false;
                        for (uintptr_t la = pc + 4; la <= pc + 16 && la + 4 <= sect_end; la += 4) {
                            const uint32_t nx = *reinterpret_cast<const volatile uint32_t*>(la);
                            // ADD (imm, 64-bit, no shift)
                            if ((nx >> 22) == 0x244U &&
                                ((nx >> 5) & 0x1FU) == rd &&
                                ((nx >> 10) & 0xFFFU) == str_off) { ref_found = true; break; }
                            // LDR (unsigned offset, 64-bit) scaled by 8
                            if ((nx & 0xFFC00000U) == 0xF9400000U &&
                                ((nx >> 5) & 0x1FU) == rd &&
                                ((nx >> 10) & 0xFFFU) * 8 == str_off) { ref_found = true; break; }
                        }
                        if (!ref_found) continue;

                        log_line("[CustomPatch] ADRP hit @ 0x%lx sect=%.*s -- scanning for fn entry",
                                 (long)(pc - slide + 0x100000000ULL), 16, sec->sectname);

                        // Walk back up to 128KB for any function entry pattern
                        uintptr_t back  = pc & ~0xFULL;
                        uintptr_t limit = (back > 0x20000U) ? (back - 0x20000U) : sect_start;
                        for (; back >= limit; back -= 4) {
                            const uint32_t pro = *reinterpret_cast<const volatile uint32_t*>(back);
                            // STP (pre-index, 64-bit): bits[31:23] = 101001011 = 0x135
                            bool is_stp_preidx = (pro >> 23) == 0x135U;
                            // SUB SP, SP, #N: bits[31:22]=1101000100, bits[4:0]=11111
                            // mask bits[31:22] = 0xFFC00000, pattern 0xD1000000; bits[4:0]=0x1F
                            bool is_sub_sp = ((pro & 0xFFC0001FU) == 0xD100001FU);
                            if (is_stp_preidx || is_sub_sp) return back;
                            if (back == sect_start) break;
                        }
                        log_line("[CustomPatch] ADRP hit @ 0x%lx but no fn entry found in walkback",
                                 (long)(pc - slide + 0x100000000ULL));
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    return 0;
}

// Scan __DATA_CONST for all uintptr_t values == fn_va; patch to stub_va.
// Returns count of patched slots.
static int patch_data_const_slots(const mach_header_64* mh, uintptr_t slide,
                                   uintptr_t fn_va, uintptr_t stub_va) {
    int count = 0;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__DATA_CONST", 16) == 0) {
                uintptr_t seg_start = seg->vmaddr + slide;
                uintptr_t seg_end   = seg_start + seg->vmsize;
                for (uintptr_t addr = seg_start;
                     addr + sizeof(uintptr_t) <= seg_end;
                     addr += sizeof(uintptr_t)) {
                    if (*reinterpret_cast<const volatile uintptr_t*>(addr) != fn_va) continue;
                    mach_vm_address_t page = addr & ~((mach_vm_address_t)0x3FFF);
                    kern_return_t kr = vm_protect(mach_task_self(),
                                                  static_cast<vm_address_t>(page), 0x4000, false,
                                                  VM_PROT_READ | VM_PROT_WRITE);
                    if (kr != KERN_SUCCESS) {
                        log_line("[CustomPatch] vm_protect(rw) FAIL kr=%d slot=0x%lx",
                                 kr, (long)addr);
                        continue;
                    }
                    *reinterpret_cast<volatile uintptr_t*>(addr) = stub_va;
                    __asm__ volatile("dmb ish" ::: "memory");
                    vm_protect(mach_task_self(),
                               static_cast<vm_address_t>(page), 0x4000, false, VM_PROT_READ);
                    ++count;
                }
            }
        }
        p += lc->cmdsize;
    }
    return count;
}

} // namespace

void install_customization_patch() {
    const mach_header_64* mh =
        reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    if (!mh) {
        log_line("[CustomPatch] FAIL: no image header");
        return;
    }
    uintptr_t base  = reinterpret_cast<uintptr_t>(mh);
    uintptr_t slide = base - 0x100000000ULL;

    // 1. Try known fixed offset (fast, build-specific).
    uintptr_t fn_va = 0;
    {
        uintptr_t candidate = base + kCustomFnOff;
        uint32_t pro = *reinterpret_cast<const volatile uint32_t*>(candidate);
        if (pro == kCustomFnPrologue) {
            fn_va = candidate;
            log_line("[CustomPatch] fn at fixed offset 0x%lx prologue OK", (long)fn_va);
        } else {
            log_line("[CustomPatch] prologue mismatch at 0x%lx: got 0x%08x want 0x%08x -- "
                     "trying string scan", (unsigned long)candidate, pro, kCustomFnPrologue);
        }
    }

    // 2. String-anchor scan: "HandleCustomizationFailed" (UFunction name in __cstring).
    // MSHookFunction on __TEXT is blocked by AMFI; this path finds the function dynamically
    // so we can do a __DATA_CONST vtable swap instead.
    // Note: in UE5 build 43.10 the string is in __cstring but not referenced via
    // ADRP+ADD in __text; the ADRP hit may appear in __init_offsets functions.
    if (!fn_va) {
        uintptr_t str_va = find_cstring_va(mh, slide, "HandleCustomizationFailed");
        if (str_va) {
            log_line("[CustomPatch] string 'HandleCustomizationFailed' at 0x%lx", (long)str_va);
            fn_va = find_fn_via_string(mh, slide, str_va, kCustomFnPrologue);
            if (fn_va)
                log_line("[CustomPatch] fn via string scan 0x%lx", (long)fn_va);
            else
                log_line("[CustomPatch] string found but no ADRP hit in any __TEXT section -- "
                         "string may only be in UE5 reflection metadata, not referenced in code");
        } else {
            log_line("[CustomPatch] 'HandleCustomizationFailed' not found in __TEXT");
        }
    }

    if (!fn_va) {
        log_line("[CustomPatch] FAIL: could not locate HandleCustomizationFailed");
        return;
    }

    // 3. VTable swap in __DATA_CONST (AMFI-safe). No __TEXT write.
    uintptr_t stub_va = reinterpret_cast<uintptr_t>(customization_failed_stub);
    int n = patch_data_const_slots(mh, slide, fn_va, stub_va);
    if (n > 0) {
        log_line("[CustomPatch] vtable swap: %d slot(s) fn=0x%lx -> stub=0x%lx "
                 "NumLoadCustomizationFailed suppressed", n, (long)fn_va, (long)stub_va);
    } else {
        log_line("[CustomPatch] WARNING: fn 0x%lx not in __DATA_CONST vtable -- "
                 "ContentPatch (HTTP) still handles cooked-content-package/link/experience_br",
                 (long)fn_va);
    }
}

} // namespace fndiag
