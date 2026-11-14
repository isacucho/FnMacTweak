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

// Find a C string needle in __TEXT,__cstring; return its runtime VA or 0.
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
                    if (strncmp(sec->sectname, "__cstring", 16) != 0) continue;
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

// Scan __TEXT,__text for ADRP+ADD pair that loads str_va, then walk back
// to the nearest function entry matching fn_prologue. Returns 0 on failure.
static uintptr_t find_fn_via_string(const mach_header_64* mh, uintptr_t slide,
                                     uintptr_t str_va, uint32_t fn_prologue) {
    // Find __TEXT,__text section
    uintptr_t text_start = 0;
    size_t    text_size  = 0;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                const section_64* sec = reinterpret_cast<const section_64*>(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j, ++sec) {
                    if (strncmp(sec->sectname, "__text", 16) == 0) {
                        text_start = sec->addr + slide;
                        text_size  = static_cast<size_t>(sec->size);
                        break;
                    }
                }
                if (!text_start) {
                    text_start = seg->vmaddr + slide;
                    text_size  = static_cast<size_t>(seg->vmsize);
                }
                break;
            }
        }
        p += lc->cmdsize;
    }
    if (!text_start) return 0;

    uintptr_t str_page = str_va & ~0xFFFULL;
    uint32_t  str_off  = static_cast<uint32_t>(str_va & 0xFFF);
    uintptr_t text_end = text_start + text_size;

    for (uintptr_t pc = text_start; pc + 8 <= text_end; pc += 4) {
        const uint32_t insn = *reinterpret_cast<const volatile uint32_t*>(pc);
        // ADRP
        if ((insn & 0x9F000000U) != 0x90000000U) continue;

        uint8_t  rd    = insn & 0x1FU;
        uint32_t immhi = (insn >> 5) & 0x7FFFFU;
        uint32_t immlo = (insn >> 29) & 0x3U;
        int64_t  imm21 = static_cast<int64_t>(
                             static_cast<int32_t>(((immhi << 2) | immlo) << 11)) >> 11;
        uintptr_t adrp_res = (pc & ~0xFFFULL) + (imm21 << 12);
        if (adrp_res != str_page) continue;

        // ADD Xd, Xrd, #str_off (look 1-4 insns ahead)
        bool add_found = false;
        for (uintptr_t la = pc + 4; la <= pc + 16 && la + 4 <= text_end; la += 4) {
            const uint32_t nx = *reinterpret_cast<const volatile uint32_t*>(la);
            if ((nx >> 22) != 0x244U) continue;
            if (((nx >> 5) & 0x1FU) != rd) continue;
            if (((nx >> 10) & 0xFFFU) != str_off) continue;
            add_found = true;
            break;
        }
        if (!add_found) continue;

        // Walk back up to 32KB for fn_prologue
        uintptr_t back  = pc & ~0xFULL;
        uintptr_t limit = (back > 0x8000U) ? (back - 0x8000U) : text_start;
        for (; back >= limit; back -= 4) {
            if (*reinterpret_cast<const volatile uint32_t*>(back) == fn_prologue)
                return back;
            if (back == text_start) break;
        }
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

    // 2. String-anchor scan: "execHandleCustomizationFailed" (UFunction name in __cstring).
    // MSHookFunction on __TEXT is blocked by AMFI; this path finds the function dynamically
    // so we can do a __DATA_CONST vtable swap instead.
    if (!fn_va) {
        uintptr_t str_va = find_cstring_va(mh, slide, "execHandleCustomizationFailed");
        if (str_va) {
            fn_va = find_fn_via_string(mh, slide, str_va, kCustomFnPrologue);
            if (fn_va)
                log_line("[CustomPatch] fn via string scan 0x%lx", (long)fn_va);
            else
                log_line("[CustomPatch] string found but fn prologue not found in walkback");
        } else {
            log_line("[CustomPatch] 'execHandleCustomizationFailed' not in __cstring");
        }
    }

    if (!fn_va) {
        log_line("[CustomPatch] FAIL: could not locate execHandleCustomizationFailed -- "
                 "ContentPatch (HTTP layer) still active");
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
