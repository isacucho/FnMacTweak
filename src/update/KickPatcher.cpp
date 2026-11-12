#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace fndiag {

// ============================================================
// Validation Patch (solucion Jaded)
// Suprime la validacion sideload/JIT parcheando dos slots vtable
// en __DATA_CONST. El stub devuelve 0 sin llegar al dispatch de kick.
//
// Para anadir una version nueva:
//   1. Compilar el binario de la IPA nueva
//   2. Buscar las funciones con el patron MOVZ W19,#0 + 0x30 -> MOVZ W8,#{6,10}
//   3. Buscar los vtable pointers que apuntan a esas funciones
//   4. Anadir una entrada en kVersionTable con el build_id del CFBundleVersion
// ============================================================

struct VersionOffsets {
    uint32_t  build_id;
    uintptr_t vtable1_off;  // slot reason=10
    uintptr_t fn1_off;
    uintptr_t vtable2_off;  // slot reason=6
    uintptr_t fn2_off;
};

static const VersionOffsets kVersionTable[] = {
    { 59596594, 0xcd32e18, 0x74c1334, 0xcd32df8, 0x74c13b8 }, // 43.00
    { 60278837, 0xce5ad38, 0x7571028, 0xce5acd8, 0x75710ac }, // 43.10
};

static uint32_t read_bundle_build_id() {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return 0;
    CFStringRef ver = (CFStringRef)CFBundleGetValueForInfoDictionaryKey(
        bundle, CFSTR("CFBundleVersion"));
    if (!ver || CFGetTypeID(ver) != CFStringGetTypeID()) return 0;
    char buf[32];
    if (!CFStringGetCString(ver, buf, sizeof(buf), kCFStringEncodingUTF8)) return 0;
    return (uint32_t)strtoul(buf, nullptr, 10);
}

static uintptr_t validation_pass_stub(void* /*self*/, uintptr_t, uintptr_t, uintptr_t) {
    return 0;
}

static bool patch_vtable_entry(mach_vm_address_t va, uintptr_t expected, uintptr_t replacement) {
    uintptr_t current = *reinterpret_cast<volatile uintptr_t*>(va);
    if (current != expected) {
        log_line("[ValidationPatch]   skip vtable[0x%lx]: val=0x%lx != expected=0x%lx",
                 (long)va, (long)current, (long)expected);
        return false;
    }

    // 16KB page on Apple Silicon
    mach_vm_address_t page = va & ~((mach_vm_address_t)0x3FFF);
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[ValidationPatch]   vm_protect(rw) FAIL kr=%d va=0x%lx", kr, (long)va);
        return false;
    }

    *reinterpret_cast<volatile uintptr_t*>(va) = replacement;
    __asm__ volatile("dmb ish" ::: "memory");

    vm_protect(mach_task_self(), static_cast<vm_address_t>(page), 0x4000, false, VM_PROT_READ);
    return true;
}

void install_validation_patch() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) { log_line("[ValidationPatch] no image header"); return; }
    uintptr_t base = reinterpret_cast<uintptr_t>(mh);

    uint32_t build_id = read_bundle_build_id();
    log_line("[ValidationPatch] build_id=%u", build_id);

    const VersionOffsets* offs = nullptr;
    for (size_t i = 0; i < sizeof(kVersionTable) / sizeof(kVersionTable[0]); ++i) {
        if (kVersionTable[i].build_id == build_id) {
            offs = &kVersionTable[i];
            break;
        }
    }

    if (!offs) {
        log_line("[ValidationPatch] version desconocida build_id=%u -- anadir entrada en kVersionTable",
                 build_id);
        return;
    }

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(validation_pass_stub);

    uintptr_t orig1 = base + offs->fn1_off;
    bool ok1 = patch_vtable_entry(base + offs->vtable1_off, orig1, stub_va);

    uintptr_t orig2 = base + offs->fn2_off;
    bool ok2 = patch_vtable_entry(base + offs->vtable2_off, orig2, stub_va);

    log_line("[ValidationPatch] slot1(r=10)=%s slot2(r=6)=%s stub=0x%lx orig1=0x%lx orig2=0x%lx",
             ok1 ? "ok" : "FAIL", ok2 ? "ok" : "FAIL",
             (long)stub_va, (long)orig1, (long)orig2);
}

} // namespace fndiag
