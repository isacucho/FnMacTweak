FW_DIR := /Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/Frameworks
INSTALLED_NAME := FnMacBypass.dylib

.PHONY: all dev beta rc public package clean install

include common.mk

SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX     := xcrun --sdk iphoneos clang++
TARGET  := arm64-apple-ios17.0

# --- Flags por canal -------------------------------------------------
# dev    : sin optimización, símbolos completos, logs extendidos
# beta   : optimización media, símbolos (gdb/lldb útil para testers)
# rc     : release candidate — ofuscación máxima, sin DWARF, sin símbolos locales
# public : igual que rc (release final, CH_TAG vacío en el artefacto)
OPT        := -O2
DEBUG_FLAGS :=
STRIP_FLAGS :=
DEFINES := -DMODULE_VERSION=\"$(VERSION)\" -DUPDATE_MANIFEST_URL=\"$(MANIFEST_URL)\"
ifeq ($(CHANNEL),dev)
  OPT         := -O0
  DEBUG_FLAGS := -g
else ifeq ($(CHANNEL),beta)
  DEBUG_FLAGS := -g
else ifeq ($(CHANNEL),rc)
  DEFINES     += -DPRODUCTION
  OPT         := -O3
  # -x: sin simbolos locales; -S: sin DWARF; -dead_strip: elimina codigo muerto
  STRIP_FLAGS := -Wl,-x -Wl,-S -Wl,-dead_strip
else ifeq ($(CHANNEL),public)
  DEFINES     += -DPRODUCTION
  OPT         := -O3
  STRIP_FLAGS := -Wl,-x -Wl,-S -Wl,-dead_strip
endif

OUTDIR  := builds/$(CHANNEL)
OUT     := $(OUTDIR)/$(ARTIFACT).dylib

# Fuentes C++ puro (sin ObjC)
CPP_SRC := \
    src/core/Config.cpp \
    src/core/DiagLog.cpp \
    src/core/GameLogMirror.cpp \
    src/hooks/ObjcUtil.cpp \
    src/update/FileHooks.cpp \
    src/update/TerrainPatcher.cpp \
    src/update/KickPatcher.cpp \
    src/update/NmtPatcher.cpp \
    src/update/CustomizationPatcher.cpp \
    src/input/FpsUnlock.cpp \
    src/input/InputIni.cpp \
    src/input/NativeKbm.cpp \
    src/eos/EosHooks.cpp \
    src/eos/CompatReport.cpp

# Fuentes ObjC++ (compilados con -fobjc-arc)
MM_SRC := \
    src/Core.mm \
    src/core/OsLogInterceptor.mm \
    src/core/LogSpoofer.mm \
    src/metadata/DeviceSpoof.mm \
    src/update/EngineHooks.mm \
    src/update/ContentPatch.mm \
    src/update/OtaUpdater.mm \
    src/update/GameUpdater.mm \
    src/input/InputProbe.mm \
    src/network/StatusCodeFix.mm \
    src/network/NetInspect.mm \
    src/gpu/MetalPurge.mm

HEADERS := $(shell find include -name '*.hpp')

FLAGS := \
    -target $(TARGET) -isysroot $(SDK) \
    -I./include \
    $(DEFINES) \
    -std=c++17 $(OPT) $(DEBUG_FLAGS) \
    -Wall -Wextra -Werror \
    -fvisibility=hidden \
    -fvisibility-inlines-hidden

LDFLAGS := \
    -dynamiclib \
    -install_name @rpath/$(NAME) \
    -Wl,-current_version,$(VERSION) \
    -Wl,-compatibility_version,1.0.0 \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-w \
    $(STRIP_FLAGS) \
    -framework Foundation \
    -framework CoreFoundation \
    -framework Security \
    -framework GameController \
    -framework Metal

all: dev

dev:
	$(MAKE) CHANNEL=dev _build

beta:
	$(MAKE) CHANNEL=beta _build

rc:
	$(MAKE) CHANNEL=rc _build

public:
	$(MAKE) CHANNEL=public _build

# DEV=1 / BETA=1 / RC=1 / PRODUCTION=1 como atajos
DEV=
BETA=
RC=
PRODUCTION=
ifneq ($(DEV),)
  override CHANNEL := dev
endif
ifneq ($(BETA),)
  override CHANNEL := beta
endif
ifneq ($(RC),)
  override CHANNEL := rc
endif
ifneq ($(PRODUCTION),)
  override CHANNEL := rc
endif

# package: empaqueta el canal indicado (por defecto rc) en builds/release/
# Genera: <ARTIFACT>.dylib + manifest.json
package:
	$(MAKE) CHANNEL=$(or $(CHANNEL),rc) _build
	$(MAKE) -C builds package CHANNEL=$(or $(CHANNEL),rc)

install: dev
	cp builds/dev/FnMacBypass-V$(VERSION)-dev.dylib $(FW_DIR)/$(INSTALLED_NAME)
	@echo "installed $(NAME) as $(INSTALLED_NAME)"
	@md5 builds/dev/$(NAME) $(FW_DIR)/$(INSTALLED_NAME)

clean:
	rm -rf builds/dev builds/beta builds/rc builds/public builds/release

_build: $(OUT)

$(OUT): $(CPP_SRC) $(MM_SRC) $(HEADERS) Makefile common.mk VERSION
	mkdir -p $(OUTDIR)
	$(CXX) $(FLAGS) $(LDFLAGS) \
	    -x c++ $(CPP_SRC) \
	    -x objective-c++ -fobjc-arc $(MM_SRC) \
	    -o $@
	rm -rf $@.dSYM

.PHONY: _build
