TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockScroller

DockScroller_FILES = Tweak.x DSCommon.m DSDockOverlay.m DSDockManager.m
DockScroller_CFLAGS = -fobjc-arc -Wno-unused-function
DockScroller_LDFLAGS = -Wl,-undefined,dynamic_lookup
DockScroller_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
