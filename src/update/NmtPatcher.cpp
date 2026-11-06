#include "update/NmtPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstdint>
#include <cstring>

namespace fndiag {

// NMT_Failure handler (leaf, not in any vtable - has no DATA pointers).
static constexpr uintptr_t kNmtHandlerOffset  = 0x54e90d4ULL;
static constexpr uint32_t  kNmtPrologue       = 0xa9bf7bfdU;

// Virtual disconnect handler: vtable[0xA8] target, dispatched via trampoline
// at 0x73c40c (LDR x8,[x22] -> LDR x8,[x8,#0xA8] -> BR x8). Frame 2 of the
// V2.0.16 crash has return addr 0x77fab0 which is inside this function; the
// nearest STP x29,x30 backwards from 0x77fab0 is at 0x778440 (confirmed via
// backward scan: prior instruction is a B, typical inter-function boundary).
// Patching this vtable entry intercepts the disconnect before the callback
// chain reaches NMT_Failure.
static constexpr uintptr_t kVirtualHandlerOffset = 0x778440ULL;
static constexpr uint32_t  kVirtualPrologue      = 0xa9bf7bfdU;

// Secondary chain functions - scan these too in case they appear in vtables
// or function-pointer slots that are easier to redirect.
static constexpr uintptr_t kChainOffsets[] = {
    0x77f8c0ULL,  // callback thunk (non-std prologue 0xa9bc5ff8), calls BLR x23
    0x72f5e4ULL,  // frame 3 func, BL 0x73c40c at 0x730408
    0x734248ULL,  // frame 4 func
    0x73aac8ULL,  // frame 5 short wrapper
};

// Stub for virtual disconnect handler: same calling convention as the real
// function (x0=this, x1=arg from trampoline MOV x1,x20). Just return; the
// disconnect chain is never entered, so NMT_Failure never fires.
static void nmt_virtual_bypass_stub() {
    log_line("[NmtPatch] virtual disconnect handler suppressed (vtable[0xA8])");
}

// Generic stub for secondary chain interception points.
static void nmt_chain_bypass_stub() {
    log_line("[NmtPatch] disconnect chain intercepted");
}

// Patch one 8-byte DATA slot: make page rw, write stub addr, restore r.
static bool patch_data_ptr(uintptr_t slot_va, uintptr_t stub_va) {
    mach_vm_address_t page = slot_va & ~((mach_vm_address_t)0x3FFFULL);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[NmtPatch] vm_protect(rw) FAIL kr=%d slot=0x%lx", kr, (long)slot_va);
        return false;
    }
    *reinterpret_cast<volatile uintptr_t*>(slot_va) = stub_va;
    __asm__ volatile("dmb ish" ::: "memory");
    vm_protect(mach_task_self(), static_cast<vm_address_t>(page), 0x4000, false,
               VM_PROT_READ);
    return true;
}

// Scan one segment for all 8-byte-aligned pointers equal to target_va and
// redirect them to stub_va. Returns count of successfully patched slots.
static int scan_and_patch_seg(const segment_command_64* seg, uintptr_t slide,
                               uintptr_t target_va, uintptr_t stub_va,
                               const char* label) {
    uintptr_t start = seg->vmaddr + slide;
    uintptr_t end   = start + seg->vmsize;
    int n = 0;
    for (uintptr_t addr = start; addr + 8 <= end; addr += 8) {
        uintptr_t val = *reinterpret_cast<const volatile uintptr_t*>(addr);
        if (val == target_va) {
            if (patch_data_ptr(addr, stub_va)) {
                ++n;
                log_line("[NmtPatch] %s patched at 0x%lx (seg %.16s)",
                         label, (long)addr, seg->segname);
            }
        }
    }
    return n;
}

void install_nmt_patch() {
    const mach_header_64* mh =
        reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    if (!mh) { log_line("[NmtPatch] no image header"); return; }

    uintptr_t base  = reinterpret_cast<uintptr_t>(mh);
    uintptr_t slide = base - 0x100000000ULL;

    // Confirm NMT handler offset is still valid.
    uintptr_t nmt_va = base + kNmtHandlerOffset;
    uint32_t nmt_prologue = *reinterpret_cast<volatile uint32_t*>(nmt_va);
    if (nmt_prologue != kNmtPrologue) {
        log_line("[NmtPatch] NMT handler prologue mismatch 0x%08x at 0x%lx",
                 nmt_prologue, (long)nmt_va);
        return;
    }

    // Confirm virtual disconnect handler offset is valid.
    uintptr_t virt_va = base + kVirtualHandlerOffset;
    uint32_t virt_prologue = *reinterpret_cast<volatile uint32_t*>(virt_va);
    if (virt_prologue != kVirtualPrologue) {
        log_line("[NmtPatch] virtual handler prologue mismatch 0x%08x at 0x%lx",
                 virt_prologue, (long)virt_va);
        // Don't return: still try secondary chain targets.
    }

    uintptr_t virt_stub  = reinterpret_cast<uintptr_t>(nmt_virtual_bypass_stub);
    uintptr_t chain_stub = reinterpret_cast<uintptr_t>(nmt_chain_bypass_stub);

    int patched_virt  = 0;
    int patched_chain = 0;
    int scanned_segs  = 0;

    const uint8_t* cmd_ptr =
        reinterpret_cast<const uint8_t*>(mh) + sizeof(mach_header_64);

    for (uint32_t ci = 0; ci < mh->ncmds; ++ci) {
        const load_command* lc = reinterpret_cast<const load_command*>(cmd_ptr);
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* seg =
                reinterpret_cast<const segment_command_64*>(lc);
            const char* name = seg->segname;
            // Only scan read-only-after-fixup segments: vtables live in
            // __DATA_CONST/__AUTH_CONST. Scanning __DATA would leave its
            // pages read-only after patch_data_ptr restores VM_PROT_READ,
            // breaking __cxa_guard writes and other mutable DATA uses.
            bool is_target = (strncmp(name, "__DATA_CONST", 16) == 0 ||
                              strncmp(name, "__AUTH_CONST", 16) == 0);
            if (is_target && seg->vmsize >= 8) {
                ++scanned_segs;

                // Primary: virtual disconnect handler (vtable[0xA8] target).
                if (virt_prologue == kVirtualPrologue) {
                    patched_virt += scan_and_patch_seg(seg, slide, virt_va,
                                                       virt_stub, "virt[0xA8]");
                }

                // Secondary: other call-chain functions.
                for (uintptr_t off : kChainOffsets) {
                    uintptr_t target = base + off;
                    patched_chain += scan_and_patch_seg(seg, slide, target,
                                                        chain_stub, "chain");
                }
            }
        }
        cmd_ptr += lc->cmdsize;
    }

    log_line("[NmtPatch] done: base=0x%lx slide=0x%lx "
             "segs=%d virt_patched=%d chain_patched=%d",
             (long)base, (long)slide,
             scanned_segs, patched_virt, patched_chain);
}

} // namespace fndiag
