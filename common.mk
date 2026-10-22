# Variables comunes a src/Makefile y builds/Makefile (nombre y canal de la dylib).
#   CHANNEL  dev (por defecto) | beta | public
#   PLATFORM ios (por defecto) | mac        SAN=1: ASan+UBSan, solo con PLATFORM=mac
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell cat $(ROOT)/VERSION)
CHANNEL  ?= dev
PLATFORM ?= ios
SAN      ?= 0

ifeq ($(CHANNEL),public)
  CH_TAG :=
else ifeq ($(CHANNEL),beta)
  CH_TAG := -beta
else ifeq ($(CHANNEL),dev)
  CH_TAG := -dev
else
  $(error CHANNEL debe ser dev, beta o public)
endif

ifeq ($(PLATFORM)$(SAN),ios0)
  PLAT_TAG :=
else ifeq ($(PLATFORM)$(SAN),mac0)
  PLAT_TAG := -mac
else ifeq ($(PLATFORM)$(SAN),mac1)
  PLAT_TAG := -mac-san
else
  $(error combinacion invalida: PLATFORM=$(PLATFORM) SAN=$(SAN) (SAN=1 exige PLATFORM=mac))
endif

# FnFixUpdate-V<version>[-beta|-dev][-mac|-mac-san].dylib ; public/iOS = FnFixUpdate-V<version>.dylib
NAME := FnFixUpdate-V$(VERSION)$(CH_TAG)$(PLAT_TAG).dylib
