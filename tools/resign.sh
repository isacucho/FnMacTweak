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

# 3. Re-firmar el bundle preservando plataforma iOS.
# --force en un bundle iOS en macOS sobreescribe LC_BUILD_VERSION platform=IOS
# con platform=macOS (0) en la firma CD -> AMFI lo mata con "Binary with wrong platform".
# Fix: extraer entitlements, quitar firma, re-firmar sin --force para que codesign
# auto-detecte platform=IOS desde LC_BUILD_VERSION del binario.
echo "[3/4] Re-firmando bundle (preservando plataforma iOS)..."
ENTS_TMP=$(mktemp /tmp/fn_ents.XXXXXX)
# deploy.sh ya quitó la firma del bundle via sudo codesign --remove-signature,
# así que el binario puede no tener entitlements que extraer. Fallback al backup.
codesign -d --entitlements :- "$BIN" 2>/dev/null > "$ENTS_TMP" || true
if [ ! -s "$ENTS_TMP" ] && [ -f "${BIN}.pre_fnpatch" ]; then
    echo "  (extrayendo entitlements del backup pre_fnpatch...)"
    codesign -d --entitlements :- "${BIN}.pre_fnpatch" 2>/dev/null > "$ENTS_TMP" || true
fi
codesign --remove-signature "$APP" 2>/dev/null || true
if [ -s "$ENTS_TMP" ]; then
    codesign --sign "$IDENTITY" --entitlements "$ENTS_TMP" "$APP"
else
    echo "  (sin entitlements encontrados, firmando sin --entitlements)"
    codesign --sign "$IDENTITY" "$APP"
fi
rm -f "$ENTS_TMP"

# Verificar + mostrar CDHash resultante del ejecutable
echo ""
echo "[Verificando...]"
codesign -v "$APP" 2>&1 && echo "OK: bundle firma valida" || echo "ERROR: firma invalida"
echo ""
echo "CDHash ejecutable post-resign:"
codesign -d --verbose=4 "$BIN" 2>&1 | grep -E "CDHash|VersionPlatform|Format|Sealed"


# 4. Re-firmar el wrapper externo /Applications/Fortnite.app.
# Su CodeResources cubre el inner bundle: cuando re-firmamos la inner,
# el outer queda con 'invalid signature' y macOS rechaza el launch.
# Mismo enfoque: --remove-signature + sign sin --force para preservar
# la plataforma iOS del ejecutable.
OUTER="/Applications/Fortnite.app"
echo "[4/4] Re-firmando wrapper externo..."
ENTS_OUTER=$(mktemp /tmp/fn_outer_ents.XXXXXX)
codesign -d --entitlements :- "$BIN" 2>/dev/null > "$ENTS_OUTER" || true
codesign --remove-signature "$OUTER" 2>/dev/null || true
codesign --sign "$IDENTITY" --entitlements "$ENTS_OUTER" "$OUTER"
rm -f "$ENTS_OUTER"
codesign -v "$OUTER" 2>&1 && echo "OK: outer wrapper firma valida" || echo "ERROR: outer wrapper firma invalida"
# Quitar quarantine del outer para que Gatekeeper no bloquee el launch.
sudo xattr -cr "$OUTER" 2>/dev/null || true
echo "xattrs outer: $(xattr "$OUTER" 2>/dev/null | tr '\n' ' ' || echo '(ninguno)')"

echo ""
echo "=== Listo. Lanza Fortnite. ==="
