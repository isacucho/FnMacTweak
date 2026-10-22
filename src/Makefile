# Compila las fuentes de una vez y enlaza la dylib en ../builds/<canal>/ (ver ../common.mk).
# Sin objetos intermedios: builds/ solo contiene las dylib.
include ../common.mk

SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX     := xcrun --sdk iphoneos clang++
TARGET  := arm64-apple-ios17.0

# dev: -O0; beta y public: -O2. public define PRODUCTION (Logger.hpp silencia LOG_D/LOG_I).
OPT     := -O2
DEFINES := -DMODULE_VERSION=\"$(VERSION)\"
ifeq ($(CHANNEL),dev)
  OPT := -O0
endif
ifeq ($(CHANNEL),public)
  DEFINES += -DPRODUCTION
endif

OUTDIR  := ../builds/$(CHANNEL)
OUT     := $(OUTDIR)/$(NAME)

CPP_SRC := $(wildcard *.cpp)
MM_SRC  := $(wildcard *.mm)
HEADERS := $(wildcard ../includes/*.hpp ../includes/fndiag/*.hpp)

FLAGS   := -target $(TARGET) -isysroot $(SDK) -I../includes $(DEFINES) \
           -std=c++17 $(OPT) -g -Wall -Wextra -Werror -fvisibility=hidden
LDFLAGS := -dynamiclib -install_name @executable_path/Frameworks/$(NAME) \
           -framework Foundation -framework CoreFoundation

all: $(OUT)

# .cpp en C++ y .mm en ObjC++ con ARC, en una sola invocacion.
$(OUT): $(CPP_SRC) $(MM_SRC) $(HEADERS) Makefile ../common.mk ../VERSION
	mkdir -p $(OUTDIR)
	$(CXX) $(FLAGS) $(LDFLAGS) -x c++ $(CPP_SRC) -x objective-c++ -fobjc-arc $(MM_SRC) -o $@
	rm -rf $@.dSYM # el compilador la genera con -g; builds/ solo lleva dylib

.PHONY: all
