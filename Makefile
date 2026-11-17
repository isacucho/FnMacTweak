TARGET := iphone:clang:latest:26.0
INSTALL_TARGET_PROCESSES = FortniteClient-IOS-Shipping
export PATH := $(PWD)/tools:$(PATH)
LDID = ldid
FnMacTweak_PACKAGE_FORMAT = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FnMacTweak

FnMacTweak_FILES = ./src/Tweak.xm ./src/FnOverlayWindow.m ./src/views/popupViewController.m ./src/globals.m ./lib/fishhook.c ./src/PerformanceGuard.m ./src/FnRuntime.m ./src/FnMouseCompatibility.xm ./src/FnAppearance.m ./src/FnGraphics.xm ./src/FnPanelInput.xm
FnMacTweak_FRAMEWORKS = UIKit CoreGraphics QuartzCore UniformTypeIdentifiers GameController Metal
FnMacTweak_CFLAGS = -fobjc-arc -O3 -Wno-c99-designator -Wno-error=c99-designator
FnMacTweak_PACKAGE_FORMAT = gzip

DEBUG = 0

include $(THEOS_MAKE_PATH)/tweak.mk

# Apply an ad-hoc signature for local injection.
after-all::
	@echo "Signing FnMacTweak-kbm..."
	@codesign -f -s - $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib
