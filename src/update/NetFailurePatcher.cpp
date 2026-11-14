#include "update/NetFailurePatcher.hpp"
#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#include <cstring>
#include <atomic>

namespace fndiag {

// SUB sp, sp, #0x80 - prologue of UEngine::BroadcastNetworkFailure
static constexpr uint32_t kBnfPrologue    = 0xd10203ffU;
// Known file offset of BNF from MachO base.
// 43.00 (build 59596594): 0x5642c74
// 43.10 (build 60278837): 0x56c999c
static constexpr uintptr_t kBnfOffset     = 0x56c999cUL;
// String used to locate BNF via ADRP+ADD scan in __TEXT,__text
static constexpr char     kBnfString[]    = "BroadcastNetworkFailure";
// Scan budget: how far back to walk from ADRP+ADD to find function prologue
static constexpr size_t   kMaxWalkback    = 0x8000U;

using BnfFn = void (*)(void* self, void* world, void* net_driver,
                        int32_t failure_type, void* error_string);
static BnfFn g_orig_bnf = nullptr;

// kConnectionLost=3, kConnectionTimeout=4 (confirmed from ENetworkFailure strings)
static constexpr int32_t kConnectionLost    = 3;
static constexpr int32_t kConnectionTimeout = 4;
// 30s window: flood is unbounded (server sends CL every ~8ms until disconnected).
// synthetic CT fires at t+25s -> lobby return. 30s covers the full 25s + 5s buffer.
static constexpr uint64_t kKickWindowNs = 30000ULL * 1000000ULL;
// 25s synthetic ConnectionTimeout delay
static constexpr double   kSyntheticDelaySecs = 25.0;

// Guards against firing the synthetic CT more than once per kick event
static std::atomic<bool> g_synthetic_pending{false};

// Kick window in mach_absolute_time ticks, computed once at init.
// Avoids calling mach_timebase_info() (kernel trap) on every BNF invocation
// during the CL flood (~125 calls/s during a kick event).
static uint64_t g_kick_window_ticks = 0;

static void bnf_bypass_stub(void* self, void* world, void* net_driver,
                              int32_t failure_type, void* error_string) {
    // Check if this ConnectionLost is within the kick-suppression window
    if (failure_type == kConnectionLost) {
        uint64_t kick_at = g_last_kick_suppressed_at.load(std::memory_order_acquire);
        if (kick_at != 0) {
            uint64_t now = mach_absolute_time();
            uint64_t window_ticks = g_kick_window_ticks;
            if (now >= kick_at && (now - kick_at) <= window_ticks) {
                log_line("[NetFailurePatch] ConnectionLost suppressed (within kick window)");

                // Fire synthetic ConnectionTimeout once after 25s
                bool expected = false;
                if (g_synthetic_pending.compare_exchange_strong(expected, true,
                        std::memory_order_acq_rel)) {
                    // Capture params for the dispatch block
                    void* cap_self   = self;
                    void* cap_world  = world;
                    void* cap_driver = net_driver;
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(kSyntheticDelaySecs * NSEC_PER_SEC)),
                        dispatch_get_main_queue(),
                        ^{
                            log_line("[NetFailurePatch] synthetic ConnectionTimeout firing (25s)");
                            g_synthetic_pending.store(false, std::memory_order_release);
                            if (g_orig_bnf)
                                g_orig_bnf(cap_self, cap_world, cap_driver,
                                           kConnectionTimeout, nullptr);
                        });
                }
                return; // suppress this ConnectionLost
            }
        }
    }

    log_line("[NetFailurePatch] BNF type=%d", failure_type);
    if (g_orig_bnf) g_orig_bnf(self, world, net_driver, failure_type, error_string);
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

    int adrp_page_hits = 0;  // ADRP instructions landing on str_page
    int add_full_hits  = 0;  // ADRP+ADD pairs with matching imm12

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
        ++adrp_page_hits;

        // Look ahead up to 4 instructions for ADD Xd, Xrd, #str_off.
        // The compiler often interleaves ADRP with unrelated instructions to hide
        // the ADRP latency, so the ADD is not always at pc+4.
        bool add_found = false;
        for (uintptr_t la = pc + 4; la <= pc + 16 && la + 4 <= text_end; la += 4) {
            const uint32_t nx = *reinterpret_cast<const volatile uint32_t*>(la);
            if ((nx >> 22) != 0x244U) continue;         // ADD 64-bit imm (sh=0)
            if (((nx >> 5) & 0x1FU) != rd) continue;    // Rn == ADRP Rd
            if (((nx >> 10) & 0xFFFU) != str_off) continue;
            add_found = true;
            break;
        }
        if (!add_found) continue;
        ++add_full_hits;

        // Found ADRP+ADD loading str_va. Walk back up to kMaxWalkback
        // looking for kBnfPrologue (function entry SUB SP,SP,#0x80).
        uintptr_t back = pc & ~0xFULL; // align to 16
        uintptr_t limit = (back > kMaxWalkback) ? (back - kMaxWalkback) : text_start;
        for (; back >= limit; back -= 4) {
            if (*reinterpret_cast<const volatile uint32_t*>(back) == kBnfPrologue)
                return back;
            if (back == text_start) break;
        }
        log_line("[NetFailurePatch] ADRP+ADD match at 0x%lx but no prologue in %zuKB",
                 (long)pc, kMaxWalkback / 1024);
    }
    log_line("[NetFailurePatch] find_bnf_via_string: adrp_page=%d add_full=%d str_page=0x%lx off=0x%x",
             adrp_page_hits, add_full_hits, (long)str_page, str_off);
    return 0;
}

void install_net_failure_patch() {
    // Compute kick window in ticks once; avoids per-call mach_timebase_info() syscall.
    if (g_kick_window_ticks == 0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        g_kick_window_ticks = kKickWindowNs * tb.denom / tb.numer;
    }

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

    // --- 2. Find BroadcastNetworkFailure VA ---
    // Primary: known file offset (fast, reliable for the target build).
    // Fallback: ADRP+ADD string-anchor scan (version-independent but slower).
    uintptr_t bnf_va = 0;
    {
        uintptr_t candidate = base + kBnfOffset;
        uint32_t pro = *reinterpret_cast<const volatile uint32_t*>(candidate);
        if (pro == kBnfPrologue) {
            bnf_va = candidate;
            log_line("[NetFailurePatch] BNF via fixed offset 0x%lx (slide=0x%lx)",
                     (long)bnf_va, (long)slide);
        } else {
            log_line("[NetFailurePatch] fixed offset 0x%lx bad prologue=0x%08x, trying string scan",
                     (long)candidate, pro);
        }
    }
    if (!bnf_va) {
        uintptr_t str_va = find_bnf_string_va(mh, slide);
        if (str_va) bnf_va = find_bnf_via_string(text_start, text_size, str_va);
        if (bnf_va) {
            uint32_t pro = *reinterpret_cast<const volatile uint32_t*>(bnf_va);
            if (pro != kBnfPrologue) {
                log_line("[NetFailurePatch] string scan 0x%lx bad prologue=0x%08x",
                         (long)bnf_va, pro);
                bnf_va = 0;
            } else {
                log_line("[NetFailurePatch] BNF via string scan 0x%lx (str=0x%lx)",
                         (long)bnf_va, (long)str_va);
            }
        }
    }
    if (!bnf_va) {
        log_line("[NetFailurePatch] BNF not found (slide=0x%lx)", (long)slide);
        return;
    }

    // --- 3. VTable swap in __DATA_CONST (AMFI-safe, no __TEXT write) ---
    // MSHookFunction/vm_protect(COPY) on main executable __TEXT is blocked by AMFI
    // (EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2). Instead, scan
    // __DATA_CONST for all vtable slots pointing to bnf_va and redirect them to our
    // stub. vm_protect on __DATA_CONST works without AMFI restriction (same as
    // KickBypass's 18-entry patch). Calling __TEXT via function pointer is an execute
    // (read) operation - AMFI-safe.
    g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(bnf_bypass_stub);
    int patched = 0;

    const uint8_t* cmd_ptr = reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const load_command* lc = reinterpret_cast<const load_command*>(cmd_ptr);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, "__DATA_CONST", 16) == 0) {
                uintptr_t seg_start = seg->vmaddr + slide;
                uintptr_t seg_end   = seg_start + seg->vmsize;
                for (uintptr_t addr = seg_start;
                     addr + sizeof(uintptr_t) <= seg_end;
                     addr += sizeof(uintptr_t)) {
                    if (*reinterpret_cast<const volatile uintptr_t*>(addr) != bnf_va) continue;
                    // 16KB page (Apple Silicon)
                    mach_vm_address_t page = addr & ~((mach_vm_address_t)0x3FFF);
                    kern_return_t kr = vm_protect(mach_task_self(),
                                                  static_cast<vm_address_t>(page), 0x4000, false,
                                                  VM_PROT_READ | VM_PROT_WRITE);
                    if (kr != KERN_SUCCESS) {
                        log_line("[NetFailurePatch] vm_protect(rw) FAIL kr=%d slot=0x%lx",
                                 kr, (long)addr);
                        continue;
                    }
                    *reinterpret_cast<volatile uintptr_t*>(addr) = stub_va;
                    __asm__ volatile("dmb ish" ::: "memory");
                    vm_protect(mach_task_self(),
                               static_cast<vm_address_t>(page), 0x4000, false, VM_PROT_READ);
                    ++patched;
                    log_line("[NetFailurePatch] vtable slot patched 0x%lx -> stub", (long)addr);
                }
            }
        }
        cmd_ptr += lc->cmdsize;
    }

    if (patched > 0) {
        log_line("[NetFailurePatch] BNF vtable swap: %d slot(s) bnf=0x%lx stub=0x%lx",
                 patched, (long)bnf_va, (long)stub_va);
    } else {
        // BNF is fully devirtualized in this build: all callers use direct BL.
        // Vtable swap cannot intercept them. bnf_bypass_stub never fires, so the
        // synthetic CT at t+25s is also inactive. ConnectionLost floods will reach
        // the game -> NCL screen. Next step: GEngine instance vtable swap or
        // schedule synthetic CT directly from kicked_bypass_stub.
        g_orig_bnf = nullptr;
        log_line("[NetFailurePatch] WARNING: BNF (0x%lx) not in __DATA_CONST vtable "
                 "(devirtualized build) -- CL suppression and synthetic CT INACTIVE",
                 (long)bnf_va);
    }
}

} // namespace fndiag
