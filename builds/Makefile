# Empaquetado y limpieza. Nada de lo generado aqui se versiona (ver README.md):
# las dylib viajan como assets de GitHub Releases.
# Canal que se empaqueta: public por defecto (make package CHANNEL=beta para un prerelease).
CHANNEL ?= public
include ../common.mk

REPO    ?= AlexGRDev/FnFixUpdate
SRC     := $(CHANNEL)/$(NAME)
REL     := release

.PHONY: package clean

# Copia la dylib iOS del canal a release/, la firma ad-hoc (Sideloadly la vuelve a
# firmar al inyectar) y genera manifest.json (version, download_url, sha256) que lee
# el Updater.
package:
	@test -f $(SRC) || { echo "falta builds/$(SRC): compila el canal primero"; exit 1; }
	rm -rf $(REL)
	mkdir -p $(REL)
	cp $(SRC) $(REL)/$(NAME)
	codesign --force --sign - $(REL)/$(NAME)
	@sha=$$(shasum -a 256 $(REL)/$(NAME) | cut -d' ' -f1); \
	printf '{\n  "version": "%s",\n  "download_url": "https://github.com/%s/releases/download/v%s/%s",\n  "sha256": "%s"\n}\n' \
		"$(VERSION)" "$(REPO)" "$(VERSION)" "$(NAME)" "$$sha" > $(REL)/manifest.json
	@echo "--- $(REL)/"; ls -1 $(REL)

# Borra toda la salida; se conservan Makefile y README.md.
clean:
	rm -rf dev beta public $(REL)
