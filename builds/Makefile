# Empaquetado y limpieza. builds/ solo contiene dev/, beta/, rc/, public/ y release/
# (todo generado, nada se versiona): los artefactos viajan como assets de GitHub Releases.
#
# Pipeline: dev → beta → rc → (release final como public)
#   make package CHANNEL=dev    → FnMacBypass-V<ver>-dev.dylib   (pruebas internas)
#   make package CHANNEL=beta   → FnMacBypass-V<ver>-beta.dylib  (testers externos)
#   make package CHANNEL=rc     → FnMacBypass-V<ver>-rc.dylib    (release candidate)
#   make package CHANNEL=public → FnMacBypass-V<ver>.dylib       (release final)
CHANNEL ?= rc
include ../common.mk

REPO    ?= AlexGRDev/FnMacUpdateFix
SRC     := $(CHANNEL)/$(ARTIFACT).dylib
REL     := release
# Artefacto con nombre de canal: FnMacBypass-V23.7.8-rc.dylib etc.
OUT_DYLIB := $(REL)/$(ARTIFACT).dylib

.PHONY: package clean

# Genera en release/:
#   <ARTIFACT>.dylib     — dylib firmada ad-hoc (Sideloadly vuelve a firmar al inyectar)
#   manifest.json        — versión, URL de descarga, sha256, canal (leído por Updater)
#   channel.txt          — nombre de canal para FnMacAssistant
package:
	@test -f $(SRC) || { echo "ERROR: falta builds/$(SRC) — compila primero: make $(CHANNEL)"; exit 1; }
	rm -rf $(REL)
	mkdir -p $(REL)
	cp $(SRC) $(OUT_DYLIB)
	codesign --force --sign - $(OUT_DYLIB)
	@sha=$$(shasum -a 256 $(OUT_DYLIB) | cut -d' ' -f1); \
	 dl_name=$(ARTIFACT).dylib; \
	 printf '{\n  "version": "%s",\n  "channel": "%s",\n  "artifact": "%s",\n  "download_url": "https://github.com/%s/releases/download/v%s/%s",\n  "sha256": "%s"\n}\n' \
		"$(VERSION)" "$(CHANNEL)" "$$dl_name" "$(REPO)" "$(VERSION)" "$$dl_name" "$$sha" \
		> $(REL)/manifest.json
	@echo "$(CHANNEL)" > $(REL)/channel.txt
	@echo "--- $(REL)/ [canal=$(CHANNEL) label=$(CH_LABEL)]"; ls -1 $(REL)
	@echo "Artefacto: $(OUT_DYLIB)"

# Borra toda la salida generada.
clean:
	rm -rf dev beta rc public $(REL)
