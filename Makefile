# Raiz: delega en includes/, src/ y builds/.
#   make                 dylib iOS (arm64) en builds/ios/
#   make PLATFORM=mac    dylib macOS, solo para pruebas locales
#   make check           compila cada cabecera por separado
#   make sanitize        macOS, -O0, ASan+UBSan, -Werror (builds/mac-san/)
#   make package         dylib firmada ad-hoc + manifest.json en builds/release/
#   make clean
VERSION  := $(shell cat VERSION)
PLATFORM ?= ios
export VERSION PLATFORM

.PHONY: all check sanitize package clean

all:
	$(MAKE) -C src

check:
	$(MAKE) -C includes check

sanitize:
	$(MAKE) -C src PLATFORM=mac SAN=1

package: all
	$(MAKE) -C builds package

clean:
	$(MAKE) -C builds clean
