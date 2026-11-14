/*
 * CompatReport.cpp - hook del reporter de compatibilidad interno de Fortnite.
 *
 * Encuentra el slot de vtable del reporter en __DATA_CONST mediante fingerprint
 * de __TEXT (portado de JadedFix). Lo reemplaza con vm_protect + CAS atomico.
 *
 * La funcion hookeada: int report(void* self, uint32_t type, const void* data, uint32_t flag)
 * Tipos suprimidos con flag==1: {5, 19, 23, 49}
 *
 * Incompatibilidad resuelta: JadedFix compilaba con macOS SDK (-mmacosx-version-min=14.0),
 * lo que genera LC_BUILD_VERSION platform=macOS en un proceso iOS Catalyst, causando
 * comportamiento inconsistente de dyld al cargar multiples dylibs. Esta version compila
 * con iphoneos SDK y se integra en FnMacBypass eliminando el problema.
 */

#include "eos/CompatReport.hpp"
#include "core/DiagLog.hpp"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <atomic>
#include <cstdint>
#include <cstring>

namespace {

struct Span {
    const uint8_t* bytes;
    size_t         size;
    uintptr_t      address;
};

// Fingerprint derivado del transport v43 verificado.
// Destinos de branches se verifican por separado en fnBranches.
static const uint32_t kBody[33] = {
    0xd10143ffu, 0xa90257f6u, 0xa9034ff4u, 0xa9047bfdu, 0x910103fdu, 0x96bde1ffu, 0x34000143u,
    0x96bde08fu, 0x37000120u, 0x52800013u, 0xf9400be0u, 0xb4000040u, 0x96456631u, 0xaa1303e0u,
    0xa9447bfdu, 0x16bddfe3u, 0x96bde262u, 0x96bde1edu, 0x54000041u, 0x96bde0f7u, 0x96bde2bcu,
    0x52800148u, 0x39003be8u, 0x12001e88u, 0x79001be8u, 0x96bde06au, 0x96bde23au, 0xb4000080u,
    0x910043e1u, 0x52800062u, 0x97ffda08u, 0x52800033u, 0x17ffffeau,
};

struct BranchFP { unsigned index; uint32_t words[8]; };

static const BranchFP kBranches[] = {
    {5,  {0xaa0303f4u, 0xaa0203e8u, 0xaa0103f5u, 0xaa0003f3u, 0xa9017fffu, 0xd65f03c0u, 0xaa0203f3u, 0xaa0103f4u}},
    {7,  {0xf9400269u, 0xf9406929u, 0x910043e2u, 0xaa1303e0u, 0xaa0803e1u, 0xd61f0120u, 0xaa1403e1u, 0xaa1503e2u}},
    {12, {0xb4000180u, 0xaa0003e1u, 0xf0094e68u, 0xf9458500u, 0xb4000120u, 0xf9400008u, 0xf9402902u, 0xf0fffde8u}},
    {15, {0xa9434ff4u, 0xa94257f6u, 0x910143ffu, 0xd65f03c0u, 0x910603e0u, 0xaa1703e1u, 0x14000000u, 0xf9400008u}},
    {16, {0x910043e0u, 0xaa0803e1u, 0x14000000u, 0xf9000008u, 0xf9401400u, 0x14000000u, 0xaa1503e0u, 0x14000000u}},
    {17, {0x321962a8u, 0x7100029fu, 0x1a8812b4u, 0x294323e0u, 0x6b08001fu, 0xd65f03c0u, 0xaa0303f4u, 0xaa0203e8u}},
    {19, {0x910043e8u, 0x910043e1u, 0x91003102u, 0x52802020u, 0x14000000u, 0xf9000028u, 0xf9400408u, 0xf8008c28u}},
    {20, {0x11000408u, 0xb9001be8u, 0xf9400be8u, 0x3820c914u, 0xd65f03c0u, 0x52800040u, 0x52800041u, 0xd65f03c0u}},
    {25, {0x910033e0u, 0x910043e1u, 0x14000000u, 0x7103fd1fu, 0x1a9f97ebu, 0x72103d1fu, 0xd65f03c0u, 0xf940abe9u}},
    {26, {0x9100e260u, 0x14000000u, 0xf9412ae0u, 0x14000000u, 0xa9424ff4u, 0x910103ffu, 0xd65f03c0u, 0xaa1403e1u}},
    {30, {0xb9400828u, 0x7100110au, 0x54000b2bu, 0xd10183ffu, 0xa90357f6u, 0xa9044ff4u, 0xa9057bfdu, 0x910143fdu}},
};

static uint32_t norm(uint32_t w) {
    return (w & 0x7c000000u) == 0x14000000u ? w & 0xfc000000u : w;
}

static bool do_fingerprint(Span code, size_t offset) {
    if (sizeof(kBody) > code.size - offset) return false;
    for (size_t i = 0; i < 33; ++i) {
        uint32_t w;
        memcpy(&w, code.bytes + offset + i * 4, 4);
        if (norm(w) != norm(kBody[i])) return false;
        if ((kBody[i] & 0x7c000000u) == 0x14000000u) {
            int64_t delta = kBody[i] & 0x03ffffffu;
            if (delta & 0x02000000) delta -= 0x04000000;
            int64_t dst = (int64_t)i * 4 + delta * 4;
            if (dst >= 0 && dst < (int64_t)sizeof(kBody) && w != kBody[i]) return false;
        }
    }
    for (size_t i = 0; i < sizeof(kBranches) / sizeof(kBranches[0]); ++i) {
        const BranchFP& b = kBranches[i];
        uint32_t instr;
        memcpy(&instr, code.bytes + offset + b.index * 4, 4);
        int64_t delta = instr & 0x03ffffffu;
        if (delta & 0x02000000) delta -= 0x04000000;
        int64_t dst = (int64_t)offset + b.index * 4 + delta * 4;
        if (dst < 0 || (uint64_t)dst > code.size || 32 > code.size - (size_t)dst) return false;
        // Words a verificar por branch (del switch de JadedFix)
        size_t count = 8;
        switch (b.index) {
        case 5: case 7:            count = 6; break;
        case 12:                   count = 7; break;
        case 15:                   count = 4; break;
        case 16:                   count = 3; break;
        case 17: case 19: case 20: count = (b.index == 17) ? 6u : 5u; break;
        case 25:                   count = 3; break;
        case 26:                   count = 2; break;
        default: break;
        }
        for (size_t j = 0; j < count; ++j) {
            uint32_t w;
            memcpy(&w, code.bytes + (size_t)dst + j * 4, 4);
            uint32_t expected = b.words[j], mask = 0xffffffffu;
            if ((expected & 0x9f000000u) == 0x90000000u) {
                mask = 0x9f00001fu; // ADRP: ignorar page offset
            } else if (j && ((b.words[j-1] & 0x9f000000u) == 0x90000000u) &&
                       ((expected & 0xffc00000u) == 0xf9400000u)) {
                mask = 0xffc003ffu; // LDR offset tras ADRP relocado
            } else if (b.index == 7 && j == 1) {
                // virtual dispatch slot: mismo receptor, byte offset entre 8 y 0x1000
                unsigned byteOff = ((w >> 10) & 0xfffu) * 8u;
                if (byteOff < 8 || byteOff > 0x1000) return false;
                mask = 0xffc003ffu;
            }
            if ((norm(w) & mask) != (expected & mask)) return false;
        }
    }
    return true;
}

// Encuentra exactamente una funcion matchando el fingerprint y un slot
// en __DATA_CONST que apunte a ella. Falla si hay 0 o >1 coincidencias.
static bool do_resolve(Span code, Span constants, uintptr_t* target, uintptr_t* slot) {
    *target = *slot = 0;
    if (code.size < sizeof(kBody)) return false;

    size_t foundOff = 0;
    unsigned bodies = 0;
    for (size_t off = 0; off <= code.size - sizeof(kBody); off += 4) {
        uint32_t first;
        memcpy(&first, code.bytes + off, 4);
        if (first == kBody[0] && do_fingerprint(code, off)) {
            foundOff = off;
            if (++bodies > 1) return false;
        }
    }
    if (bodies != 1) return false;

    uintptr_t candidate = code.address + foundOff;
    unsigned slots = 0;
    for (size_t off = 0; off + sizeof(uintptr_t) <= constants.size; off += sizeof(uintptr_t)) {
        uintptr_t val;
        memcpy(&val, constants.bytes + off, sizeof(val));
        if (val == candidate) {
            if (++slots > 1) return false;
            *slot = constants.address + off;
        }
    }
    if (slots != 1) return false;
    *target = candidate;
    return true;
}

typedef int (*ReportFn)(void*, uint32_t, const void*, uint32_t);
static ReportFn           g_orig{nullptr};
static uintptr_t*         g_slot{nullptr};
static std::atomic<bool>  g_installed{false};

static int compat_hook(void* self, uint32_t type, const void* data, uint32_t flag) {
    if (flag == 1 && (type == 5 || type == 19 || type == 23 || type == 49))
        return 1;
    return g_orig(self, type, data, flag);
}

static bool swap_slot(uintptr_t expected, uintptr_t replacement) {
    vm_address_t region = (vm_address_t)g_slot;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &regionSize,
                                     VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                     &infoCount, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (kr != KERN_SUCCESS) return false;
    if ((uintptr_t)g_slot < region ||
        (uintptr_t)g_slot + sizeof(uintptr_t) > region + regionSize) return false;
    vm_address_t page = (uintptr_t)g_slot & ~((uintptr_t)vm_page_size - 1);
    kr = vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return false;
    uintptr_t cur = expected;
    bool ok = __atomic_compare_exchange_n(g_slot, &cur, replacement, false,
                                          __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection);
    return ok;
}

} // namespace

namespace fndiag {

void install_compat_report() {
    const auto* h = reinterpret_cast<const struct mach_header_64*>(_dyld_get_image_header(0));
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64) {
        log_line("[CompatReport] unexpected image header, skip");
        return;
    }
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t base = reinterpret_cast<uintptr_t>(h);

    // UUID del build original de JadedFix para fast path; en builds distintos cae al scanner.
    static const uint8_t kKnownUUID[16] = {
        0xe4,0x03,0x51,0xab, 0x50,0xa4,0x3f,0x3e,
        0xb3,0x2b,0xa0,0x7a, 0x31,0x1d,0x9b,0x73,
    };

    Span code{}, constants{};
    bool uuidMatch = false;
    const auto* p   = reinterpret_cast<const uint8_t*>(h + 1);
    const auto* end = p + h->sizeofcmds;

    for (uint32_t i = 0; i < h->ncmds && p + sizeof(struct load_command) <= end; ++i) {
        const auto* lc = reinterpret_cast<const struct load_command*>(p);
        if (lc->cmdsize < sizeof(*lc) || p + lc->cmdsize > end) return;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command))
            uuidMatch = !memcmp(reinterpret_cast<const struct uuid_command*>(lc)->uuid,
                                kKnownUUID, 16);
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const auto* seg = reinterpret_cast<const struct segment_command_64*>(lc);
            if ((seg->initprot & VM_PROT_READ) && seg->vmsize <= SIZE_MAX) {
                uintptr_t addr = seg->vmaddr + (uintptr_t)slide;
                Span s{reinterpret_cast<const uint8_t*>(addr), (size_t)seg->vmsize, addr};
                if (!strncmp(seg->segname, "__TEXT", 16) && (seg->initprot & VM_PROT_EXECUTE))
                    code = s;
                else if (!strncmp(seg->segname, "__DATA_CONST", 16))
                    constants = s;
            }
        }
        p += lc->cmdsize;
    }

    if (!code.bytes || !constants.bytes) {
        log_line("[CompatReport] segments missing, skip");
        return;
    }

    uintptr_t target = 0, slotAddr = 0;
    if (uuidMatch) {
        target   = base + 0x74c1334;
        slotAddr = base + 0xcd32e18;
        bool rangeOk = (target   >= code.address && target   - code.address < code.size) &&
                       (slotAddr >= constants.address &&
                        slotAddr - constants.address + sizeof(uintptr_t) <= constants.size);
        if (!rangeOk || !do_fingerprint(code, target - code.address)) {
            log_line("[CompatReport] UUID match pero offsets/fingerprint invalidos, usando scanner");
            target = slotAddr = 0;
        } else {
            log_line("[CompatReport] UUID fast-path: target=0x%lx slot=0x%lx",
                     (unsigned long)(target - base), (unsigned long)(slotAddr - base));
        }
    }

    if (!target) {
        log_line("[CompatReport] escaneando __TEXT (puede tardar ~100ms en binarios grandes)...");
        if (!do_resolve(code, constants, &target, &slotAddr)) {
            log_line("[CompatReport] resolver fallido: build desconocido o fingerprint cambio");
            return;
        }
        log_line("[CompatReport] resolver: target=+0x%lx slot=+0x%lx",
                 (unsigned long)(target - base), (unsigned long)(slotAddr - base));
    }

    g_slot = reinterpret_cast<uintptr_t*>(slotAddr);
    if (*g_slot != target) {
        log_line("[CompatReport] slot value mismatch (ya parchado o slot incorrecto)");
        g_slot = nullptr;
        return;
    }
    g_orig = reinterpret_cast<ReportFn>(target);

    if (swap_slot(target, reinterpret_cast<uintptr_t>(compat_hook))) {
        g_installed.store(true, std::memory_order_release);
        log_line("[CompatReport] instalado (tipos 5/19/23/49 flag=1 suprimidos)");
    } else {
        log_line("[CompatReport] vm_protect/CAS fallido");
        g_slot = nullptr;
    }
}

} // namespace fndiag
