#include "FnKBMPatch.h"
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <Foundation/Foundation.h>
#endif

_Static_assert(sizeof(vm_address_t) == sizeof(uintptr_t), "Native patching requires a 64-bit VM API");

// All scanners below operate on checked offsets; no instruction is executed.
typedef struct { uint64_t address, size; size_t offset; } Section;
typedef struct {
    const uint8_t *bytes; size_t length; uint64_t base;
    Section text, strings;
    struct { uint64_t address, size; vm_prot_t protection; } segments[128];
    size_t segmentCount;
} Image;

static bool fail(FnKBMResult *r, FnKBMStatus s, const char *format, ...) {
    if (r) {
        memset(r, 0, sizeof(*r)); r->status = s;
        va_list ap; va_start(ap, format); vsnprintf(r->detail, sizeof(r->detail), format, ap); va_end(ap);
    }
    return false;
}
static bool span(uint64_t offset, uint64_t size, uint64_t length) { return offset <= length && size <= length - offset; }
static uint32_t word(const void *p) { uint32_t w; memcpy(&w, p, 4); return w; }
static bool nameIs(const char name[16], const char *s) { return strncmp(name, s, 16) == 0; }
static bool addSigned(uint64_t a, int64_t b, uint64_t *out) {
    if (b < 0) { uint64_t n = (uint64_t)(-(b + 1)) + 1; if (a < n) return false; *out = a - n; }
    else { if (UINT64_MAX - a < (uint64_t)b) return false; *out = a + (uint64_t)b; }
    return true;
}
static int64_t signExtend(uint32_t n, unsigned bits) { return (n & (1u << (bits - 1))) ? (int64_t)n - (1LL << bits) : n; }

// headerLength is separately bounded for the sparse loaded-image case.
static bool parse(const void *bytes, size_t headerLength, size_t length, FnKBMImageLayout layout, Image *im, FnKBMResult *r) {
    memset(im, 0, sizeof(*im)); im->bytes = bytes; im->length = length;
    if (!bytes || headerLength < sizeof(struct mach_header_64)) return fail(r, FnKBMStatusUnsupported, "Mach-O header is truncated");
    struct mach_header_64 h; memcpy(&h, bytes, sizeof(h));
    if (h.magic != MH_MAGIC_64 || h.cputype != CPU_TYPE_ARM64 || h.filetype != MH_EXECUTE ||
        h.ncmds > 65536 || h.sizeofcmds > 16u * 1024u * 1024u || !span(sizeof(h), h.sizeofcmds, headerLength))
        return fail(r, FnKBMStatusUnsupported, "Expected a bounded thin ARM64 executable Mach-O");
    size_t cursor = sizeof(h), end = cursor + h.sizeofcmds;
    bool baseFound = false, textFound = false, stringsFound = false;
    // Pass one establishes the preferred image base and segment bounds.
    for (uint32_t i = 0; i < h.ncmds; i++) {
        if (!span(cursor, sizeof(struct load_command), end)) return fail(r, FnKBMStatusUnsupported, "Truncated load command");
        struct load_command lc; memcpy(&lc, im->bytes + cursor, sizeof(lc));
        if (lc.cmdsize < sizeof(lc) || (lc.cmdsize & 7) || !span(cursor, lc.cmdsize, end)) return fail(r, FnKBMStatusUnsupported, "Invalid load command size");
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 s;
            if (lc.cmdsize < sizeof(s)) return fail(r, FnKBMStatusUnsupported, "Truncated segment");
            memcpy(&s, im->bytes + cursor, sizeof(s));
            if (s.nsects > (lc.cmdsize - sizeof(s)) / sizeof(struct section_64) || s.filesize > s.vmsize ||
                s.vmaddr > UINT64_MAX - s.vmsize || im->segmentCount == 128 ||
                (layout == FnKBMImageFile && !span(s.fileoff, s.filesize, length))) return fail(r, FnKBMStatusUnsupported, "Invalid segment bounds");
            im->segments[im->segmentCount].address = s.vmaddr;
            im->segments[im->segmentCount].size = s.vmsize;
            im->segments[im->segmentCount++].protection = s.initprot;
            if (nameIs(s.segname, "__TEXT")) {
                if (baseFound || s.fileoff || !s.filesize) return fail(r, FnKBMStatusUnsupported, "Ambiguous __TEXT segment");
                im->base = s.vmaddr; baseFound = true;
            }
        }
        cursor += lc.cmdsize;
    }
    if (cursor != end || !baseFound) return fail(r, FnKBMStatusUnsupported, "Invalid command table or missing __TEXT");
    cursor = sizeof(h);
    for (uint32_t i = 0; i < h.ncmds; i++) {
        struct load_command lc; memcpy(&lc, im->bytes + cursor, sizeof(lc));
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 s; memcpy(&s, im->bytes + cursor, sizeof(s));
            for (uint32_t j = 0; j < s.nsects; j++) {
                struct section_64 sec; memcpy(&sec, im->bytes + cursor + sizeof(s) + j * sizeof(sec), sizeof(sec));
                bool isText = nameIs(sec.sectname, "__text"), isStrings = nameIs(sec.sectname, "__ustring");
                if (!isText && !isStrings) continue;
                if (!nameIs(sec.segname, "__TEXT") || !nameIs(s.segname, "__TEXT") ||
                    sec.addr < s.vmaddr || !span(sec.addr - s.vmaddr, sec.size, s.vmsize) ||
                    sec.offset < s.fileoff || !span(sec.offset - s.fileoff, sec.size, s.filesize) ||
                    sec.addr - s.vmaddr != sec.offset - s.fileoff || !(s.initprot & VM_PROT_READ) ||
                    (isText && (!(s.initprot & VM_PROT_EXECUTE) || (sec.addr & 3) || (sec.size & 3))))
                    return fail(r, FnKBMStatusUnsupported, "Invalid code/string section mapping");
                uint64_t offset = layout == FnKBMImageFile ? sec.offset : sec.addr - im->base;
                if (offset > SIZE_MAX || !sec.size || !span(offset, sec.size, length)) return fail(r, FnKBMStatusUnsupported, "Section extends beyond supplied image");
                Section v = {sec.addr, sec.size, (size_t)offset};
                if (isText) { if (textFound) return fail(r, FnKBMStatusUnsupported, "Duplicate __text"); im->text = v; textFound = true; }
                else { if (stringsFound) return fail(r, FnKBMStatusUnsupported, "Duplicate __ustring"); im->strings = v; stringsFound = true; }
            }
        }
        cursor += lc.cmdsize;
    }
    if (!textFound || !stringsFound) return fail(r, FnKBMStatusUnsupported, "Missing __text or __ustring");
    if (im->text.offset < im->strings.offset + im->strings.size && im->strings.offset < im->text.offset + im->text.size)
        return fail(r, FnKBMStatusUnsupported, "Code and string sections overlap");
    return true;
}
static bool code(const Image *im, uint64_t pc, size_t n, size_t *off) {
    if ((pc & 3) || pc < im->text.address || !span(pc - im->text.address, n, im->text.size)) return false;
    *off = (size_t)(pc - im->text.address); return true;
}
static uint32_t insn(const Image *im, size_t off) { return word(im->bytes + im->text.offset + off); }
static bool branch(uint32_t w, uint64_t pc, bool link, uint64_t *target) {
    return (w & 0xfc000000) == (link ? 0x94000000 : 0x14000000) && addSigned(pc, signExtend(w & 0x03ffffff, 26) * 4, target);
}
static bool encodeBranch(uint64_t pc, uint64_t target, uint32_t *out) {
    if ((pc | target) & 3) return false;
    if (target >= pc) { uint64_t d = target - pc; if (d >= (1u << 27)) return false; *out = 0x14000000 | (uint32_t)(d / 4); }
    else { uint64_t d = pc - target; if (d > (1u << 27)) return false; *out = 0x14000000 | ((uint32_t)(-(int64_t)(d / 4)) & 0x03ffffff); }
    return true;
}
static bool adrp(uint32_t w, uint64_t pc, uint64_t *page) {
    uint32_t imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3);
    return (w & 0x9f000000) == 0x90000000 && addSigned(pc & ~UINT64_C(4095), signExtend(imm, 21) * 4096, page);
}
static bool literal(const Image *im, const char *ascii, uint64_t *address) {
    size_t n = strlen(ascii), found = 0;
    if (n > im->strings.size / 2) return false;
    const uint8_t *s = im->bytes + im->strings.offset;
    for (size_t i = 0; i + n * 2 <= im->strings.size; i += 2) {
        size_t j = 0; for (; j < n && s[i+j*2] == (uint8_t)ascii[j] && s[i+j*2+1] == 0; j++) {}
        if (j == n) { *address = im->strings.address + i; if (++found > 1) return false; }
    }
    return found == 1;
}
static size_t literalSites(const Image *im, uint64_t address, unsigned reg, size_t *site) {
    size_t count = 0;
    for (size_t k = 0; k + 8 <= im->text.size; k += 4) {
        uint32_t a = insn(im, k), b = insn(im, k+4); uint64_t page;
        if ((a & 31) == reg && adrp(a, im->text.address+k, &page) && page == (address & ~UINT64_C(4095)) &&
            (b & 0xffc003ff) == (0x91000000u | reg | (reg << 5)) && ((b >> 10) & 4095) == (address & 4095)) { *site = k; count++; }
    }
    return count;
}
static const uint8_t prologue[] = {0xff,0xc3,0x00,0xd1,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91,0xf3,0x03,0x03,0xaa};
static bool hasPrologue(const Image *im, size_t k) { return k >= sizeof(prologue) && memcmp(im->bytes+im->text.offset+k-sizeof(prologue), prologue, sizeof(prologue)) == 0; }
static bool addPatch(const Image *im, FnKBMPlan *p, size_t k, uint32_t replacement, bool patched, bool states[6]) {
    if (p->count >= 6 || !span(k, 4, im->text.size)) return false;
    for (size_t i = 0; i < p->count; i++) if (p->patches[i].vmAddress == im->text.address+k) return false;
    states[p->count] = patched;
    p->patches[p->count++] = (FnKBMPatch){im->text.address+k, im->text.offset+k, insn(im,k), replacement}; return true;
}
static bool writableDataAddress(const Image *im, uint64_t a) {
    for (size_t i = 0; i < im->segmentCount; i++) if ((im->segments[i].protection & VM_PROT_WRITE) &&
        !(im->segments[i].protection & VM_PROT_EXECUTE) && a >= im->segments[i].address && a-im->segments[i].address < im->segments[i].size) return true;
    return false;
}

bool FnKBMBuildPlan(const void *bytes, size_t length, FnKBMImageLayout layout, FnKBMPlan *out, FnKBMResult *r) {
    if (out) memset(out, 0, sizeof(*out));
    if (!out || (layout != FnKBMImageFile && layout != FnKBMImageMapped)) return fail(r, FnKBMStatusUnsupported, "Invalid plan arguments");
    Image im;
    if (!parse(bytes, length, length, layout, &im, r)) return false;
    FnKBMPlan p = {.preferredBase=im.base}; bool states[6] = {0};
    uint64_t mouseLiteral, mkbLiteral, tagLiteral; size_t mouse = 0, mkb = 0, tag = 0;
    if (!literal(&im, "Platform does not support mouse settings", &mouseLiteral) ||
        !literal(&im, "UFortSettingEditCondition_WhenPlatformSupportsMouseAndKeyboard", &mkbLiteral) ||
        !literal(&im, "OptionsMenu.DisplayTabs.AllowGameUITab", &tagLiteral) ||
        literalSites(&im, mouseLiteral, 1, &mouse) != 1 || literalSites(&im, tagLiteral, 2, &tag) != 1)
        return fail(r, FnKBMStatusUnsupported, "Required literals or register-correct references are not unique");
    uint64_t check, target, epilogue, trueStub = 0; size_t checkOff, targetOff, epOff;
    if (mouse < 28 || !hasPrologue(&im, mouse-8) || (insn(&im, mouse-4) & 0xfff8001f) != 0x37000000 ||
        !branch(insn(&im,mouse-8), im.text.address+mouse-8, true, &check) || !code(&im,check,4,&checkOff) ||
        !branch(insn(&im,checkOff),check,false,&target) || !code(&im,target,8,&targetOff) ||
        (insn(&im,targetOff) != 0x52800000 && insn(&im,targetOff) != 0x52800020) || insn(&im,targetOff+4) != 0xd65f03c0 ||
        !addSigned(im.text.address+mouse-4, signExtend((insn(&im,mouse-4)>>5)&0x3fff,14)*4, &epilogue) ||
        !code(&im,epilogue,8,&epOff) || insn(&im,epOff) != 0xa9427bfd ||
        !branch(insn(&im,epOff+4),epilogue+4,false,&target) || !code(&im,target,4,&targetOff))
        return fail(r, FnKBMStatusUnsupported, "Mouse check, condition frame or pass epilogue differs");
    // Target is re-read because the epilogue validation used the scratch address.
    branch(insn(&im,checkOff),check,false,&target); code(&im,target,8,&targetOff);
    bool mousePatched = insn(&im,targetOff) == 0x52800020;
    if (mousePatched) trueStub = target;
    else for (size_t k = 0; k+8 <= im.text.size; k += 4) if (insn(&im,k)==0x52800020 && insn(&im,k+4)==0xd65f03c0) { trueStub=im.text.address+k; break; }
    uint32_t replacement;
    if (!trueStub || !encodeBranch(check,trueStub,&replacement) || !addPatch(&im,&p,checkOff,replacement,mousePatched,states)) return fail(r, FnKBMStatusUnsupported, "No reachable true-return stub");
    size_t mkbCount=0;
    for (size_t k=20; k+8<=im.text.size; k+=4) {
        if (!hasPrologue(&im,k) || insn(&im,k+4)!=(0x91000021u | ((uint32_t)(mkbLiteral&4095)<<10))) continue;
        uint64_t page,t;
        bool original=(insn(&im,k)&31)==1 && adrp(insn(&im,k),im.text.address+k,&page) && page==(mkbLiteral&~UINT64_C(4095));
        bool patched=branch(insn(&im,k),im.text.address+k,false,&t) && t==epilogue;
        if (original || patched) { mkb=k; mkbCount++; }
    }
    if (mkbCount!=1 || !encodeBranch(im.text.address+mkb,epilogue,&replacement) ||
        !addPatch(&im,&p,mkb,replacement,(insn(&im,mkb)&0xfc000000)==0x14000000,states)) return fail(r, FnKBMStatusUnsupported, "Keyboard edit condition is not unique");
    // Resolve the Game UI registration's data pointer through x20.
    uint64_t cvar=0; bool argFound=false, baseFound=false; unsigned argOffset=0;
    for (size_t k=tag; k<=tag+20 && k+4<=im.text.size; k+=4) {
        uint32_t w=insn(&im,k);
        if ((w&0xffc003ff)==0x91000283) { argOffset=(w>>10)&4095; argFound=true; break; }
        if (w==0xaa1403e3) { argFound=true; break; }
    }
    for (size_t n=0; n<=200 && n*4<=tag; n++) {
        size_t k=tag-n*4; uint32_t w=insn(&im,k); uint64_t page;
        if ((w&0x9f00001f)==0x90000014 && adrp(w,im.text.address+k,&page)) {
            if (k+8>im.text.size || (insn(&im,k+4)&0xffc003ff)!=0x91000294 ||
                !addSigned(page,((insn(&im,k+4)>>10)&4095)+argOffset,&cvar)) break;
            baseFound=true; break;
        }
    }
    if (!argFound || !baseFound || !writableDataAddress(&im,cvar)) return fail(r, FnKBMStatusUnsupported, "Game UI variable registration differs");
    size_t pair=0, pairs=0;
    for (size_t k=0; k+0x48<=im.text.size; k+=4) {
        if (insn(&im,k)!=0xaa1e03e0 || insn(&im,k+8)!=0xaa0003fe ||
            (insn(&im,k+12)&0x9f00001f)!=0x90000008 || (insn(&im,k+16)&0xffc003ff)!=0x39400108) continue;
        uint64_t page,t; size_t scratch;
        if (!adrp(insn(&im,k+12),im.text.address+k+12,&page) || !addSigned(page,(insn(&im,k+16)>>10)&4095,&t) || t!=cvar ||
            !branch(insn(&im,k+4),im.text.address+k+4,true,&t) || !code(&im,t,4,&scratch) ||
            !branch(insn(&im,k+20),im.text.address+k+20,false,&t) || !code(&im,t,4,&scratch)) continue;
        bool ok=true;
        for (size_t j=0;j<2;j++) {
            size_t h=k+28+j*24;
            if (insn(&im,h)!=0xaa1e03e0 || insn(&im,h+8)!=0xaa0003fe || insn(&im,h+16)!=0xd65f03c0 ||
                !branch(insn(&im,h+4),im.text.address+h+4,true,&t) || !code(&im,t,4,&scratch) ||
                !branch(insn(&im,h-4),im.text.address+h-4,false,&t) || !code(&im,t,4,&scratch) ||
                (insn(&im,h+12)!=0x3900005f && !(branch(insn(&im,h+12),im.text.address+h+12,false,&t) && t==im.text.address+k+12))) { ok=false; break; }
        }
        if (ok) {pair=k; pairs++;}
    }
    if (pairs!=1) return fail(r, FnKBMStatusUnsupported, "Tab visibility reader/functions are not unique");
    for (size_t j=0;j<2;j++) {
        size_t k=pair+40+j*24;
        if (!encodeBranch(im.text.address+k,im.text.address+pair+12,&replacement) || !addPatch(&im,&p,k,replacement,insn(&im,k)!=0x3900005f,states)) return fail(r,FnKBMStatusUnsupported,"Invalid tab patch");
    }
    static const uint32_t signatures[2][9] = {
        {0x7100083f,0x54000100,0x7100043f,0x54000080,0x350000e1,0x39410408,0x14000006,0x39410c08,0x14000004},
        {0x71000a7f,0x540002a0,0x7100067f,0x54000080,0x35000a53,0x39410408,0,0,0}
    };
    for (size_t s=0;s<2;s++) {
        size_t n=s?6:9, found=0, match=0;
        for (size_t k=0; k+n*4<=im.text.size; k+=4) {
            bool ok=true; for(size_t j=0;j<n;j++) if (j!=5 && insn(&im,k+j*4)!=signatures[s][j]) {ok=false;break;}
            uint32_t w=insn(&im,k+20);
            if(ok && (w==0x39410408 || w==0x52800028)) {match=k;found++;}
        }
        if(found!=1 || !addPatch(&im,&p,match+20,0x52800028,insn(&im,match+20)==0x52800028,states)) return fail(r,FnKBMStatusUnsupported,"Input support switches are not unique");
    }
    bool any=false, all=true; for(size_t i=0;i<6;i++){any|=states[i];all&=states[i];}
    if(any && !all) return fail(r,FnKBMStatusMixedState,"Six native input patches have mixed state; no changes made");
    p.alreadyPatched=all; *out=p;
    fail(r,all?FnKBMStatusAlreadyPatched:FnKBMStatusReady,all?"All six native input patches already present":"Validated six native input patches");
    // A read-only plan reports readiness, never runtime activation.
    return true;
}

typedef struct { uintptr_t address; vm_prot_t current, maximum; } PatchPage;
typedef struct {
    void *context; size_t pageSize;
    bool (*query)(void *, uintptr_t, size_t, vm_prot_t *, vm_prot_t *);
    bool (*preflight)(void *, const PatchPage *, size_t);
    bool (*protect)(void *, uintptr_t, size_t, vm_prot_t);
    bool (*setMaximum)(void *, uintptr_t, size_t, vm_prot_t);
    bool (*write)(void *, uintptr_t, uint32_t);
    bool (*read)(void *, uintptr_t, uint32_t *);
    void (*invalidate)(void *, uintptr_t, size_t);
} WriteOps;

static bool restorePages(const WriteOps *ops, PatchPage *pages, size_t count) {
    bool ok=true;
    for(size_t i=0;i<count;i++) {
        vm_prot_t cur=0,max=0;
        bool restored=ops->protect(ops->context,pages[i].address,ops->pageSize,pages[i].current);
        bool maximumRestored=ops->setMaximum(ops->context,pages[i].address,ops->pageSize,pages[i].maximum);
        bool queried=ops->query(ops->context,pages[i].address,ops->pageSize,&cur,&max);
        if(!restored || !maximumRestored || !queried || cur!=pages[i].current || max!=pages[i].maximum) ok=false;
    }
    return ok;
}
static bool applyPlan(const FnKBMPlan *plan, uintptr_t base, const WriteOps *ops, FnKBMResult *r) {
    if(plan->count!=6 || !ops->pageSize || (ops->pageSize&(ops->pageSize-1)) || ops->pageSize<4)
        return fail(r,FnKBMStatusUnsupported,"Invalid transaction plan or VM page size");
    PatchPage pages[6]; size_t pageCount=0;
    for(size_t i=0;i<6;i++) {
        const FnKBMPatch *p=&plan->patches[i]; uint32_t current=0;
        if(p->imageOffset>UINTPTR_MAX-base || ((base+p->imageOffset)&3) ||
            !ops->read(ops->context,base+p->imageOffset,&current) || current!=p->original)
            return fail(r,FnKBMStatusWriteFailed,"Code changed after structural validation; no writes made");
        uintptr_t page=(base+p->imageOffset)&~(uintptr_t)(ops->pageSize-1);
        size_t j=0; for(;j<pageCount && pages[j].address!=page;j++) {}
        if(j==pageCount) {
            PatchPage ppage={.address=page};
            if(!ops->query(ops->context,page,ops->pageSize,&ppage.current,&ppage.maximum) ||
                (ppage.current&(VM_PROT_READ|VM_PROT_EXECUTE))!=(VM_PROT_READ|VM_PROT_EXECUTE) || (ppage.current&VM_PROT_WRITE))
                return fail(r,FnKBMStatusProtectionDenied,"Patch page is not a readable, executable, nonwritable mapping");
            pages[pageCount++]=ppage;
        }
    }
    // The alias probe never modifies the source mapping or executes game code.
    for(size_t i=0;i<pageCount;i++) if(!ops->preflight(ops->context,&pages[i],ops->pageSize))
        return fail(r,FnKBMStatusProtectionDenied,"Private code-page copy cannot complete a writable-to-executable protection round trip");
    size_t enabled=0;
    for(;enabled<pageCount;enabled++) {
        if(!ops->protect(ops->context,pages[enabled].address,ops->pageSize,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)) {
            // Also restore the failing page: kernels may partially alter a map.
            bool restored=restorePages(ops,pages,enabled+1);
            return fail(r,restored?FnKBMStatusProtectionDenied:FnKBMStatusRollbackFailed,
                        restored?"Executable memory protection denied; original protections restored":"Protection transition failed and original mapping protections could not be restored");
        }
    }
    bool success=true;
    // Recheck the complete set immediately before the first write.
    for(size_t i=0;i<6;i++) { uint32_t current=0; if(!ops->read(ops->context,base+plan->patches[i].imageOffset,&current) || current!=plan->patches[i].original) success=false; }
    size_t attempted=0;
    if(success) for(size_t i=0;i<6;i++) {
        const FnKBMPatch *p=&plan->patches[i]; attempted=i+1;
        if(!ops->write(ops->context,base+p->imageOffset,p->replacement)) {success=false;break;}
    }
    for(size_t i=0;i<attempted;i++) ops->invalidate(ops->context,base+plan->patches[i].imageOffset,4);
    if(success) for(size_t i=0;i<6;i++) { uint32_t current=0; if(!ops->read(ops->context,base+plan->patches[i].imageOffset,&current) || current!=plan->patches[i].replacement) success=false; }
    // If restoring RX fails, the same rollback path still restores code bytes.
    if(success && restorePages(ops,pages,pageCount)) {
        // Validate the final executable view, after cache invalidation and RX.
        for(size_t i=0;i<6;i++) { uint32_t current=0; if(!ops->read(ops->context,base+plan->patches[i].imageOffset,&current) || current!=plan->patches[i].replacement) success=false; }
        if(success) { fail(r,FnKBMStatusInstalled,"Six native input patches installed in private process memory"); r->active=true; r->changed=true; return true; }
    } else success=false;
    bool rollback=true;
    // All six originals are known. Restore even a write that reported failure,
    // because a failed low-level write could have changed part of its word.
    if(attempted) {
        for(size_t i=0;i<pageCount;i++) if(!ops->protect(ops->context,pages[i].address,ops->pageSize,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)) rollback=false;
        for(size_t i=0;i<attempted;i++) {
            const FnKBMPatch *p=&plan->patches[i];
            if(!ops->write(ops->context,base+p->imageOffset,p->original)) rollback=false;
            ops->invalidate(ops->context,base+p->imageOffset,4);
        }
    }
    bool restored=restorePages(ops,pages,pageCount); rollback=rollback&&restored;
    for(size_t i=0;i<6;i++) { uint32_t current=0; if(!ops->read(ops->context,base+plan->patches[i].imageOffset,&current) || current!=plan->patches[i].original) rollback=false; }
    return fail(r,rollback?FnKBMStatusWriteFailed:FnKBMStatusRollbackFailed,
                rollback?"Native input patch transaction failed; original code and protections restored":"Native input patch transaction failed; rollback could not be fully verified");
}

static bool realQuery(void *context, uintptr_t address, size_t size, vm_prot_t *current, vm_prot_t *maximum) {
    (void)context;
    if(size>UINTPTR_MAX-address) return false;
    uintptr_t end=address+size; bool first=true;
    while(address<end) {
        vm_address_t region=address; vm_size_t length=0; mach_port_t object=MACH_PORT_NULL;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
        kern_return_t kr=vm_region_64(mach_task_self(),&region,&length,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
        if(object!=MACH_PORT_NULL) mach_port_deallocate(mach_task_self(),object);
        if(kr!=KERN_SUCCESS || region>address || !length || region>UINT64_MAX-length || region+length<=address) return false;
        if(first) {*current=info.protection;*maximum=info.max_protection;first=false;}
        else if(*current!=info.protection || *maximum!=info.max_protection) return false;
        address=(uintptr_t)(region+length<end?region+length:end);
    }
    return !first;
}
// Other injected tweaks may split __TEXT into regions with different maximum
// protections. Section scanning only requires access, not identical VM metadata.
static bool readableRange(uintptr_t address, size_t size, vm_prot_t required) {
    if (!size || size > UINTPTR_MAX - address) return false;
    uintptr_t end = address + size;
    while (address < end) {
        vm_address_t region = address; vm_size_t length = 0;
        mach_port_t object = MACH_PORT_NULL;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        kern_return_t kr = vm_region_64(mach_task_self(), &region, &length,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS || region > address || !length ||
            length > UINTPTR_MAX - region || region + length <= address ||
            (info.protection & required) != required) return false;
        address = region + length < end ? region + length : end;
    }
    return true;
}

static bool realProtect(void *context, uintptr_t address, size_t size, vm_prot_t protection) {
    (void)context; return vm_protect(mach_task_self(),address,size,FALSE,protection)==KERN_SUCCESS;
}
static bool realSetMaximum(void *context, uintptr_t address, size_t size, vm_prot_t protection) {
    (void)context; return vm_protect(mach_task_self(),address,size,TRUE,protection)==KERN_SUCCESS;
}
static bool realPreflight(void *context, const PatchPage *page, size_t size) {
    (void)context; vm_address_t alias=0; vm_prot_t current=0,maximum=0;
    kern_return_t kr=vm_remap(mach_task_self(),&alias,size,0,VM_FLAGS_ANYWHERE,mach_task_self(),page->address,TRUE,&current,&maximum,VM_INHERIT_NONE);
    if(kr!=KERN_SUCCESS) return false;
    bool ok=realProtect(NULL,(uintptr_t)alias,size,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if(ok) {
        // Force a private dirty page; merely changing protection can postpone
        // the COW and code-signing checks until the first real write.
        uint32_t changed=word((const void *)(uintptr_t)alias)^1u;
        ok=vm_write(mach_task_self(),alias,(vm_offset_t)&changed,sizeof(changed))==KERN_SUCCESS;
    }
    ok=ok && realProtect(NULL,(uintptr_t)alias,size,page->current) && realSetMaximum(NULL,(uintptr_t)alias,size,page->maximum);
    vm_prot_t final=0,max=0;
    ok=ok && realQuery(NULL,(uintptr_t)alias,size,&final,&max) && final==page->current && max==page->maximum;
    kern_return_t released=vm_deallocate(mach_task_self(),alias,size);
    return ok && released==KERN_SUCCESS;
}
static bool realWrite(void *context, uintptr_t address, uint32_t value) {
    (void)context;
    return vm_write(mach_task_self(),address,(vm_offset_t)&value,sizeof(value))==KERN_SUCCESS;
}
static bool realRead(void *context, uintptr_t address, uint32_t *value) {
    (void)context; vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),address,4,(vm_address_t)value,&copied)==KERN_SUCCESS && copied==4;
}
static void realInvalidate(void *context, uintptr_t address, size_t size) { (void)context; sys_icache_invalidate((void *)address,size); }

static bool runtimePolicy(FnKBMResult *r) {
#if TARGET_OS_IPHONE
    if(![[NSProcessInfo processInfo] isiOSAppOnMac]) return fail(r,FnKBMStatusProtectionDenied,"Native executable patching is supported only for iOS apps running on macOS");
#elif !TARGET_OS_OSX
    return fail(r,FnKBMStatusProtectionDenied,"Unsupported executable-memory platform");
#endif
    // Public SDKs omit csops. These status masks are the XNU codesign ABI;
    // absence of a reliable policy query is a denial, never permission.
    typedef int (*CSOps)(pid_t,unsigned int,void *,size_t);
    CSOps csops=(CSOps)dlsym(RTLD_DEFAULT,"csops"); uint32_t flags=0;
    if(!csops || csops(getpid(),0,&flags,sizeof(flags))!=0) return fail(r,FnKBMStatusProtectionDenied,"Cannot establish process code-signing policy");
    const uint32_t hard=0x00000100, enforcement=0x00001000, hardenedRuntime=0x00010000;
    const uint32_t debugged=0x10000000, invalidAllowed=0x00000020;
    if((flags&(hard|enforcement|hardenedRuntime)) && !(flags&(debugged|invalidAllowed)))
        return fail(r,FnKBMStatusProtectionDenied,"FnKBM blocked by app signing (0x%08x). Restarting alone cannot fix this; executable-memory permission is required.",flags);
    return true;
}

static pthread_mutex_t installLock=PTHREAD_MUTEX_INITIALIZER;
static FnKBMResult currentResult={.status=FnKBMStatusNotAttempted,.detail="Native input patch installation has not been requested"};
const char *FnKBMStatusName(FnKBMStatus status) {
    switch(status) {
        case FnKBMStatusNotAttempted:return "not-attempted";case FnKBMStatusReady:return "ready";
        case FnKBMStatusInstalled:return "installed";case FnKBMStatusAlreadyPatched:return "already-patched";
        case FnKBMStatusUnsupported:return "unsupported";case FnKBMStatusMixedState:return "mixed-state";
        case FnKBMStatusProtectionDenied:return "protection-denied";case FnKBMStatusWriteFailed:return "write-failed";
        case FnKBMStatusRollbackFailed:return "rollback-failed";
    }
    return "unknown";
}
FnKBMResult FnKBMCurrentResult(void) { pthread_mutex_lock(&installLock);FnKBMResult r=currentResult;pthread_mutex_unlock(&installLock);return r; }
FnKBMResult FnKBMInstallEarly(void) {
    pthread_mutex_lock(&installLock);
    if(currentResult.status!=FnKBMStatusNotAttempted) {FnKBMResult r=currentResult;pthread_mutex_unlock(&installLock);return r;}
    FnKBMResult r; FnKBMPlan plan; Image image;
    if(!pthread_main_np()) {fail(&r,FnKBMStatusUnsupported,"Native input patch installation requires the main thread during early startup");goto done;}
    const struct mach_header *header=_dyld_get_image_header(0); uintptr_t base=(uintptr_t)header;
    vm_prot_t protection=0,maximum=0;
    if(!header || !realQuery(NULL,base,sizeof(struct mach_header_64),&protection,&maximum) || !(protection&VM_PROT_READ)) {fail(&r,FnKBMStatusUnsupported,"Main image header is not readable");goto done;}
    struct mach_header_64 h;memcpy(&h,header,sizeof(h));
    size_t headerSize=sizeof(h)+(size_t)h.sizeofcmds;
    if(h.sizeofcmds>16u*1024u*1024u || !realQuery(NULL,base,headerSize,&protection,&maximum) || !(protection&VM_PROT_READ) ||
        !parse(header,headerSize,SIZE_MAX,FnKBMImageMapped,&image,&r)) {
        fail(&r,FnKBMStatusUnsupported,"Main image load commands are invalid or inaccessible");goto done;
    }
    if(image.text.offset>UINTPTR_MAX-base || image.strings.offset>UINTPTR_MAX-base ||
        !readableRange(base+image.text.offset,(size_t)image.text.size,VM_PROT_READ|VM_PROT_EXECUTE) ||
        !readableRange(base+image.strings.offset,(size_t)image.strings.size,VM_PROT_READ)) {
        fail(&r,FnKBMStatusUnsupported,"Required image sections are not fully readable");goto done;
    }
    size_t length=image.text.offset+(size_t)image.text.size;
    if(length<image.strings.offset+image.strings.size) length=image.strings.offset+(size_t)image.strings.size;
    if(!FnKBMBuildPlan(header,length,FnKBMImageMapped,&plan,&r)) goto done;
    if(plan.alreadyPatched) {r.active=true;goto done;}
    if(!runtimePolicy(&r)) goto done;
    vm_size_t pageSize=0;
    if(host_page_size(mach_host_self(),&pageSize)!=KERN_SUCCESS) {fail(&r,FnKBMStatusProtectionDenied,"Cannot query the actual VM page size");goto done;}
    WriteOps ops={.pageSize=pageSize,.query=realQuery,.preflight=realPreflight,.protect=realProtect,.setMaximum=realSetMaximum,.write=realWrite,.read=realRead,.invalidate=realInvalidate};
    applyPlan(&plan,base,&ops,&r);
done:
    currentResult=r;pthread_mutex_unlock(&installLock);return r;
}
