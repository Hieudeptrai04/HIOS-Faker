PACKAGE_VERSION = 3.0.8
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosMG
ChangeInfoIosMG_FILES = Tweak.xm fishhook.c
ChangeInfoIosMG_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
ChangeInfoIosMG_FRAMEWORKS = Foundation CoreFoundation UIKit IOKit SystemConfiguration CoreLocation WebKit AdSupport
ChangeInfoIosMG_WEAK_FRAMEWORKS = CoreTelephony

include $(THEOS_MAKE_PATH)/tweak.mk
