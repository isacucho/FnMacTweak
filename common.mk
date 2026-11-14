ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell cat $(ROOT)/VERSION)
CHANNEL  ?= dev
PRODUCT  ?= FnMacUpdateFix
GH_USER  ?= AlexGRDev

# Pipeline de publicación: dev → beta → rc → public
#   dev    : símbolos completos, logs extendidos, solo pruebas internas
#   beta   : símbolos (-g), optimización, distribución a testers externos
#   rc     : release candidate — ofuscación máxima, sin símbolos, listo para validar
#   public : release final (mismos flags que rc; CH_TAG vacío en el artefacto)
ifeq ($(CHANNEL),public)
  CH_TAG     :=
  CH_LABEL   := Public
else ifeq ($(CHANNEL),rc)
  CH_TAG     := -rc
  CH_LABEL   := RC
else ifeq ($(CHANNEL),beta)
  CH_TAG     := -beta
  CH_LABEL   := PublicBeta
else ifeq ($(CHANNEL),dev)
  CH_TAG     := -dev
  CH_LABEL   := Dev
else
  $(error CHANNEL debe ser dev, beta, rc o public)
endif

NAME         := FnMacBypass.dylib
# Artefactos nombrados por canal: FnMacBypass-V<ver>-<label>.dylib / .ipa
ARTIFACT     := FnMacBypass-V$(VERSION)$(CH_TAG)
MANIFEST_URL := https://github.com/$(GH_USER)/$(PRODUCT)/releases/latest/download/manifest.json
