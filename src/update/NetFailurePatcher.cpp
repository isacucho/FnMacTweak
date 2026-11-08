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

// File offset (from IMAGE_BASE=0x100000000) of UEngine::BroadcastNetworkFailure.
// Found via ADRP+ADD decode of the "UEngine::BroadcastNetworkFailure: FailureType"
// log string at VA 0x10adb3da7. Prologue: SUB sp, sp, #0x80 (0xd10203ff).
static constexpr uintptr_t kBnfOffset   = 0x5642c74ULL;
static constexpr uint32_t  kBnfPrologue = 0xd10203ffU; // SUB sp, sp, #0x80

// ENetworkFailure::Type (UE4 enum):
//   0 NetDriverAlreadyExists ... 3 ConnectionLost ... 7 OutdatedServer
static constexpr int32_t kConnectionLost = 3;

// Window: suppress ConnectionLost only within 500ms of a suppressed kick.
static constexpr uint64_t kWindowNs = 500000000ULL;

// On-disk trampoline constants (also used for in-memory apply path).
// ASLR-independent: BL uses relative encoding; island ADRP page delta is constant.
static constexpr uintptr_t kIslandOffset    = 0x29BCULL;
static constexpr uint32_t  kIslandFirstInsn = 0xB0075530U; // ADRP X16, #0xeaa5
static constexpr uintptr_t kDataSlotOffset  = 0x0EAA7338ULL;

// In-memory BL patch sites and instruction bytes.
static constexpr uintptr_t kBL1Offset = 0x0F21998ULL;
static constexpr uintptr_t kBL2Offset = 0x16356DCULL;
static constexpr uintptr_t kBL3Offset = 0x05B9FB70ULL;

static constexpr uint32_t  kBL1New  = 0x97C38409U; // LE: 09 84 c3 97
static constexpr uint32_t  kBL2New  = 0x97A734B8U; // LE: b8 34 a7 97
static constexpr uint32_t  kBL3New  = 0x96918B93U; // LE: 93 8b 91 96
static constexpr uint32_t  kBL1Orig = 0x951C84B7U; // LE: b7 84 1c 95
static constexpr uint32_t  kBL2Orig = 0x95003566U; // LE: 66 35 00 95
static constexpr uint32_t  kBL3Orig = 0x97EA8C41U; // LE: 41 8c ea 97

static constexpr uint8_t kIslandBytes[12] = {
    0x30, 0x55, 0x07, 0xB0,  // ADRP X16, #0xeaa5000
    0x10, 0x9E, 0x41, 0xF9,  // LDR X16, [X16, #0x338]
    0x00, 0x02, 0x1F, 0xD6   // BR X16
};

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
                     "(delta=%llums > 500ms window, passing through)",
                     (unsigned long long)(delta_ns / 1000000ULL));
        }
    }
    if (g_orig_bnf) g_orig_bnf(self, world, net_driver, failure_type, error_string);
}

// Write len bytes to a __TEXT page (W^X compliant: RW then RE, never RWX).
static bool write_text_region(uintptr_t va, const void* data, size_t len) {
    mach_vm_address_t page = va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000,
                                  false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NetFailurePatch] vm_protect(text RW) FAIL kr=%d va=0x%lx",
                 kr, (long)va);
        return false;
    }
    memcpy(reinterpret_cast<void*>(va), data, len);
    sys_icache_invalidate(reinterpret_cast<void*>(va), len);
    __asm__ volatile("isb" ::: "memory");
    kr = vm_protect(mach_task_self(),
                    static_cast<vm_address_t>(page), 0x4000,
                    false, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS)
        log_line("[NetFailurePatch] vm_protect(text RE) FAIL kr=%d va=0x%lx",
                 kr, (long)va);
    return true;
}

// Apply island + 3 BL patches in memory, then arm the DATA slot.
// Returns true on full success. Only called when binary is NOT patched on disk.
static bool apply_inmem_patch(uintptr_t base, uintptr_t island_va,
                               uintptr_t slot_va, uintptr_t bnf_va,
                               uintptr_t slide) {
    auto rd32 = [](uintptr_t a) -> uint32_t {
        return *reinterpret_cast<const volatile uint32_t*>(a);
    };

    // Validate original bytes at BL sites before writing.
    // If mismatch: binary was updated and offsets are stale.
    uint32_t b1 = rd32(base + kBL1Offset);
    uint32_t b2 = rd32(base + kBL2Offset);
    uint32_t b3 = rd32(base + kBL3Offset);
    if (b1 != kBL1Orig || b2 != kBL2Orig || b3 != kBL3Orig) {
        log_line("[NetFailurePatch] inmem: BL orig mismatch "
                 "0x%08x 0x%08x 0x%08x (exp 0x%08x 0x%08x 0x%08x)",
                 b1, b2, b3, kBL1Orig, kBL2Orig, kBL3Orig);
        return false;
    }

    // Write island + 3 BL patches into __TEXT.
    if (!write_text_region(island_va, kIslandBytes, sizeof(kIslandBytes))) return false;
    if (!write_text_region(base + kBL1Offset, &kBL1New, 4)) return false;
    if (!write_text_region(base + kBL2Offset, &kBL2New, 4)) return false;
    if (!write_text_region(base + kBL3Offset, &kBL3New, 4)) return false;

    // Arm DATA slot.
    mach_vm_address_t pg = slot_va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(pg), 0x4000,
                                  false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NetFailurePatch] inmem: vm_protect DATA slot FAIL kr=%d", kr);
        return false;
    }
    uintptr_t stub_va = reinterpret_cast<uintptr_t>(bnf_bypass_stub);
    *reinterpret_cast<volatile uintptr_t*>(slot_va) = stub_va;
    __asm__ volatile("dmb ish" ::: "memory");
    g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);

    log_line("[NetFailurePatch] in-memory patch applied: "
             "island=0x%lx bl1=0x%lx bl2=0x%lx bl3=0x%lx "
             "slot=0x%lx stub=0x%lx slide=0x%lx",
             (long)island_va,
             (long)(base + kBL1Offset), (long)(base + kBL2Offset),
             (long)(base + kBL3Offset),
             (long)slot_va, (long)stub_va, (long)slide);
    return true;
}

// DATA path: patch an 8-byte slot in __DATA_CONST/__AUTH_CONST.
static bool patch_data_ptr(uintptr_t slot_va, uintptr_t stub_va) {
    mach_vm_address_t page = slot_va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NetFailurePatch] vm_protect(rw) FAIL kr=%d slot=0x%lx",
                 kr, (long)slot_va);
        return false;
    }
    *reinterpret_cast<volatile uintptr_t*>(slot_va) = stub_va;
    __asm__ volatile("dmb ish" ::: "memory");
    return true;
}

static int scan_seg(const segment_command_64* seg, uintptr_t slide,
                     uintptr_t target_va, uintptr_t stub_va) {
    uintptr_t start = seg->vmaddr + slide;
    uintptr_t end   = start + seg->vmsize;
    int n = 0;
    for (uintptr_t addr = start; addr + 8 <= end; addr += 8) {
        if (*reinterpret_cast<const volatile uintptr_t*>(addr) == target_va) {
            if (patch_data_ptr(addr, stub_va)) {
                ++n;
                log_line("[NetFailurePatch] vtable patched at 0x%lx (seg %.16s)",
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

    uintptr_t island_va = base + kIslandOffset;
    uintptr_t slot_va   = base + kDataSlotOffset;
    uint32_t  island_insn = *reinterpret_cast<const volatile uint32_t*>(island_va);

    // --- On-disk trampoline path ---
    // Binary was patched on disk: island present, arm DATA slot then also vtable scan.
    bool trampoline_armed = false;
    if (island_insn == kIslandFirstInsn) {
        uintptr_t stub_va_s = reinterpret_cast<uintptr_t>(bnf_bypass_stub);
        mach_vm_address_t pg = slot_va & ~((mach_vm_address_t)0x3FFFULL);
        kern_return_t kr = vm_protect(mach_task_self(),
                                      static_cast<vm_address_t>(pg), 0x4000,
                                      false, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            log_line("[NetFailurePatch] vm_protect DATA slot FAIL kr=%d slot=0x%lx",
                     kr, (long)slot_va);
            return;
        }
        *reinterpret_cast<volatile uintptr_t*>(slot_va) = stub_va_s;
        __asm__ volatile("dmb ish" ::: "memory");

        uintptr_t bnf_va = base + kBnfOffset;
        uint32_t  pro    = *reinterpret_cast<const volatile uint32_t*>(bnf_va);
        if (pro == kBnfPrologue) {
            g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);
            log_line("[NetFailurePatch] on-disk trampoline armed (pass-through): "
                     "island=0x%lx slot=0x%lx stub=0x%lx slide=0x%lx",
                     (long)island_va, (long)slot_va, (long)stub_va_s, (long)slide);
        } else {
            log_line("[NetFailurePatch] on-disk trampoline armed (suppress-only, "
                     "prologue=0x%08x stale): island=0x%lx slot=0x%lx stub=0x%lx",
                     pro, (long)island_va, (long)slot_va, (long)stub_va_s);
        }
        trampoline_armed = true;
    }

    // --- In-memory patch path ---
    // Binary unpatched on disk (e.g. after Fortnite update). Apply island + BLs
    // at runtime. Requires valid kBnfOffset; if stale, fall through to vtable scan.
    if (!trampoline_armed) {
        uintptr_t bnf_va_m = base + kBnfOffset;
        uint32_t  pro_m    = *reinterpret_cast<const volatile uint32_t*>(bnf_va_m);
        if (pro_m == kBnfPrologue) {
            if (apply_inmem_patch(base, island_va, slot_va, bnf_va_m, slide))
                trampoline_armed = true;
            else
                log_line("[NetFailurePatch] inmem patch FAILED, trying vtable scan");
        } else {
            log_line("[NetFailurePatch] kBnfOffset stale (prologue=0x%08x), "
                     "skipping inmem path", pro_m);
        }
    }

    // --- Vtable scan path ---
    // Always run to also cover virtual-dispatch call paths to BnfFn.
    uintptr_t bnf_va  = base + kBnfOffset;
    uint32_t  prologue = *reinterpret_cast<const volatile uint32_t*>(bnf_va);
    if (prologue != kBnfPrologue) {
        if (trampoline_armed) {
            // Trampoline covers devirtualized BL sites; skip vtable scan.
            log_line("[NetFailurePatch] prologue stale (0x%08x) but trampoline armed, "
                     "vtable scan skipped", prologue);
        } else {
            log_line("[NetFailurePatch] prologue mismatch 0x%08x at 0x%lx (expected 0x%08x) "
                     "-- offset stale, ConnectionLost NOT intercepted",
                     prologue, (long)bnf_va, kBnfPrologue);
        }
        return;
    }

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(bnf_bypass_stub);
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

    if (vtable_patched > 0) {
        if (!g_orig_bnf) g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);
        log_line("[NetFailurePatch] vtable scan: segs=%d patched=%d trampoline=%s",
                 scanned_segs, vtable_patched, trampoline_armed ? "yes" : "no");
    } else if (trampoline_armed) {
        log_line("[NetFailurePatch] vtable=0 (trampoline covers BL sites, segs=%d)",
                 scanned_segs);
    } else {
        log_line("[NetFailurePatch] vtable=0 (segs_scanned=%d). "
                 "On-disk patch not applied (island=0x%08x expected 0x%08x). "
                 "Run: python3 tools/patch_binary.py --apply && resign.sh",
                 scanned_segs, island_insn, kIslandFirstInsn);
    }
}

} // namespace fndiag
