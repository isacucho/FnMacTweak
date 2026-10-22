# Variables comunes a src/Makefile y builds/Makefile (nombre y canal de la dylib).
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

# FnFixUpdate-V<version>[-beta|-dev].dylib ; public = FnFixUpdate-V<version>.dylib
NAME := FnFixUpdate-V$(VERSION)$(CH_TAG).dylib
