include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DockScrollerPrefs
DockScrollerPrefs_FILES = DSRootListController.m DSAppPickerController.m DSPrefsCommon.m
DockScrollerPrefs_INSTALL_PATH = /Library/PreferenceBundles
DockScrollerPrefs_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
DockScrollerPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
DockScrollerPrefs_FRAMEWORKS = UIKit Foundation
DockScrollerPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
