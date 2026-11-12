#include "update/NetFailurePatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <libkern/OSCacheControl.h>
#include <cstdint>
#include <cstring>

namespace fndiag {

// SUB sp, sp, #0x80 - prologue of UEngine::BroadcastNetworkFailure
static constexpr uint32_t kBnfPrologue    = 0xd10203ffU;
// Known file offset of BNF from MachO base (Fortnite v2.0.32 / build 43)
static constexpr uintptr_t kBnfOffset     = 0x5642c74UL;
// String used to locate BNF via ADRP+ADD scan in __TEXT,__text
static constexpr char     kBnfString[]    = "BroadcastNetworkFailure";
// Scan budget: how far back to walk from ADRP+ADD to find function prologue
static constexpr size_t   kMaxWalkback    = 0x8000U;
// ARM64 encoding of island instructions (version-independent)
static constexpr uint32_t kIslandCbzX16  = 0xB4000050U; // CBZ X16, +8 (skip BR if slot==0)
static constexpr uint32_t kIslandBrX16   = 0xD61F0200U; // BR X16

using BnfFn = void (*)(void* self, void* world, void* net_driver,
                        int32_t failure_type, void* error_string);
static BnfFn g_orig_bnf = nullptr;

static void bnf_bypass_stub(void* self, void* world, void* net_driver,
                              int32_t failure_type, void* error_string) {
    log_line("[NetFailurePatch] BNF type=%d (pass-through)", failure_type);
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

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(bnf_bypass_stub);

    // --- 3. Disk-island fast path: populate DATA slot, no __TEXT write needed ---
    // patch_binary.py installs a 20-byte ADRP+LDR+CBZ+BR+RET island in the Mach-O
    // padding before __TEXT,__text. Its LDR loads a pointer from a __bss slot (zero on
    // disk) which we fill with stub_va at runtime. The BL call sites already point to
    // this island after patch_binary.py runs. Writing the DATA slot arms the hook.
    // __DATA has maxprot=rw- so patch_data_ptr() works; no __TEXT vm_protect needed.
    //
    // Dynamic island scan: instead of hardcoded offsets (kPaddingIslandOff, kDataSlotOff,
    // kDiskIslandMagic), scan the Mach-O padding area for the ADRP+LDR+CBZ+BR pattern.
    // This decouples the dylib from binary-specific constants that change each update.
    // Only patch_binary.py needs re-running after an Epic update (no dylib recompile).
    bool trampoline_armed = false;
    {
        // Padding: from end of load commands to start of __TEXT,__text.
        // Subtract 16 bytes from the computed start: patch_binary.py may place the island
        // up to one instruction (4 bytes) before sizeofcmds ends due to alignment slack.
        // Starting 16 bytes early is harmless (we validate the full ADRP+LDR+CBZ+BR pattern).
        uintptr_t pad_start_raw = base + sizeof(mach_header_64) +
                              reinterpret_cast<const mach_header_64*>(mh)->sizeofcmds;
        uintptr_t pad_start = (pad_start_raw >= base + 16) ? pad_start_raw - 16 : base;
        uintptr_t pad_end   = text_start;
        uintptr_t slot_va   = 0;

        for (uintptr_t p = pad_start; p + 20 <= pad_end; p += 4) {
            const uint32_t* w = reinterpret_cast<const uint32_t*>(p);
            // w[0]: ADRP X16  -> bits[31,28:24]=1,10000; Rd=16(0x10)
            if ((w[0] & 0x9F00001FU) != 0x90000010U) continue;
            // w[1]: LDR X16, [X16, #imm12*8]  -> bits[31:22]=0b1111 1001 01, Rn=16, Rt=16
            if ((w[1] & 0xFFC003FFU) != 0xF9400210U) continue;
            // w[2]: CBZ X16, +8  = 0xB4000050
            if (w[2] != kIslandCbzX16) continue;
            // w[3]: BR X16  = 0xD61F0200
            if (w[3] != kIslandBrX16)  continue;

            // Decode DATA slot VA from ADRP + LDR
            uint32_t immhi = (w[0] >> 5) & 0x7FFFFU;
            uint32_t immlo = (w[0] >> 29) & 0x3U;
            int64_t  imm21 = static_cast<int64_t>(
                                 static_cast<int32_t>(((immhi << 2) | immlo) << 11)) >> 11;
            uintptr_t adrp_res = (p & ~0xFFFULL) + (imm21 << 12);
            uint32_t  imm12    = (w[1] >> 10) & 0xFFFU;
            slot_va = adrp_res + (imm12 * 8);  // 64-bit LDR scales by 8
            log_line("[NetFailurePatch] disk-island found at 0x%lx slot=0x%lx",
                     (long)p, (long)slot_va);
            break;
        }

        if (slot_va) {
            if (patch_data_ptr(slot_va, stub_va)) {
                g_orig_bnf = reinterpret_cast<BnfFn>(bnf_va);
                trampoline_armed = true;
                log_line("[NetFailurePatch] disk-island: slot 0x%lx -> stub (armed)",
                         (long)slot_va);
            } else {
                log_line("[NetFailurePatch] disk-island: slot write FAILED 0x%lx", (long)slot_va);
            }
        } else {
            log_line("[NetFailurePatch] disk island not found in padding [0x%lx,0x%lx) - __TEXT fallback",
                     (long)pad_start, (long)pad_end);
        }
    }

    // --- 4. __TEXT island fallback: DISABLED (AMFI fatal) ---
    // vm_protect(VM_PROT_COPY) on __TEXT produces a COW page not covered by the
    // binary's code signature. AMFI kills the process (EXC_BAD_ACCESS SIGKILL,
    // Namespace CODESIGNING, Code 2 "Invalid Page") the first time the CPU fetches
    // an instruction from that page. This is true even with get-task-allow present.
    // The only valid hook path is the disk island installed by patch_binary.py.
    // deploy.sh now calls patch_binary.py --apply automatically before each deploy.
    if (!trampoline_armed) {
        log_line("[NetFailurePatch] FATAL: disk island not found. "
                 "Run: sudo bash tools/deploy.sh && bash tools/resign.sh");
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
