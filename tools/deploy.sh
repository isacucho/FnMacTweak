#!/bin/bash
# deploy.sh — copia el dylib parchado a Frameworks y actualiza LC_LOAD_DYLIB
# Uso: sudo bash tools/deploy.sh
set -euo pipefail

VERSION="$(cat "$(dirname "$0")/../VERSION" | tr -d '[:space:]')"
DYLIB_SRC="$(dirname "$0")/../builds/dev/FnMacKickFix-V${VERSION}-dev.dylib"
APP="/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app"
FW_DIR="$APP/Frameworks"
BIN="$APP/FortniteClient-IOS-Shipping"
DYLIB_DST="$FW_DIR/FnMacKickFix-V${VERSION}-dev.dylib"
LOG="$HOME/Library/Containers/D2C36FB2-592A-48AC-984E-A6CC17CB07C9/Documents/FnDiag.log"

# Resolve path
DYLIB_SRC="$(cd "$(dirname "$DYLIB_SRC")" && pwd)/$(basename "$DYLIB_SRC")"

if [ ! -f "$DYLIB_SRC" ]; then
    echo "ERROR: dylib no encontrado en $DYLIB_SRC"
    echo "Ejecuta primero: cd FnMacUpdateFix && make"
    exit 1
fi

echo "=== FnMac Deploy V${VERSION} ==="
echo "Fuente: $DYLIB_SRC ($(du -h "$DYLIB_SRC" | cut -f1))"

# Remove provenance xattr so we can overwrite
echo "Quitando com.apple.provenance..."
xattr -d com.apple.provenance "$DYLIB_DST" 2>/dev/null || true
xattr -d com.apple.provenance "$FW_DIR" 2>/dev/null || true

# Copy to versioned destination
echo "Copiando dylib..."
cp "$DYLIB_SRC" "$DYLIB_DST"

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

# Update LC_LOAD_DYLIB in binary to reference the new versioned dylib.
# The binary was originally injected by Sideloadly/insert_dylib with a versioned name.
# Each deploy must update that name or the binary will crash on launch (dyld: Library missing).
echo ""
echo "Actualizando LC_LOAD_DYLIB del binario..."
NEW_LC="@executable_path/Frameworks/FnMacKickFix-V${VERSION}-dev.dylib"
NEW_FNAME=$(basename "$NEW_LC")
OLD_LC=$(otool -L "$BIN" | grep 'FnMacKickFix-V.*-dev\.dylib' | awk '{print $1}' | head -1)

if [ -z "$OLD_LC" ]; then
    echo "AVISO: no se encontro LC_LOAD_DYLIB de FnMacKickFix en el binario"
    echo "El binario no tiene la dylib inyectada. Reinjecta con Sideloadly antes de lanzar."
elif [ "$OLD_LC" = "$NEW_LC" ]; then
    echo "LC_LOAD_DYLIB ya apunta a V${VERSION}, sin cambios"
else
    OLD_FNAME=$(basename "$OLD_LC")
    echo "  $OLD_FNAME -> $NEW_FNAME"
    install_name_tool -change "$OLD_LC" "$NEW_LC" "$BIN"
    echo "LC_LOAD_DYLIB actualizado"

    # Remove the old versioned dylib from Frameworks
    if [ -f "$FW_DIR/$OLD_FNAME" ] && [ "$OLD_FNAME" != "$NEW_FNAME" ]; then
        echo "Eliminando dylib antigua: $OLD_FNAME"
        xattr -d com.apple.provenance "$FW_DIR/$OLD_FNAME" 2>/dev/null || true
        rm -f "$FW_DIR/$OLD_FNAME"
    fi
fi

# Remove any other residual FnMacKickFix-V* dylibs (not the new one).
# Multiple old versions cause duplicate hooks with broken timing channels.
for f in "$FW_DIR"/FnMacKickFix-V*.dylib; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$NEW_FNAME" ] && continue
    echo "Eliminando residual: $(basename "$f")"
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
echo "Para monitorizar el log en tiempo real:"
echo "  tail -f '$LOG'"
