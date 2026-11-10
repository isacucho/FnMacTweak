"""
lldb_rejoin.py - Script LLDB para encontrar UFortRejoinCheck* en memoria.

Uso desde LLDB:
    command script import /path/to/lldb_rejoin.py

O lanzar directamente:
    lldb -p $(pgrep FortniteClient-IOS) -- command script import tools/lldb_rejoin.py

Lo que hace:
1. Calcula el slide del binario principal.
2. Calcula la VA del vtable de UFortRejoinCheck (IMAGE_BASE + 0xd4a4e70).
3. Busca ese puntero en regiones de memoria RW (heap) para encontrar instancias.
4. Imprime la VA de cada instancia y los bytes relevantes (+0x2a = bCanRejoinSession).
5. Busca tambien via GEngine si lo encuentra.
"""

import lldb

REJOIN_VTABLE_OFF = 0xd4a4e70   # file off del vtable de UFortRejoinCheck
REJOIN_FN_OFF     = 0x805be18   # file off de RejoinViaSessionInternal
IMAGE_BASE        = 0x100000000

def get_slide(target):
    for mod in target.module_iter():
        name = mod.file.basename
        if name and 'FortniteClient' in name and 'IOS' in name and 'Shipping' in name:
            for sec in mod.section_iter():
                if sec.name == '__TEXT':
                    slide = sec.GetLoadAddress(target) - sec.GetFileAddress()
                    return slide, mod
    return None, None

def read_ptr(process, addr):
    err = lldb.SBError()
    val = process.ReadUnsignedFromMemory(addr, 8, err)
    if err.success:
        return val
    return None

def run(debugger, command, result, internal_dict):
    target  = debugger.GetSelectedTarget()
    process = target.GetProcess()

    slide, mod = get_slide(target)
    if slide is None:
        result.AppendMessage("ERROR: FortniteClient-IOS-Shipping not found in modules")
        return

    result.AppendMessage(f"[RejoinSearch] slide=0x{slide:x}")

    vtable_va    = IMAGE_BASE + slide + REJOIN_VTABLE_OFF
    rejoin_fn_va = IMAGE_BASE + slide + REJOIN_FN_OFF
    result.AppendMessage(f"[RejoinSearch] vtable_va=0x{vtable_va:x}  rejoin_fn_va=0x{rejoin_fn_va:x}")

    # Scan all anonymous RW regions (no file backing = heap/UObject arenas).
    # Read in 2MB chunks so Python doesn't OOM. Skip mapped files (__TEXT/__DATA).
    import struct, re

    MIN_RW_SIZE = 0x400           # skip tiny stack guards
    CHUNK       = 0x200000        # 2 MB chunks
    ADDR_MAX    = 0x700000000000  # user space on ARM64 macOS

    result.AppendMessage("[RejoinSearch] Scanning anonymous RW regions (all sizes)...")
    needle = struct.pack('<Q', vtable_va)

    hits_all   = []
    mem_list   = process.GetMemoryRegions()
    n          = mem_list.GetSize()
    scanned_mb = 0
    regions_scanned = 0

    for i in range(n):
        info = lldb.SBMemoryRegionInfo()
        mem_list.GetMemoryRegionAtIndex(i, info)
        if not info.IsReadable() or not info.IsWritable():
            continue
        start = info.GetRegionBase()
        end   = info.GetRegionEnd()
        sz    = end - start
        if sz < MIN_RW_SIZE or start > ADDR_MAX:
            continue
        # Skip mapped files (Mach-O image, __DATA pages mapped from binary)
        if info.GetName() and info.GetName() not in ('', '--'):
            continue

        regions_scanned += 1
        off = 0
        while off < sz:
            chunk_sz = min(CHUNK, sz - off)
            err = lldb.SBError()
            raw = process.ReadMemory(start + off, chunk_sz, err)
            if err.success and raw:
                scanned_mb += chunk_sz
                pos = 0
                while True:
                    idx = raw.find(needle, pos)
                    if idx == -1:
                        break
                    abs_off = off + idx
                    if abs_off % 8 == 0:
                        hits_all.append(start + abs_off)
                    pos = idx + 1
            off += chunk_sz

    result.AppendMessage(f"[RejoinSearch] Scanned {scanned_mb//1024//1024}MB across {regions_scanned} anonymous RW regions")
    result.AppendMessage(f"[RejoinSearch] Found {len(hits_all)} UFortRejoinCheck instance(s)")

    for addr in hits_all[:5]:
        can_rejoin = read_ptr(process, addr + 0x28)
        b = (can_rejoin >> 16) & 0xFF if can_rejoin is not None else None
        result.AppendMessage(f"  UFortRejoinCheck* = 0x{addr:x}  bCanRejoinSession[+0x2a]={b}")

    if hits_all:
        ptr = hits_all[0]
        result.AppendMessage(f"\n[RejoinSearch] Buscando holders de 0x{ptr:x}...")
        needle2 = struct.pack('<Q', ptr)
        holders = []
        for i in range(n):
            info = lldb.SBMemoryRegionInfo()
            mem_list.GetMemoryRegionAtIndex(i, info)
            if not info.IsReadable() or not info.IsWritable():
                continue
            start = info.GetRegionBase()
            end   = info.GetRegionEnd()
            sz    = end - start
            if sz < MIN_RW_SIZE or start > ADDR_MAX:
                continue
            if info.GetName() and info.GetName() not in ('', '--'):
                continue
            off = 0
            while off < sz:
                chunk_sz = min(CHUNK, sz - off)
                err = lldb.SBError()
                raw = process.ReadMemory(start + off, chunk_sz, err)
                if err.success and raw:
                    pos = 0
                    while True:
                        idx = raw.find(needle2, pos)
                        if idx == -1:
                            break
                        abs_off = off + idx
                        if abs_off % 8 == 0:
                            holders.append(start + abs_off)
                            result.AppendMessage(f"  Holder @ 0x{start+abs_off:x}  (region base=0x{start:x} sz={sz//1024}KB)")
                        pos = idx + 1
                off += chunk_sz
            if len(holders) >= 20:
                break
        if not holders:
            result.AppendMessage("  (no holders en regiones anonimas)")
    else:
        result.AppendMessage("[RejoinSearch] NO INSTANCES FOUND")

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add -f lldb_rejoin.run rejoin_search')
    print("[lldb_rejoin] Loaded. Run 'rejoin_search' to scan for UFortRejoinCheck*.")
    print("[lldb_rejoin] Or attach with: lldb -p $(pgrep FortniteClient-IOS) -o 'command script import tools/lldb_rejoin.py' -o 'rejoin_search' -o 'continue'")
