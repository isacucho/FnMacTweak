# Empaquetado y limpieza. Nada de lo generado aqui se versiona (ver README.md):
# las dylib viajan como assets de GitHub Releases.
VERSION := $(shell cat ../VERSION)
REPO    ?= AlexGRDev/FnFixUpdate
NAME    := FnFixUpdate-V$(VERSION).dylib
SRC     := ios/$(NAME)
REL     := release

.PHONY: package clean

# Copia la dylib iOS a release/, la firma ad-hoc (Sideloadly la vuelve a firmar
# al inyectar) y genera manifest.json (version, download_url, sha256) que lee el
# Updater.
package:
	@test -f $(SRC) || { echo "falta $(SRC): ejecuta 'make' en la raiz"; exit 1; }
	rm -rf $(REL)
	mkdir -p $(REL)
	cp $(SRC) $(REL)/$(NAME)
	codesign --force --sign - $(REL)/$(NAME)
	@sha=$$(shasum -a 256 $(REL)/$(NAME) | cut -d' ' -f1); \
	printf '{\n  "version": "%s",\n  "download_url": "https://github.com/%s/releases/download/v%s/%s",\n  "sha256": "%s"\n}\n' \
		"$(VERSION)" "$(REPO)" "$(VERSION)" "$(NAME)" "$$sha" > $(REL)/manifest.json
	@echo "--- $(REL)/"; ls -1 $(REL)

clean:
	rm -rf ios mac mac-san obj $(REL)
