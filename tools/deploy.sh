#!/bin/bash
# deploy.sh — copia el dylib parchado a Frameworks y actualiza LC_LOAD_DYLIB
# Uso: sudo bash tools/deploy.sh
set -euo pipefail

VERSION="$(cat "$(dirname "$0")/../VERSION" | tr -d '[:space:]')"
DYLIB_SRC="$(dirname "$0")/../builds/dev/FnMacBypass.dylib"
APP="/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app"
FW_DIR="$APP/Frameworks"
BIN="$APP/FortniteClient-IOS-Shipping"
DYLIB_DST="$FW_DIR/FnMacBypass.dylib"
# UUID del container asignado por Sideloadly, puede cambiar al reinstalar.
# Buscar dinamicamente: primero por FnDiag.log existente, luego por lsof si el
# juego esta corriendo, con fallback al UUID conocido.
_discover_container_log() {
    local f
    f=$(find ~/Library/Containers -name "FnDiag.log" 2>/dev/null | head -1)
    [ -n "$f" ] && echo "$f" && return
    local pid
    pid=$(pgrep -f FortniteClient-IOS 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
        f=$(lsof -p "$pid" 2>/dev/null | awk '$NF~/FnDiag\.log/{print $NF}' | head -1)
        [ -n "$f" ] && echo "$f" && return
    fi
    echo "$HOME/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log"
}
LOG=$(_discover_container_log)

# Resolve path
DYLIB_SRC="$(cd "$(dirname "$DYLIB_SRC")" && pwd)/$(basename "$DYLIB_SRC")"

if [ ! -f "$DYLIB_SRC" ]; then
    echo "ERROR: dylib no encontrado en $DYLIB_SRC"
    echo "Ejecuta primero: cd FnMacUpdateFix && make"
    exit 1
fi

echo "=== FnMacBypass Deploy V${VERSION} ==="
echo "Fuente: $DYLIB_SRC ($(du -h "$DYLIB_SRC" | cut -f1))"

# Kill any running Fortnite process: the kernel blocks writes to a mapped executable.
# write-xor-execute is enforced at the VFS level regardless of file permissions.
FN_PID=$(pgrep -f FortniteClient-IOS 2>/dev/null | head -1 || true)
if [ -n "$FN_PID" ]; then
    echo "Matando FortniteClient-IOS (PID $FN_PID)..."
    kill "$FN_PID" 2>/dev/null || true
    sleep 1
fi

# Remove code signature first: com.apple.macl on the .app dir blocks ALL writes
# (even by the file owner) once the app has been run. sudo codesign --remove-signature
# disables the kernel's macl write-protection; xattr data remains but is no longer
# enforced. This MUST run before any cp/write/patch_binary step.
echo "Quitando firma para liberar macl write-protection..."
sudo codesign --remove-signature "$APP" 2>&1 || true
sudo xattr -cr "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

# --- 0. Disk island patch (required for BNF hook) ---
# BroadcastNetworkFailure is non-virtual: the only way to hook it without
# AMFI kill is via a pre-patched island in Mach-O padding. Auto-apply here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_PY="$SCRIPT_DIR/patch_binary.py"
echo ""
echo "[0/5] Verificando parche de isla en disco..."
PATCH_STATE=$(python3 "$PATCH_PY" --verify 2>&1 | grep "^Island at" | awk '{print $NF}')
echo "  Estado: $PATCH_STATE"
if [ "$PATCH_STATE" = "unpatched" ]; then
    echo "  Aplicando parche de isla (patch_binary.py --apply)..."
    python3 "$PATCH_PY" --apply
    echo "  Isla aplicada."
elif [ "$PATCH_STATE" = "patched" ]; then
    echo "  BNF island presente. Verificando islands adicionales..."
    python3 "$PATCH_PY" --apply || true
elif [ "$PATCH_STATE" = "patched_old" ]; then
    echo "  Isla antigua detectada, actualizando..."
    python3 "$PATCH_PY" --apply
    echo "  Isla actualizada."
elif [ "$PATCH_STATE" = "migrate" ]; then
    echo "  Migrando isla de 0x29bc -> 0x29c0 (fix install_name_tool overlap)..."
    python3 "$PATCH_PY" --apply
    echo "  Migracion completada."
else
    echo "  Estado inesperado ($PATCH_STATE), intentando aplicar parche..."
    python3 "$PATCH_PY" --apply && echo "  Parche aplicado." || echo "  AVISO: patch_binary.py --apply fallo, continua sin parche."
fi


# Copy to versioned destination
echo "Copiando dylib..."
cp "$DYLIB_SRC" "$DYLIB_DST"
# Also keep the old name in sync while LC_LOAD_DYLIB migration is pending
OLD_FNAME_CUR=$(otool -L "$BIN" 2>/dev/null | grep -E 'FnMac(Bypass|KickFix).*\.dylib' | awk '{print $1}' | head -1 | xargs basename 2>/dev/null)
if [ -n "$OLD_FNAME_CUR" ] && [ "$OLD_FNAME_CUR" != "FnMacBypass.dylib" ]; then
    cp "$DYLIB_SRC" "$FW_DIR/$OLD_FNAME_CUR"
fi

echo "Verificando checksum..."
SRC_MD5=$(md5 -q "$DYLIB_SRC")
DST_MD5=$(md5 -q "$DYLIB_DST")
if [ "$SRC_MD5" != "$DST_MD5" ]; then
    echo "ERROR: checksums no coinciden"
    echo "  src: $SRC_MD5"
    echo "  dst: $DST_MD5"
    exit 1
fi
echo "OK: $DST_MD5"

# Asegura que LC_LOAD_DYLIB apunte al nombre fijo FnMacBypass.dylib.
# Si el binario tiene un nombre versionado antiguo (FnMacKickFix-V*) lo migra en un solo deploy.
echo ""
echo "Actualizando LC_LOAD_DYLIB del binario..."
NEW_LC="@rpath/FnMacBypass.dylib"
NEW_FNAME=$(basename "$NEW_LC")
# Buscar LC_LOAD_DYLIB: acepta tanto el nombre fijo nuevo como cualquier variante versionada anterior.
OLD_LC=$(otool -L "$BIN" | grep -E 'FnMac(Bypass|KickFix).*\.dylib' | awk '{print $1}' | head -1)

if [ -z "$OLD_LC" ]; then
    echo "AVISO: no se encontro LC_LOAD_DYLIB de FnMacBypass en el binario"
    echo "El binario no tiene la dylib inyectada. Reinjecta con Sideloadly antes de lanzar."
elif [ "$OLD_LC" = "$NEW_LC" ]; then
    echo "LC_LOAD_DYLIB ya apunta a FnMacBypass.dylib, sin cambios"
else
    OLD_FNAME=$(basename "$OLD_LC")
    echo "  $OLD_FNAME -> $NEW_FNAME"
    # install_name_tool fails when LC_CODE_SIGNATURE is present (LINKEDIT inconsistency).
    # Direct byte-replace works regardless of signature state; both strings must be same length.
    python3 - "$BIN" "$OLD_LC" "$NEW_LC" <<'PYEOF'
import sys, struct
BIN, OLD, NEW = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
if len(NEW) > len(OLD):
    sys.exit(f"ERROR: len mismatch OLD={len(OLD)} NEW={len(NEW)} - new string longer, cannot patch in-place")
if len(NEW) < len(OLD):
    NEW = NEW + b'\x00' * (len(OLD) - len(NEW))
with open(BIN, 'rb') as f:
    data = bytearray(f.read())
idx = data.find(OLD)
if idx == -1:
    idx2 = data.find(NEW)
    print(f"Already {sys.argv[3]} at 0x{idx2:x}" if idx2 != -1 else "ERROR: LC_LOAD_DYLIB string not found")
    sys.exit(0)
data[idx:idx+len(OLD)] = NEW
with open(BIN, 'wb') as f:
    f.write(data)
print(f"LC_LOAD_DYLIB patched at 0x{idx:x}: {sys.argv[2]} -> {sys.argv[3]}")
PYEOF
    echo "LC_LOAD_DYLIB actualizado"

    # Remove the old versioned dylib from Frameworks
    if [ -f "$FW_DIR/$OLD_FNAME" ] && [ "$OLD_FNAME" != "$NEW_FNAME" ]; then
        echo "Eliminando dylib antigua: $OLD_FNAME"
        xattr -d com.apple.provenance "$FW_DIR/$OLD_FNAME" 2>/dev/null || true
        rm -f "$FW_DIR/$OLD_FNAME"
    fi
fi

# Limpiar restos de nombres versionados anteriores (FnMacKickFix-V* y FnMacBypass-V*).
for f in "$FW_DIR"/FnMac*.dylib; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$NEW_FNAME" ] && continue
    echo "Eliminando dylib residual: $(basename "$f")"
    xattr -d com.apple.provenance "$f" 2>/dev/null || true
    rm -f "$f"
done

# Tail log if exists
if [ -f "$LOG" ]; then
    echo ""
    echo "=== Log previo (ultimas 5 lineas) ==="
    tail -5 "$LOG"
fi

echo ""
echo "=== Deploy completo. Ejecuta resign.sh antes de lanzar Fortnite. ==="
echo "(Incluye parche de isla en disco. BNF hook activo tras resign + relaunch.)"
echo "Para monitorizar el log en tiempo real:"
echo "  tail -f '$LOG'"
