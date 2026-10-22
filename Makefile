# Raiz: delega en includes/, src/ y builds/. La salida va a builds/<canal>/.
#   make | make dev        iOS arm64, -O0               builds/dev/
#   make sanitize          macOS, ASan+UBSan, -O0       builds/dev/
#   make mac               macOS, para pruebas locales  builds/dev/
#   make beta              iOS arm64, -O2               builds/beta/
#   make public            iOS arm64, -O2, PRODUCTION   builds/public/
#   make package           public (o CHANNEL=beta) firmada ad-hoc + manifest.json en builds/release/
#   make check             compila cada cabecera por separado
#   make clean
.PHONY: all dev sanitize mac beta public package check clean

all: dev

dev:
	$(MAKE) -C src CHANNEL=dev

sanitize:
	$(MAKE) -C src CHANNEL=dev PLATFORM=mac SAN=1

mac:
	$(MAKE) -C src CHANNEL=dev PLATFORM=mac

beta:
	$(MAKE) -C src CHANNEL=beta

public:
	$(MAKE) -C src CHANNEL=public

package: public
	$(MAKE) -C builds package CHANNEL=public

check:
	$(MAKE) -C includes check

clean:
	$(MAKE) -C builds clean
