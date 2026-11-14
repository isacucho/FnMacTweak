#!/bin/bash
# promote.sh — valida y promueve un artefacto entre canales del pipeline.
# Uso:
#   bash tools/promote.sh dev→beta    # promueve builds/dev/ a builds/beta/
#   bash tools/promote.sh beta→rc     # promueve builds/beta/ a builds/rc/
#   bash tools/promote.sh rc→public   # promueve builds/rc/ a builds/release/ (artefacto final)
#
# La promoción falla si:
#   - El canal origen no tiene dylib compilada
#   - El canal origen tiene símbolos de debug que no deberían estar (beta/rc)
#   - El binario no es ARM64
#   - No hay VERSION en el repo
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRANSITION="${1:-}"

usage() {
    echo "Uso: bash tools/promote.sh <origen>→<destino>"
    echo "  dev→beta   : promover dev a beta (pruebas externas)"
    echo "  beta→rc    : promover beta a rc (release candidate)"
    echo "  rc→public  : empaquetar rc como release final"
    exit 1
}

[[ -z "$TRANSITION" ]] && usage

# Parsear transición (acepta → o ->)
TRANSITION="${TRANSITION/→/->}"
SRC_CH="${TRANSITION%%->*}"
DST_CH="${TRANSITION##*->}"

valid_channels=(dev beta rc public)
is_valid() {
    local ch="$1"
    for v in "${valid_channels[@]}"; do [[ "$ch" == "$v" ]] && return 0; done
    return 1
}
is_valid "$SRC_CH" || { echo "Canal origen inválido: $SRC_CH"; usage; }
is_valid "$DST_CH" || { echo "Canal destino inválido: $DST_CH"; usage; }

VERSION="$(cat "$ROOT/VERSION" | tr -d '[:space:]')"
SRC_DYLIB="$ROOT/builds/$SRC_CH/FnMacBypass.dylib"

echo "=== FnMac Promote V${VERSION}: ${SRC_CH} → ${DST_CH} ==="

# --- 1. Verificar existencia del artefacto origen ---
if [[ ! -f "$SRC_DYLIB" ]]; then
    echo "ERROR: falta $SRC_DYLIB"
    echo "  Compila primero: make $SRC_CH"
    exit 1
fi
echo "[1/5] Artefacto origen: OK ($SRC_DYLIB)"
echo "      Tamaño: $(du -h "$SRC_DYLIB" | cut -f1)"

# --- 2. Verificar arquitectura ARM64 ---
ARCH="$(file "$SRC_DYLIB")"
if ! echo "$ARCH" | grep -q "arm64"; then
    echo "ERROR: el dylib no es ARM64"
    echo "  $ARCH"
    exit 1
fi
echo "[2/5] Arquitectura: ARM64 OK"

# --- 3. Verificar símbolos según canal ---
# beta: puede tener -g (secciones __DWARF) pero no debería tener símbolos privados en exceso
# rc/public: sin secciones __DWARF, sin símbolos locales
DWARF_SECTIONS=$(otool -l "$SRC_DYLIB" 2>/dev/null | grep -c '__DWARF' || true)
LOCAL_SYMS=$(nm "$SRC_DYLIB" 2>/dev/null | grep -c '^[0-9a-f]\{16\} [a-z]' || true)

if [[ "$SRC_CH" == "beta" ]]; then
    # Para beta→rc: rechazar si ya tiene DWARF (canal origen debería tenerlo, es OK)
    echo "[3/5] Símbolos beta: secciones __DWARF=$DWARF_SECTIONS símbolos_locales=$LOCAL_SYMS"
elif [[ "$SRC_CH" == "rc" ]] || [[ "$SRC_CH" == "public" ]]; then
    # Para rc: exigir que NO tenga secciones __DWARF ni símbolos locales
    if [[ "$DWARF_SECTIONS" -gt 0 ]]; then
        echo "ERROR: rc dylib tiene secciones __DWARF ($DWARF_SECTIONS) — compila con 'make rc'"
        exit 1
    fi
    if [[ "$LOCAL_SYMS" -gt 5 ]]; then
        echo "ERROR: rc dylib tiene $LOCAL_SYMS símbolos locales — compila con 'make rc'"
        exit 1
    fi
    echo "[3/5] Ofuscación: OK (DWARF=$DWARF_SECTIONS local_syms=$LOCAL_SYMS)"
else
    echo "[3/5] Símbolos dev: sin restricción ($LOCAL_SYMS locales, $DWARF_SECTIONS DWARF)"
fi

# --- 4. Verificar que el install_name sea correcto ---
INSTALL_NAME=$(otool -D "$SRC_DYLIB" 2>/dev/null | tail -1 || true)
if [[ "$INSTALL_NAME" != "@rpath/FnMacBypass.dylib" ]]; then
    echo "WARN: install_name inesperado: $INSTALL_NAME (esperado @rpath/FnMacBypass.dylib)"
fi
echo "[4/5] install_name: $INSTALL_NAME"

# --- 5. Promoción ---
if [[ "$DST_CH" == "public" ]]; then
    # Caso especial: rc→public = empaquetar con make package
    echo "[5/5] Empaquetando como release final..."
    make -C "$ROOT" -C builds package CHANNEL=rc
    echo ""
    echo "=== Listo. Artefacto final en builds/release/ ==="
    echo "    Siguiente paso: gh release create v${VERSION} builds/release/*.dylib builds/release/manifest.json"
else
    # Copiar dylib al canal destino para que make <destino> la detecte
    DST_DIR="$ROOT/builds/$DST_CH"
    mkdir -p "$DST_DIR"
    cp "$SRC_DYLIB" "$DST_DIR/FnMacBypass.dylib"
    echo "[5/5] Copiado a $DST_DIR/"
    echo ""
    echo "=== Listo. Ahora compila el canal destino con sus propias flags: ==="
    echo "    make $DST_CH"
    echo ""
    echo "    (promote copia el origen como referencia; make $DST_CH recompila desde fuente)"
fi
