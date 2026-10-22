# Empaquetado y limpieza. Las dylib compiladas no se versionan: viajan como
# assets de GitHub Releases.
VERSION := $(shell cat ../VERSION)
REPO    ?= AlexGRDev/FnFixUpdate
REL     := release
DYLIB   := ios/FnFix.dylib

.PHONY: package clean

# Firma ad-hoc (Sideloadly la vuelve a firmar al inyectar) y genera el
# manifest.json que lee el Updater: version, download_url y sha256.
package:
	mkdir -p $(REL)
	cp $(DYLIB) $(REL)/FnFix.dylib
	codesign --force --sign - $(REL)/FnFix.dylib
	@sha=$$(shasum -a 256 $(REL)/FnFix.dylib | cut -d' ' -f1); \
	printf '{\n  "version": "%s",\n  "download_url": "https://github.com/%s/releases/download/v%s/FnFix.dylib",\n  "sha256": "%s"\n}\n' \
		"$(VERSION)" "$(REPO)" "$(VERSION)" "$$sha" > $(REL)/manifest.json
	@cat $(REL)/manifest.json

clean:
	rm -rf ios mac $(REL)
