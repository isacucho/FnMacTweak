# Compila las fuentes y enlaza la dylib en ../builds/$(PLATFORM)/.
VERSION  ?= $(shell cat ../VERSION)
PLATFORM ?= ios

ifeq ($(PLATFORM),ios)
  SDKNAME := iphoneos
  TARGET  := arm64-apple-ios17.0
else ifeq ($(PLATFORM),mac)
  SDKNAME := macosx
  TARGET  := arm64-apple-macos13.0
else
  $(error PLATFORM debe ser ios o mac)
endif

SDK     := $(shell xcrun --sdk $(SDKNAME) --show-sdk-path)
CXX     := xcrun --sdk $(SDKNAME) clang++
OUTDIR  := ../builds/$(PLATFORM)
OBJDIR  := $(OUTDIR)/obj
OUT     := $(OUTDIR)/FnFix.dylib

COMMON  := -target $(TARGET) -isysroot $(SDK) -I../includes -DMODULE_VERSION=\"$(VERSION)\" \
           -std=c++17 -O2 -g -Wall -Wextra -fvisibility=hidden -MMD -MP
OBJCXX  := -x objective-c++ -fobjc-arc
LDFLAGS := -target $(TARGET) -isysroot $(SDK) -dynamiclib \
           -install_name @executable_path/Frameworks/FnFix.dylib \
           -framework Foundation -framework CoreFoundation

CPP_SRC := $(wildcard *.cpp)
MM_SRC  := $(wildcard *.mm)
OBJS    := $(addprefix $(OBJDIR)/,$(CPP_SRC:.cpp=.o) $(MM_SRC:.mm=.o))

all: $(OUT)

$(OUT): $(OBJS)
	$(CXX) $(LDFLAGS) $^ -o $@

$(OBJDIR)/%.o: %.cpp | $(OBJDIR)
	$(CXX) $(COMMON) -c $< -o $@

$(OBJDIR)/%.o: %.mm | $(OBJDIR)
	$(CXX) $(COMMON) $(OBJCXX) -c $< -o $@

$(OBJDIR):
	mkdir -p $@

-include $(OBJS:.o=.d)

.PHONY: all
