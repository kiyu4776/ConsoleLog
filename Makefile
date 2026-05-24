TARGET := iphone:clang:latest:16.5
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ConsoleLog

$(TWEAK_NAME)_FILES = Tweak.xm
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit CoreGraphics
_THEOS_PLATFORM_DPKG_DEB_FLAGS = --nocheck

include $(THEOS_MAKE_PATH)/tweak.mk

# dylibのみ
after-all::
	mkdir -p packages
	cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/