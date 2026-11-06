#import "metadata/DeviceSpoof.hpp"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <errno.h>
#include "core/Logger.hpp"
#include "hooks/ObjcUtil.hpp"

typedef void (*MSHookFunction_t)(void* symbol, void* replace, void** result);
static MSHookFunction_t MSHookFunction = NULL;

// -----------------------------------------------------------------------
// Hardware profile: maps real Mac CPU/RAM to an internally-consistent
// iOS device fingerprint so each user presents a different identity.
// All numeric sysctl values are stored as their native binary types.
// -----------------------------------------------------------------------
struct iOSDeviceProfile {
    const char* machine;           // hw.machine / utsname.machine
    const char* model;             // hw.model (board ID)
    uint64_t    memsize;           // hw.memsize
    const char* osversion;         // kern.osversion
    const char* osproductversion;  // kern.osproductversion
    int32_t     cpufamily;         // hw.cpufamily (ARM CPU family)
    int32_t     cpusubtype;        // hw.cpusubtype
    int32_t     physicalcpu;       // hw.physicalcpu / hw.logicalcpu
    int32_t     perflevel0_phys;   // hw.perflevel0.physicalcpu (P-cores)
    int32_t     perflevel1_phys;   // hw.perflevel1.physicalcpu (E-cores)
    const char* uname_release;     // utsname.release
};

// ARM CPU family IDs (from XNU osfmk/mach/machine.h)
#define CF_ARM_AVALANCHE  ((int32_t)0x1777d680)  // A15 / M2
#define CF_ARM_EVEREST    ((int32_t)0xda33d83d)  // A16 / M2 Pro
#define CF_ARM_FATIGUE    ((int32_t)0xfa33d83d)  // M4 (approximate)

static const iOSDeviceProfile kProfiles[] = {
    // 0 - iPhone 14 A15: old Intel Macs or <= 4 logical CPUs
    { "iPhone14,7", "J173AP", 4294967296ULL,
      "21E236", "17.4.1", CF_ARM_AVALANCHE, 0x2, 6, 2, 4, "23.4.0" },
    // 1 - iPhone 15 A16: M1/M2/M3 base with <= 8GB
    { "iPhone15,4", "D27AP",  6442450944ULL,
      "21F79",  "17.5",   CF_ARM_EVEREST,   0x2, 6, 2, 4, "23.5.0" },
    // 2 - iPad Pro 11" M2: M1/M2/M3 base with > 8GB, or 8-core machines
    { "iPad14,3",   "J617AP", 8589934592ULL,
      "21G93",  "17.6",   CF_ARM_EVEREST,   0x2, 8, 4, 4, "23.6.0" },
    // 3 - iPad Pro 11" M2 16GB: M1 Pro / M2 Pro (10-12 cores)
    { "iPad14,4",   "J618AP", 17179869184ULL,
      "21H116", "17.6.1", CF_ARM_EVEREST,   0x2, 8, 4, 4, "23.6.0" },
    // 4 - iPad Pro 11" M4: M3 Max / M4 Pro (> 12 cores)
    { "iPad16,3",   "J717AP", 17179869184ULL,
      "22A3354","18.0",   CF_ARM_FATIGUE,   0x2, 10, 4, 6, "24.0.0" },
};

static iOSDeviceProfile g_profile;

// Reads real Mac sysctl values BEFORE hooks are installed to pick a profile.
static void deriveDeviceProfile(void) {
    int     ncpu    = 4;
    uint64_t memraw = 8589934592ULL;
    size_t sz;

    sz = sizeof(ncpu);   sysctlbyname("hw.ncpu",    &ncpu,   &sz, NULL, 0);
    sz = sizeof(memraw); sysctlbyname("hw.memsize", &memraw, &sz, NULL, 0);

    size_t idx;
    if      (ncpu <= 4)                                 idx = 0;
    else if (ncpu <= 8 && memraw <= 8589934592ULL)      idx = 1;
    else if (ncpu <= 8)                                 idx = 2;
    else if (ncpu <= 12)                                idx = 3;
    else                                                idx = 4;

    g_profile = kProfiles[idx];
    LOG_I("Spoof", "hw derive: ncpu=%d mem=%lluGB -> %s",
          ncpu, (unsigned long long)(memraw >> 30), g_profile.machine);
}

static const char* kJbPaths[] = {
    "/Applications/Cydia.app", "/Library/MobileSubstrate", "/var/jb",
    "/usr/sbin/sshd", "/private/var/lib/apt", "/bin/bash",
    "/usr/bin/ssh", "/etc/apt", "/private/var/lib/cydia",
    "/var/cache/apt", "/var/lib/dpkg"
};

static bool isJailbreakPath(const char* path) {
    if (!path) return false;
    for (size_t i = 0; i < sizeof(kJbPaths)/sizeof(kJbPaths[0]); i++)
        if (strstr(path, kJbPaths[i])) return true;
    return false;
}

typedef OSStatus (*SecTrustEvaluateFn)(SecTrustRef, SecTrustResultType*);
static SecTrustEvaluateFn orig_SecTrustEvaluate = NULL;
static OSStatus h_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType* result) {
    (void)trust;
    if (result) *result = kSecTrustResultProceed;
    return errSecSuccess;
}

typedef bool (*SecTrustEvaluateWithErrorFn)(SecTrustRef, CFErrorRef*);
static SecTrustEvaluateWithErrorFn orig_SecTrustEvaluateWithError = NULL;
static bool h_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef* error) {
    (void)trust;
    if (error) *error = NULL;
    return true;
}

static uint32_t (*orig_dyld_image_count)(void) = NULL;
static uint32_t h_dyld_image_count(void) {
    uint32_t n = orig_dyld_image_count ? orig_dyld_image_count() : 0;
    return n > 0 ? n - 1 : 0;
}

static int (*orig_dladdr)(const void*, Dl_info*) = NULL;
static int h_dladdr(const void* addr, Dl_info* info) {
    int r = orig_dladdr ? orig_dladdr(addr, info) : -1;
    if (r && info && info->dli_fname) {
        const char* f = info->dli_fname;
        if (strstr(f, "FnMac") || strstr(f, "SpoofLog") || strstr(f, "HookManager")) {
            info->dli_fname = "/usr/lib/libSystem.B.dylib";
            info->dli_sname = NULL;
        }
    }
    return r;
}

static const char* (*orig_dyld_get_image_name)(uint32_t) = NULL;
static const char* h_dyld_get_image_name(uint32_t idx) {
    const char* n = orig_dyld_get_image_name ? orig_dyld_get_image_name(idx) : NULL;
    if (n && (strstr(n, "FnMac") || strstr(n, "SpoofLog") || strstr(n, "HookManager")))
        return "/usr/lib/libSystem.B.dylib";
    return n;
}

static char* (*orig_getenv)(const char*) = NULL;
static char* h_getenv(const char* name) {
    if (name && (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
                 strcmp(name, "DYLD_FORCE_FLAT_NAMESPACE") == 0))
        return NULL;
    return orig_getenv ? orig_getenv(name) : NULL;
}

typedef int (*sysctlbyname_t)(const char*, void*, size_t*, void*, size_t);
static sysctlbyname_t orig_sysctlbyname = NULL;

// Writes binary value to oldp, returns 0 on success or fills *oldlenp with required size.
static int sctl_u64(void* oldp, size_t* oldlenp, uint64_t val) {
    if (!oldlenp) return -1;
    if (!oldp) { *oldlenp = sizeof(uint64_t); return 0; }
    if (*oldlenp < sizeof(uint64_t)) { *oldlenp = sizeof(uint64_t); return ENOMEM; }
    memcpy(oldp, &val, sizeof(uint64_t)); *oldlenp = sizeof(uint64_t); return 0;
}
static int sctl_i32(void* oldp, size_t* oldlenp, int32_t val) {
    if (!oldlenp) return -1;
    if (!oldp) { *oldlenp = sizeof(int32_t); return 0; }
    if (*oldlenp < sizeof(int32_t)) { *oldlenp = sizeof(int32_t); return ENOMEM; }
    memcpy(oldp, &val, sizeof(int32_t)); *oldlenp = sizeof(int32_t); return 0;
}
static int sctl_str(void* oldp, size_t* oldlenp, const char* val) {
    if (!oldlenp || !val) return -1;
    size_t len = strlen(val) + 1;
    if (!oldp) { *oldlenp = len; return 0; }
    if (*oldlenp < len) { *oldlenp = len; return ENOMEM; }
    memcpy(oldp, val, len); *oldlenp = len; return 0;
}

static int h_sysctlbyname(const char* name, void* oldp, size_t* oldlenp, void* newp, size_t newlen) {
    if (name) {
        const iOSDeviceProfile& p = g_profile;
        if (!strcmp(name, "hw.machine"))                    return sctl_str(oldp, oldlenp, p.machine);
        if (!strcmp(name, "hw.model"))                      return sctl_str(oldp, oldlenp, p.model);
        if (!strcmp(name, "hw.product"))                    return sctl_str(oldp, oldlenp, p.machine);
        if (!strcmp(name, "hw.memsize"))                    return sctl_u64(oldp, oldlenp, p.memsize);
        if (!strcmp(name, "kern.osversion"))                return sctl_str(oldp, oldlenp, p.osversion);
        if (!strcmp(name, "kern.osproductversion"))         return sctl_str(oldp, oldlenp, p.osproductversion);
        if (!strcmp(name, "hw.cpufamily"))                  return sctl_i32(oldp, oldlenp, p.cpufamily);
        if (!strcmp(name, "hw.cpusubtype"))                 return sctl_i32(oldp, oldlenp, p.cpusubtype);
        if (!strcmp(name, "hw.physicalcpu"))                return sctl_i32(oldp, oldlenp, p.physicalcpu);
        if (!strcmp(name, "hw.logicalcpu"))                 return sctl_i32(oldp, oldlenp, p.physicalcpu);
        if (!strcmp(name, "hw.perflevel0.physicalcpu"))     return sctl_i32(oldp, oldlenp, p.perflevel0_phys);
        if (!strcmp(name, "hw.perflevel1.physicalcpu"))     return sctl_i32(oldp, oldlenp, p.perflevel1_phys);
        if (!strcmp(name, "kern.securekernel"))             return sctl_i32(oldp, oldlenp, 1);
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}

typedef int (*sysctl_t)(int*, u_int, void*, size_t*, void*, size_t);
static sysctl_t orig_sysctl = NULL;
static int h_sysctl(int* name, u_int namelen, void* oldp, size_t* oldlenp, void* newp, size_t newlen) {
    if (name && namelen == 4 && name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_ALL)
        return -1;
    if (name && namelen == 2 && name[0] == CTL_HW) {
        const iOSDeviceProfile& p = g_profile;
        if (name[1] == HW_MEMSIZE)  return sctl_u64(oldp, oldlenp, p.memsize);
        if (name[1] == HW_MACHINE)  return sctl_str(oldp, oldlenp, p.machine);
        if (name[1] == HW_NCPU)     return sctl_i32(oldp, oldlenp, p.physicalcpu);
    }
    return orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
}

typedef int (*uname_t)(struct utsname*);
static uname_t orig_uname = NULL;
static int h_uname(struct utsname* info) {
    int r = orig_uname ? orig_uname(info) : -1;
    if (r == 0 && info) {
        strlcpy(info->machine, g_profile.machine,       sizeof(info->machine));
        strlcpy(info->release, g_profile.uname_release, sizeof(info->release));
    }
    return r;
}

typedef kern_return_t (*host_stats64_t)(host_t, host_flavor_t, host_info64_t, mach_msg_type_number_t*);
static host_stats64_t orig_host_stats64 = NULL;
static kern_return_t h_host_stats64(host_t host, host_flavor_t flavor, host_info64_t info, mach_msg_type_number_t* count) {
    kern_return_t r = orig_host_stats64 ? orig_host_stats64(host, flavor, info, count) : KERN_FAILURE;
    if (r == KERN_SUCCESS && flavor == HOST_VM_INFO64 && info && *count >= HOST_VM_INFO64_COUNT) {
        vm_statistics64_data_t* v = (vm_statistics64_data_t*)info;
        const uint64_t pages = g_profile.memsize / 16384;
        v->active_count = pages / 2; v->inactive_count = pages / 4; v->free_count = pages / 4;
    }
    return r;
}

typedef int (*csops_t)(pid_t, unsigned int, void*, size_t);
static csops_t orig_csops = NULL;
static int h_csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize) {
    if (ops == 0 && useraddr && usersize >= sizeof(uint32_t)) {
        uint32_t* flags = (uint32_t*)useraddr;
        *flags = (*flags & ~0x100 & ~0x800) | 0x1;
        return 0;
    }
    return orig_csops ? orig_csops(pid, ops, useraddr, usersize) : -1;
}

static NSString* kForcedBundleId = @"com.epicgames.fortnite";

static IMP o_activeProcessorCount = NULL;
static NSUInteger h_activeProcessorCount(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return (NSUInteger)g_profile.physicalcpu;
}

static IMP o_deviceModel = NULL;
static NSString* h_deviceModel(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    // Macs with iPhone profiles report "iPhone"; iPad profiles report "iPad"
    return (strncmp(g_profile.machine, "iPhone", 6) == 0) ? @"iPhone" : @"iPad";
}

static IMP o_systemName = NULL;
static NSString* h_systemName(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return (strncmp(g_profile.machine, "iPhone", 6) == 0) ? @"iPhone OS" : @"iPadOS";
}

static IMP o_systemVersion = NULL;
static NSString* h_systemVersion(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSString stringWithUTF8String:g_profile.osproductversion];
}

static IMP o_bundleIdentifier = NULL;
static NSString* h_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) return kForcedBundleId;
    if (!o_bundleIdentifier) return kForcedBundleId;
    return ((NSString* (*)(id, SEL))o_bundleIdentifier)(self, _cmd);
}

static void h_checkExpectedBundleID(id self, SEL _cmd, id arg1) { (void)self; (void)_cmd; (void)arg1; }

static IMP o_FIROptions_bundleID = NULL;
static NSString* h_FIROptions_bundleID(id self, SEL _cmd) { (void)self; (void)_cmd; return kForcedBundleId; }

static IMP o_backgroundRefreshStatus = NULL;
static NSInteger h_backgroundRefreshStatus(id self, SEL _cmd) { (void)self; (void)_cmd; return 1; }

static IMP o_fileExistsAtPath = NULL;
static BOOL h_fileExistsAtPath(id self, SEL _cmd, NSString* path) {
    if (isJailbreakPath([path UTF8String])) return NO;
    return ((BOOL (*)(id, SEL, NSString*))o_fileExistsAtPath)(self, _cmd, path);
}
static IMP o_fileExistsAtPathIsDirectory = NULL;
static BOOL h_fileExistsAtPathIsDirectory(id self, SEL _cmd, NSString* path, BOOL* isDir) {
    if (isJailbreakPath([path UTF8String])) return NO;
    return ((BOOL (*)(id, SEL, NSString*, BOOL*))o_fileExistsAtPathIsDirectory)(self, _cmd, path, isDir);
}

void installSpoofHooks(void) {
    @autoreleasepool {
        deriveDeviceProfile();   // must run before any hook reads g_profile

        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("DYLD_FORCE_FLAT_NAMESPACE");

        void* handle = dlopen(NULL, RTLD_NOW);
        MSHookFunction = (MSHookFunction_t)dlsym(handle, "MSHookFunction");
        if (!MSHookFunction) {
            void* substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (!substrate) substrate = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
            if (substrate) MSHookFunction = (MSHookFunction_t)dlsym(substrate, "MSHookFunction");
        }
        LOG_I("Spoof", "MSHookFunction: %s", MSHookFunction ? "ok" : "no disponible");

        if (MSHookFunction) {
            void* syms[] = {
                dlsym(RTLD_DEFAULT, "sysctlbyname"),
                dlsym(RTLD_DEFAULT, "sysctl"),
                dlsym(RTLD_DEFAULT, "uname"),
                dlsym(RTLD_DEFAULT, "dladdr"),
                dlsym(RTLD_DEFAULT, "_dyld_image_count"),
                dlsym(RTLD_DEFAULT, "_dyld_get_image_name"),
                dlsym(RTLD_DEFAULT, "getenv"),
                dlsym(RTLD_DEFAULT, "host_statistics64"),
                dlsym(RTLD_DEFAULT, "csops"),
#if !TARGET_OS_SIMULATOR
                dlsym(RTLD_DEFAULT, "SecTrustEvaluate"),
                dlsym(RTLD_DEFAULT, "SecTrustEvaluateWithError"),
#endif
            };
            void* repls[] = {
                (void*)h_sysctlbyname,
                (void*)h_sysctl,
                (void*)h_uname,
                (void*)h_dladdr,
                (void*)h_dyld_image_count,
                (void*)h_dyld_get_image_name,
                (void*)h_getenv,
                (void*)h_host_stats64,
                (void*)h_csops,
#if !TARGET_OS_SIMULATOR
                (void*)h_SecTrustEvaluate,
                (void*)h_SecTrustEvaluateWithError,
#endif
            };
            void** origs[] = {
                (void**)&orig_sysctlbyname,
                (void**)&orig_sysctl,
                (void**)&orig_uname,
                (void**)&orig_dladdr,
                (void**)&orig_dyld_image_count,
                (void**)&orig_dyld_get_image_name,
                (void**)&orig_getenv,
                (void**)&orig_host_stats64,
                (void**)&orig_csops,
#if !TARGET_OS_SIMULATOR
                (void**)&orig_SecTrustEvaluate,
                (void**)&orig_SecTrustEvaluateWithError,
#endif
            };
            const size_t n = sizeof(syms) / sizeof(syms[0]);
            for (size_t i = 0; i < n; i++)
                if (syms[i] && repls[i] && origs[i])
                    MSHookFunction(syms[i], repls[i], origs[i]);
        }

        using fndiag::objc::swizzle;
        swizzle(NSClassFromString(@"NSProcessInfo"), @selector(activeProcessorCount), (IMP)h_activeProcessorCount, &o_activeProcessorCount);
        swizzle(NSClassFromString(@"UIDevice"),      @selector(model),                (IMP)h_deviceModel,          &o_deviceModel);
        swizzle(NSClassFromString(@"UIDevice"),      @selector(systemName),           (IMP)h_systemName,           &o_systemName);
        swizzle(NSClassFromString(@"UIDevice"),      @selector(systemVersion),        (IMP)h_systemVersion,        &o_systemVersion);
        swizzle(NSClassFromString(@"NSBundle"),      @selector(bundleIdentifier),     (IMP)h_bundleIdentifier,     &o_bundleIdentifier);

        Class firApp = NSClassFromString(@"FIRApp");
        if (firApp) {
            Method m = class_getClassMethod(firApp, @selector(checkExpectedBundleID:));
            if (m) method_setImplementation(m, (IMP)h_checkExpectedBundleID);
        }
        swizzle(NSClassFromString(@"FIROptions"),    @selector(bundleID),             (IMP)h_FIROptions_bundleID,         &o_FIROptions_bundleID);
        swizzle(NSClassFromString(@"UIApplication"), @selector(backgroundRefreshStatus), (IMP)h_backgroundRefreshStatus, &o_backgroundRefreshStatus);

        Class nsfm = NSClassFromString(@"NSFileManager");
        swizzle(nsfm, @selector(fileExistsAtPath:),             (IMP)h_fileExistsAtPath,            &o_fileExistsAtPath);
        swizzle(nsfm, @selector(fileExistsAtPath:isDirectory:), (IMP)h_fileExistsAtPathIsDirectory, &o_fileExistsAtPathIsDirectory);

        LOG_I("Spoof", "Hooks de dispositivo/bundle/JB instalados");
    }
}
