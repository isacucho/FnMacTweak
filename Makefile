# Raiz: delega en includes/, src/ y builds/. La salida va a builds/<canal>/ (solo iOS arm64).
#   make | make dev   -O0                   builds/dev/
#   make beta         -O2                   builds/beta/
#   make public       -O2, PRODUCTION       builds/public/   (sin LOG_D/LOG_I)
#   make package      public firmada ad-hoc + manifest.json en builds/release/
#                     (make package CHANNEL=beta empaqueta la beta)
#   make check        compila cada cabecera por separado
#   make clean
.PHONY: all dev beta public package check clean

all: dev

dev:
	$(MAKE) -C src CHANNEL=dev

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
