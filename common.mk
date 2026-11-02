# Variables comunes: nombre de la dylib y canal de build.
#   CHANNEL  dev (por defecto) | beta | public
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell cat $(ROOT)/VERSION)
CHANNEL  ?= dev

ifeq ($(CHANNEL),public)
  CH_TAG :=
else ifeq ($(CHANNEL),beta)
  CH_TAG := -beta
else ifeq ($(CHANNEL),dev)
  CH_TAG := -dev
else
  $(error CHANNEL debe ser dev, beta o public)
endif

NAME := FnMacKickFix-V$(VERSION)$(CH_TAG).dylib
