#!/bin/bash
# resign.sh - Re-firma el bundle tras patch_binary.py + deploy.sh
# Ejecutar: bash tools/resign.sh
set -euo pipefail

APP="/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app"
BIN="$APP/FortniteClient-IOS-Shipping"
IDENTITY="Apple Development: alexgaro2015@icloud.com (P5273M69QW)"
VERSION="$(cat "$(dirname "$0")/../VERSION" | tr -d '[:space:]')"
DYLIB_NAME="FnMacKickFix-V${VERSION}-dev.dylib"

echo "=== FnMac Bundle Re-Sign ==="
echo "Bundle:   $APP"
echo "Identity: $IDENTITY"
echo "Version:  $VERSION"
echo ""

# 1. Quitar xattr de provenance que bloquea escrituras
echo "[1/4] Quitando com.apple.provenance..."
sudo xattr -cr "$APP" 2>/dev/null || true

# 2. Re-firmar el dylib parchado primero (antes que el bundle)
echo "[2/4] Re-firmando dylib..."
codesign --force --sign "$IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags \
  "$APP/Frameworks/$DYLIB_NAME"

# 3. Re-firmar el bundle.
# ADVERTENCIA: codesign en macOS siempre escribe VersionPlatform=0 (macOS) en el
# CodeDirectory, independientemente de --force y de LC_BUILD_VERSION platform=IOS.
# Tras ejecutar resign.sh, Fortnite NO lanzara hasta re-sideloadear el IPA con
# Sideloadly (que firma correctamente con VersionPlatform=2 (IOS)).
# resign.sh es util solo para actualizar el dylib o parchear el binario antes
# de regenerar el IPA.
echo "[3/4] Re-firmando bundle (VersionPlatform quedara 0 / macOS)..."
ENTS_TMP=$(mktemp)
trap "rm -f '$ENTS_TMP'" EXIT
# Fuente de entitlements (prioridad descendente):
# 1. embedded.mobileprovision del bundle (creado por Sideloadly, siempre presente)
# 2. Binario firmado (solo si Sideloadly no ha sido ejecutado aun)
# 3. Backup pre_fnpatch
PROVISION="$APP/embedded.mobileprovision"
if [ -f "$PROVISION" ]; then
    echo "  (extrayendo entitlements de embedded.mobileprovision...)"
    python3 - "$PROVISION" "$ENTS_TMP" << 'PYEOF'
import sys, re, plistlib
data = open(sys.argv[1], 'rb').read()
start = data.find(b'<?xml'); end = data.rfind(b'</plist>') + len(b'</plist>')
profile = plistlib.loads(data[start:end])
ents = profile.get('Entitlements', {})
with open(sys.argv[2], 'wb') as f:
    plistlib.dump(ents, f)
print(f"  entitlements extraidos: {list(ents.keys())}")
PYEOF
fi
if [ ! -s "$ENTS_TMP" ]; then
    codesign -d --entitlements :- "$BIN" 2>/dev/null > "$ENTS_TMP" || true
fi
if [ ! -s "$ENTS_TMP" ] && [ -f "${BIN}.pre_fnpatch" ]; then
    echo "  (extrayendo entitlements del backup pre_fnpatch...)"
    codesign -d --entitlements :- "${BIN}.pre_fnpatch" 2>/dev/null > "$ENTS_TMP" || true
fi
# Patch LSRequiresIPhoneOS: sin esto macOS bloquea el launch con
# "developer did not intend for it to run on this Mac".
# Esta key vuelve a true cada vez que se re-sideloadea la app.
INFOPLIST="$APP/Info.plist"
if [ -f "$INFOPLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :LSRequiresIPhoneOS false" "$INFOPLIST" 2>/dev/null && \
        echo "  LSRequiresIPhoneOS -> false" || \
        echo "  AVISO: no se pudo parchear LSRequiresIPhoneOS"
fi
codesign --remove-signature "$APP" 2>/dev/null || true
if [ -s "$ENTS_TMP" ]; then
    codesign --sign "$IDENTITY" --entitlements "$ENTS_TMP" "$APP"
else
    echo "  AVISO: sin entitlements, firmando sin --entitlements (sandbox fallara)"
    codesign --sign "$IDENTITY" "$APP"
fi
# Verificar + mostrar CDHash resultante del ejecutable
echo ""
echo "[Verificando...]"
codesign -v "$APP" 2>&1 && echo "OK: bundle firma valida" || echo "ERROR: firma invalida"
echo ""
echo "CDHash ejecutable post-resign:"
codesign -d --verbose=4 "$BIN" 2>&1 | grep -E "CDHash|VersionPlatform|Format|Sealed"


# 4. Outer wrapper /Applications/Fortnite.app: NO re-firmar.
# El outer no tiene ejecutable ni Info.plist propios; Sideloadly lo firma
# usando el binario iOS via symlink WrappedBundle. Cuando resign.sh vuelve
# a firmar el outer con nuestro cert, Gatekeeper preflight falla con -10673.
# Dejar la firma original de Sideloadly intacta (CDHash ya no coincide tras
# re-firmar el inner, pero Gatekeeper acepta eso para iOS-on-Mac wrappers).
OUTER="/Applications/Fortnite.app"
echo "[4/4] Outer wrapper: conservando firma Sideloadly (no re-firmar)..."
codesign -d --verbose=1 "$OUTER" 2>&1 | grep -E "Identifier|Authority|VersionPlatform" || true
# Solo quitar quarantine para que Gatekeeper no bloquee el launch.
sudo xattr -cr "$OUTER" 2>/dev/null || true
echo "xattrs outer: $(xattr "$OUTER" 2>/dev/null | tr '\n' ' ' || echo '(ninguno)')"

echo ""
echo "=== Listo. ==="
echo "ADVERTENCIA: VersionPlatform=0 (macOS) en CodeDirectory."
echo "Para lanzar Fortnite: regenera el IPA e instala con Sideloadly."
