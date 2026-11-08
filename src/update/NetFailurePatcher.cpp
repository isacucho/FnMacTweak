#include "update/NetFailurePatcher.hpp"
#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <libkern/OSCacheControl.h>
#include <cstdint>
#include <cstring>
#include <atomic>
#include <time.h>

namespace fndiag {

// SUB sp, sp, #0x80 - prologue of UEngine::BroadcastNetworkFailure
static constexpr uint32_t kBnfPrologue    = 0xd10203ffU;
// String used to locate BNF via ADRP+ADD scan in __TEXT,__text
static constexpr char     kBnfString[]    = "BroadcastNetworkFailure";
// Scan budget: how far back to walk from ADRP+ADD to find function prologue
static constexpr size_t   kMaxWalkback    = 0x1000U;
// Island size: LDR X16,[PC+8] + BR X16 + .quad stub_va
static constexpr size_t   kIslandSize     = 16U;
// NOP (d503201f) - island candidate word
static constexpr uint32_t kNop            = 0xd503201fU;
// ENetworkFailure::Type value for ConnectionLost
static constexpr int32_t  kConnectionLost = 3;
// Window: suppress ConnectionLost only within 500ms of a suppressed kick
static constexpr uint64_t kWindowNs       = 500000000ULL;

using BnfFn = void (*)(void* self, void* world, void* net_driver,
                        int32_t failure_type, void* error_string);
static BnfFn g_orig_bnf = nullptr;

static void bnf_bypass_stub(void* self, void* world, void* net_driver,
                              int32_t failure_type, void* error_string) {
    if (failure_type == kConnectionLost) {
        uint64_t last_kick = g_last_kick_suppressed_ns.load(std::memory_order_relaxed);
        if (last_kick != 0) {
            uint64_t now      = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            uint64_t delta_ns = (now > last_kick) ? (now - last_kick) : 0;
            if (delta_ns < kWindowNs) {
                log_line("[NetFailurePatch] ConnectionLost suppressed "
                         "(delta=%llums after suppressed kick)",
                         (unsigned long long)(delta_ns / 1000000ULL));
                return;
            }
            log_line("[NetFailurePatch] ConnectionLost NOT suppressed "
                     "(delta=%llums > 500ms window)",
                     (unsigned long long)(delta_ns / 1000000ULL));
        }
    }
    if (g_orig_bnf) g_orig_bnf(self, world, net_driver, failure_type, error_string);
}

// Write len bytes into a __TEXT page (W^X compliant: RW then RE, never RWX).
// Covers a single 16KB page; caller must ensure va..va+len fits in one page.
static bool write_text_region(uintptr_t va, const void* data, size_t len) {
    mach_vm_address_t page = va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000,
                                  false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NetFailurePatch] vm_protect(RW) FAIL kr=%d va=0x%lx", kr, (long)va);
        return false;
    }
    memcpy(reinterpret_cast<void*>(va), data, len);
    sys_icache_invalidate(reinterpret_cast<void*>(va), len);
    __asm__ volatile("isb" ::: "memory");
    kr = vm_protect(mach_task_self(),
                    static_cast<vm_address_t>(page), 0x4000,
                    false, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS)
        log_line("[NetFailurePatch] vm_protect(RE) FAIL kr=%d va=0x%lx", kr, (long)va);
    return true;
}

// Locate __TEXT,__text section: returns start VA and size.
static bool get_text_section(const mach_header_64* mh, uintptr_t slide,
                              uintptr_t* out_start, size_t* out_size) {
    const uint8_t* p = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(p);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                const section_64* sec = reinterpret_cast<const section_64*>(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j, ++sec) {
                    if (strncmp(sec->sectname, "__text", 16) == 0) {
                        *out_start = sec->addr + slide;
                        *out_size  = static_cast<size_t>(sec->size);
                        return true;
                    }
                }
                // Fallback: whole __TEXT segment
                *out_start = seg->vmaddr + slide;
                *out_size  = static_cast<size_t>(seg->vmsize);
                return true;
            }
        }
        p += lc->cmdsize;
    }
    return false;
}

// Scan __TEXT,__cstring for the BNF log string; return its VA or 0.
static uintptr_t find_bnf_string_va(const mach_header_64* mh, uintptr_t slide) {
    static constexpr size_t kNLen = sizeof(kBnfString) - 1;
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
                    for (uintptr_t a = start; a + kNLen < end; ++a) {
                        if (memcmp(reinterpret_cast<const void*>(a), kBnfString, kNLen) != 0)
                            continue;
                        // Accept "BroadcastNetworkFailure" at word boundary
                        char nxt = *reinterpret_cast<const char*>(a + kNLen);
                        if (nxt != ':' && nxt != '\0' && nxt != ' ') continue;
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
// to the nearest kBnfPrologue to find BNF's function entry. Returns 0 on failure.
static uintptr_t find_bnf_via_string(uintptr_t text_start, size_t text_size,
                                      uintptr_t str_va) {
    uintptr_t str_page = str_va & ~0xFFFULL;
    uint32_t  str_off  = static_cast<uint32_t>(str_va & 0xFFF);
    uintptr_t text_end = text_start + text_size;

    for (uintptr_t pc = text_start; pc + 8 <= text_end; pc += 4) {
        const uint32_t insn = *reinterpret_cast<const volatile uint32_t*>(pc);

        // ADRP: bits[31,28:24] == 1,10000; bits[29:30] = immlo
        if ((insn & 0x9F000000U) != 0x90000000U) continue;

        uint8_t  rd     = insn & 0x1FU;
        uint32_t immhi  = (insn >> 5) & 0x7FFFFU;   // bits[23:5], 19 bits
        uint32_t immlo  = (insn >> 29) & 0x3U;       // bits[30:29], 2 bits
        // imm21 = immhi:immlo, sign-extended, shifted left 12
        int64_t  imm21  = static_cast<int64_t>(
                              static_cast<int32_t>(((immhi << 2) | immlo) << 11)) >> 11;
        uintptr_t adrp_res = (pc & ~0xFFFULL) + (imm21 << 12);
        if (adrp_res != str_page) continue;

        // Next: ADD Xrd, Xrd, #str_off  (64-bit ADD immediate: 0x91......, sf=1, op=0, S=0)
        const uint32_t next = *reinterpret_cast<const volatile uint32_t*>(pc + 4);
        // mask: opcode[31:22] = 1001 0001 00, check Rd==Rn==rd and imm12==str_off
        uint32_t add_opcode = next >> 22;
        if (add_opcode != 0x244U) continue;             // 0x91>>2 = 0x244
        if ((next & 0x1FU) != rd) continue;             // Rd == rd
        if (((next >> 5) & 0x1FU) != rd) continue;     // Rn == rd
        if (((next >> 10) & 0xFFFU) != str_off) continue;

        // Found ADRP+ADD loading str_va. Walk back up to kMaxWalkback
        // looking for kBnfPrologue (function entry SUB SP,SP,#0x80).
        uintptr_t back = pc & ~0xFULL; // align to 16
        uintptr_t limit = (back > kMaxWalkback) ? (back - kMaxWalkback) : text_start;
        for (; back >= limit; back -= 4) {
            if (*reinterpret_cast<const volatile uint32_t*>(back) == kBnfPrologue)
                return back;
            if (back == text_start) break;
        }
        // No prologue found within budget; keep scanning for more ADRP+ADD pairs
    }
    return 0;
}

// Scan text_start..text_start+text_size for a run of kNopRunNeeded NOP words.
// The island must not cross a 16KB page boundary (write_text_region limit).
static uintptr_t find_nop_island(uintptr_t text_start, size_t text_size) {
    uintptr_t end = text_start + text_size;
    if (text_size < kIslandSize) return 0;
    end -= kIslandSize;
    for (uintptr_t p = text_start; p <= end; p += 4) {
        bool ok = true;
        for (size_t i = 0; i < kIslandSize; i += 4) {
            if (*reinterpret_cast<const volatile uint32_t*>(p + i) != kNop) {
                ok = false; break;
            }
        }
        if (!ok) continue;
        // Reject if island spans two 16KB pages
        if ((p & ~0x3FFFULL) != ((p + kIslandSize - 1) & ~0x3FFFULL)) continue;
        return p;
    }
    return 0;
}

// Write a 16-byte position-independent island at island_va:
//   LDR X16, [PC+8]   ; load stub_va from offset +8
//   BR  X16           ; tail-call to stub
//   .quad stub_va     ; 8-byte literal
static bool write_island(uintptr_t island_va, uintptr_t stub_va) {
    uint8_t buf[16];
    // LDR X16, [PC+8]: opcode 0x58 | (imm19 << 5) | Rd; imm19=2, Rd=16
    uint32_t ldr = 0x58000050U; // LDR X16, [PC+8]
    uint32_t br  = 0xD61F0200U; // BR X16
    memcpy(buf,     &ldr,     4);
    memcpy(buf + 4, &br,      4);
    memcpy(buf + 8, &stub_va, 8);
    return write_text_region(island_va, buf, 16);
}

// Scan text_start..text_start+text_size for BL instructions targeting bnf_va.
// Redirect each one to island_va. Returns number of BL instructions patched.
// Only patches if BL range to island fits in 26-bit signed offset (±128MB).
static int scan_bl_to_bnf(uintptr_t text_start, size_t text_size,
                            uintptr_t bnf_va, uintptr_t island_va) {
    uintptr_t text_end = text_start + text_size;
    int count = 0;
    for (uintptr_t pc = text_start; pc + 4 <= text_end; pc += 4) {
        const uint32_t insn = *reinterpret_cast<const volatile uint32_t*>(pc);
        // BL: bits[31:26] == 0b100101
        if ((insn >> 26) != 0x25U) continue;
        // Decode 26-bit signed immediate (units of 4 bytes)
        int32_t imm26 = static_cast<int32_t>(insn << 6) >> 6;
        uintptr_t target = pc + static_cast<uintptr_t>(static_cast<int64_t>(imm26) * 4);
        if (target != bnf_va) continue;
        // Encode new BL to island
        int64_t disp = static_cast<int64_t>(island_va) - static_cast<int64_t>(pc);
        if (disp < -(1LL << 27) || disp >= (1LL << 27)) {
            log_line("[NetFailurePatch] BL at 0x%lx out of range to island 0x%lx (disp=%lld)",
                     (long)pc, (long)island_va, (long long)disp);
            continue;
        }
        uint32_t new_insn = (0x25U << 26) | (static_cast<uint32_t>(disp / 4) & 0x3FFFFFFU);
        if (write_text_region(pc, &new_insn, 4)) {
            ++count;
            log_line("[NetFailurePatch] BL patched 0x%lx -> island 0x%lx", (long)pc, (long)island_va);
        }
    }
    return count;
}

// Patch a single 8-byte pointer slot in a DATA segment (vtable entry).
static bool patch_data_ptr(uintptr_t slot_va, uintptr_t stub_va) {
    mach_vm_address_t page = slot_va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NetFailurePatch] vm_protect(DATA RW) FAIL kr=%d slot=0x%lx",
                 kr, (long)slot_va);
        return false;
    }
    *reinterpret_cast<volatile uintptr_t*>(slot_va) = stub_va;
    __asm__ volatile("dmb ish" ::: "memory");
    return true;
}

// Scan a DATA segment for 8-byte pointers equal to target_va, replace with stub_va.
static int scan_seg(const segment_command_64* seg, uintptr_t slide,
                     uintptr_t target_va, uintptr_t stub_va) {
    uintptr_t start = seg->vmaddr + slide;
    uintptr_t end   = start + seg->vmsize;
    int n = 0;
    for (uintptr_t addr = start; addr + 8 <= end; addr += 8) {
        if (*reinterpret_cast<const volatile uintptr_t*>(addr) == target_va) {
            if (patch_data_ptr(addr, stub_va)) {
                ++n;
                log_line("[NetFailurePatch] vtable patched 0x%lx (seg %.16s)",
                         (long)addr, seg->segname);
            }
        }
    }
    return n;
}

void install_net_failure_patch() {
    const mach_header_64* mh =
        reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    if (!mh) { log_line("[NetFailurePatch] no image header"); return; }

    uintptr_t base  = reinterpret_cast<uintptr_t>(mh);
    uintptr_t slide = base - 0x100000000ULL;

    // --- 1. Locate __TEXT,__text ---
    uintptr_t text_start = 0;
    size_t    text_size  = 0;
    if (!get_text_section(mh, slide, &text_start, &text_size)) {
        log_line("[NetFailurePatch] __TEXT,__text not found");
        return;
    }

    // --- 2. Find BroadcastNetworkFailure VA via string anchor ---
    uintptr_t str_va = find_bnf_string_va(mh, slide);
    uintptr_t bnf_va = 0;
    if (str_va) {
        bnf_va = find_bnf_via_string(text_start, text_size, str_va);
    }
    if (!bnf_va) {
        log_line("[NetFailurePatch] BNF not found (str_va=0x%lx)", (long)str_va);
        return;
    }
    // Verify prologue at found address
    uint32_t pro = *reinterpret_cast<const volatile uint32_t*>(bnf_va);
    if (pro != kBnfPrologue) {
        log_line("[NetFailurePatch] BNF found at 0x%lx but prologue=0x%08x (unexpected)",
                 (long)bnf_va, pro);
        return;
    }
    log_line("[NetFailurePatch] BNF located: 0x%lx (str=0x%lx slide=0x%lx)",
             (long)bnf_va, (long)str_va, (long)slide);

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(bnf_bypass_stub);

    // --- 3. Find NOP island in __TEXT,__text ---
    uintptr_t island_va = find_nop_island(text_start, text_size);
    bool trampoline_armed = false;
    if (!island_va) {
        log_line("[NetFailurePatch] no NOP island found in __TEXT,__text (%zu bytes)",
                 text_size);
    } else {
        // --- 4. Write island ---
        if (write_island(island_va, stub_va)) {
            g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);
            // --- 5. Scan __TEXT,__text for BL→bnf_va, redirect to island ---
            int bl_count = scan_bl_to_bnf(text_start, text_size, bnf_va, island_va);
            trampoline_armed = (bl_count > 0);
            log_line("[NetFailurePatch] dynamic patch: island=0x%lx bl_patched=%d",
                     (long)island_va, bl_count);
        } else {
            log_line("[NetFailurePatch] island write FAILED at 0x%lx", (long)island_va);
        }
    }

    // --- 6. Vtable scan: covers virtual-dispatch paths regardless of BL result ---
    int vtable_patched = 0;
    int scanned_segs   = 0;
    const uint8_t* cmd_ptr =
        reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t ci = 0; ci < mh->ncmds; ++ci) {
        const load_command* lc = reinterpret_cast<const load_command*>(cmd_ptr);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg =
                reinterpret_cast<const segment_command_64*>(lc);
            const char* name = seg->segname;
            if ((strncmp(name, "__DATA_CONST", 12) == 0 ||
                 strncmp(name, "__AUTH_CONST", 12) == 0 ||
                 strncmp(name, "__DATA_DIRTY", 12) == 0 ||
                 strncmp(name, "__AUTH",        6) == 0 ||
                 strncmp(name, "__DATA",        6) == 0) &&
                seg->vmsize >= 8) {
                ++scanned_segs;
                vtable_patched += scan_seg(seg, slide, bnf_va, stub_va);
            }
        }
        cmd_ptr += lc->cmdsize;
    }
    if (vtable_patched > 0 && !g_orig_bnf)
        g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);

    log_line("[NetFailurePatch] vtable: segs=%d patched=%d trampoline=%s",
             scanned_segs, vtable_patched, trampoline_armed ? "yes" : "no");

    if (!trampoline_armed && vtable_patched == 0) {
        log_line("[NetFailurePatch] WARNING: no BL or vtable entries patched - "
                 "ConnectionLost may not be intercepted");
    }
}

} // namespace fndiag
