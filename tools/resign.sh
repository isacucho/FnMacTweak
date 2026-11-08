#!/bin/bash
# resign.sh - Repara el bundle signature roto por el auto-refresh de Sideloadly
# Ejecutar: bash resign.sh
# Requiere: contraseña de admin (sudo)
set -euo pipefail

APP="/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app"
IDENTITY="Apple Development: alexgaro2015@icloud.com (P5273M69QW)"
VERSION="$(cat "$(dirname "$0")/../VERSION" | tr -d '[:space:]')"
DYLIB_NAME="FnMacKickFix-V${VERSION}-dev.dylib"

echo "=== FnMac Bundle Re-Sign ==="
echo "Bundle: $APP"
echo "Identity: $IDENTITY"
echo ""

# 1. Quitar xattr de provenance que bloquea escrituras
echo "[1/4] Quitando com.apple.provenance..."
sudo xattr -d com.apple.provenance "$APP" 2>/dev/null || true
sudo xattr -d com.apple.provenance "$APP/Frameworks/$DYLIB_NAME" 2>/dev/null || true
sudo xattr -d com.apple.provenance "$APP/_CodeSignature" 2>/dev/null || true
sudo xattr -d com.apple.provenance "$APP/_CodeSignature/CodeResources" 2>/dev/null || true
sudo xattr -d com.apple.provenance "$APP/embedded.mobileprovision" 2>/dev/null || true

# 2. Re-firmar el dylib parchado primero
echo "[2/5] Re-firmando dylib..."
codesign --force --sign "$IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags \
  "$APP/Frameworks/$DYLIB_NAME"

# 3. Extraer entitlements y re-firmar el binario principal explícitamente.
#    --preserve-metadata=entitlements falla si la firma ya esta corrompida (post-patch).
echo "[3/5] Extrayendo entitlements del binario..."
ENTS_TMP=$(mktemp /tmp/fn_ents_XXXXXX.plist)
codesign -d --entitlements - --xml "$APP/FortniteClient-IOS-Shipping" 2>/dev/null > "$ENTS_TMP" || true

echo "[4/5] Re-firmando binario con entitlements..."
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTS_TMP" \
  --preserve-metadata=identifier,flags \
  "$APP/FortniteClient-IOS-Shipping"
rm -f "$ENTS_TMP"

# 5. Re-firmar el bundle completo (regenera CodeResources con hashes actuales)
echo "[5/5] Re-firmando bundle completo..."
codesign --force --sign "$IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags \
  "$APP"

# Verificar
echo "[Verificando...]"
codesign -v "$APP" 2>&1 && echo "OK: bundle firma valida" || echo "ERROR: firma sigue rota"

echo ""
echo "=== Listo. Lanza Fortnite. ==="
