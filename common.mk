ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION  := $(shell cat $(ROOT)/VERSION)
CHANNEL  ?= dev
PRODUCT  ?= FnMacBypass
GH_USER  ?= AlexGRDev

ifeq ($(CHANNEL),public)
  CH_TAG :=
else ifeq ($(CHANNEL),beta)
  CH_TAG := -beta
else ifeq ($(CHANNEL),dev)
  CH_TAG := -dev
else
  $(error CHANNEL debe ser dev, beta o public)
endif

NAME         := FnMacBypass.dylib
MANIFEST_URL := https://github.com/$(GH_USER)/$(PRODUCT)/releases/latest/download/manifest.json
