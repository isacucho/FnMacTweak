FW_DIR := /Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/Frameworks
INSTALLED_NAME := FnMacBypass.dylib

.PHONY: all dev beta public package clean install

include common.mk

SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX     := xcrun --sdk iphoneos clang++
TARGET  := arm64-apple-ios17.0

OPT        := -O2
DEBUG_FLAGS :=
STRIP_FLAGS :=
DEFINES := -DMODULE_VERSION=\"$(VERSION)\" -DUPDATE_MANIFEST_URL=\"$(MANIFEST_URL)\"
ifeq ($(CHANNEL),dev)
  OPT         := -O0
  DEBUG_FLAGS := -g
else ifeq ($(CHANNEL),beta)
  DEBUG_FLAGS := -g
else ifeq ($(CHANNEL),public)
  DEFINES     += -DPRODUCTION
  # Strip all local symbols and debug sections from the output dylib.
  # -Wl,-x : remove local (non-exported) symbols
  # -Wl,-S : strip debug info (__DWARF sections)
  # Together these eliminate function names, source paths and line numbers
  # from the distributed binary, complementing -fvisibility=hidden.
  STRIP_FLAGS := -Wl,-x -Wl,-S
endif

OUTDIR  := builds/$(CHANNEL)
OUT     := $(OUTDIR)/$(NAME)

# Fuentes C++ puro (sin ObjC)
CPP_SRC := \
    src/core/Config.cpp \
    src/core/DiagLog.cpp \
    src/core/GameLogMirror.cpp \
    src/hooks/ObjcUtil.cpp \
    src/update/FileHooks.cpp \
    src/update/SessionOverride.cpp \
    src/update/TerrainPatcher.cpp \
    src/update/KickPatcher.cpp \
    src/update/NmtPatcher.cpp \
    src/update/NetFailurePatcher.cpp \
    src/update/CustomizationPatcher.cpp \
    src/input/FpsUnlock.cpp \
    src/input/InputIni.cpp \
    src/input/NativeKbm.cpp \
    src/eos/EosHooks.cpp \
    src/eos/MkwBypass.cpp

# Fuentes ObjC++ (compilados con -fobjc-arc)
MM_SRC := \
    src/Core.mm \
    src/core/OsLogInterceptor.mm \
    src/core/LogSpoofer.mm \
    src/metadata/DeviceSpoof.mm \
    src/network/EacHooks.mm \
    src/update/EngineHooks.mm \
    src/update/NetworkHooks.mm \
    src/update/ContentPatch.mm \
    src/update/Updater.mm \
    src/input/InputProbe.mm

HEADERS := $(shell find include -name '*.hpp')

FLAGS := \
    -target $(TARGET) -isysroot $(SDK) \
    -I./include \
    $(DEFINES) \
    -std=c++17 $(OPT) $(DEBUG_FLAGS) \
    -Wall -Wextra -Werror \
    -fvisibility=hidden

LDFLAGS := \
    -dynamiclib \
    -install_name @rpath/$(NAME) \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-w \
    $(STRIP_FLAGS) \
    -framework Foundation \
    -framework CoreFoundation \
    -framework Security \
    -framework GameController

all: dev

dev:
	$(MAKE) CHANNEL=dev _build

beta:
	$(MAKE) CHANNEL=beta _build

public:
	$(MAKE) CHANNEL=public _build

package: public
	$(MAKE) -C builds package CHANNEL=public

install: dev
	cp builds/dev/$(NAME) $(FW_DIR)/$(INSTALLED_NAME)
	@echo "installed $(NAME) as $(INSTALLED_NAME)"
	@md5 builds/dev/$(NAME) $(FW_DIR)/$(INSTALLED_NAME)

clean:
	rm -rf builds/dev builds/beta builds/public builds/release

_build: $(OUT)

$(OUT): $(CPP_SRC) $(MM_SRC) $(HEADERS) Makefile common.mk VERSION
	mkdir -p $(OUTDIR)
	$(CXX) $(FLAGS) $(LDFLAGS) \
	    -x c++ $(CPP_SRC) \
	    -x objective-c++ -fobjc-arc $(MM_SRC) \
	    -o $@
	rm -rf $@.dSYM

.PHONY: _build
