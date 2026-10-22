# Compila las fuentes y enlaza la dylib en ../builds/<canal>/ (ver ../common.mk).
include ../common.mk

ifeq ($(PLATFORM),ios)
  SDKNAME := iphoneos
  TARGET  := arm64-apple-ios17.0
else
  SDKNAME := macosx
  TARGET  := arm64-apple-macos13.0
endif

SDK     := $(shell xcrun --sdk $(SDKNAME) --show-sdk-path)
CXX     := xcrun --sdk $(SDKNAME) clang++

# dev: -O0. SAN=1 (solo macOS): ASan/UBSan, sin recuperacion. public: define PRODUCTION
# (Logger.hpp silencia LOG_D/LOG_I). beta y public: -O2.
OPT      := -O2
SANFLAGS :=
DEFINES  := -DMODULE_VERSION=\"$(VERSION)\"
ifeq ($(CHANNEL),dev)
  OPT := -O0
endif
ifeq ($(SAN),1)
  SANFLAGS := -fsanitize=address,undefined -fno-sanitize-recover=all
endif
ifeq ($(CHANNEL),public)
  DEFINES += -DPRODUCTION
endif

# builds/<canal>/<NAME> ; objetos en builds/<canal>/.obj/<plataforma>/
OUTDIR  := ../builds/$(CHANNEL)
OBJDIR  := $(OUTDIR)/.obj/$(PLATFORM)$(if $(filter 1,$(SAN)),-san)
OUT     := $(OUTDIR)/$(NAME)

COMMON  := -target $(TARGET) -isysroot $(SDK) -I../includes $(DEFINES) \
           -std=c++17 $(OPT) -g -Wall -Wextra -Werror $(SANFLAGS) -fvisibility=hidden -MMD -MP
OBJCXX  := -x objective-c++ -fobjc-arc
LDFLAGS := -target $(TARGET) -isysroot $(SDK) -dynamiclib \
           -install_name @executable_path/Frameworks/$(NAME) \
           $(SANFLAGS) -framework Foundation -framework CoreFoundation

CPP_SRC := $(wildcard *.cpp)
MM_SRC  := $(wildcard *.mm)
OBJS    := $(addprefix $(OBJDIR)/,$(CPP_SRC:.cpp=.o) $(MM_SRC:.mm=.o))

all: $(OUT)

$(OUT): $(OBJS) | $(OUTDIR)
	$(CXX) $(LDFLAGS) $^ -o $@

$(OBJDIR)/%.o: %.cpp | $(OBJDIR)
	$(CXX) $(COMMON) -c $< -o $@

$(OBJDIR)/%.o: %.mm | $(OBJDIR)
	$(CXX) $(COMMON) $(OBJCXX) -c $< -o $@

$(OBJDIR) $(OUTDIR):
	mkdir -p $@

-include $(OBJS:.o=.d)

.PHONY: all
