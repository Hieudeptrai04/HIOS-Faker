# ChangeInfoIos Tweak Makefile
# Build: THEOS_PACKAGE_SCHEME=rootless make package
# Install: make install THEOS_DEVICE_IP=<ip> THEOS_DEVICE_PORT=22

PACKAGE_VERSION = 2.2.1
ARCHS = arm64 arm64e

TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIos
ChangeInfoIos_FILES = Tweak.xm Hooks.mm
ChangeInfoIos_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
ChangeInfoIos_FRAMEWORKS = UIKit Foundation CoreTelephony CoreLocation SystemConfiguration Security AdSupport WebKit IOKit CoreMotion Metal AppTrackingTransparency MobileCoreServices
# MobileGestalt intentionally not linked — MGCopyAnswer is resolved at
# runtime via dlopen/dlsym (see Tweak.xm:1072), and some SDK packages
# ship without a PrivateFrameworks/MobileGestalt.tbd stub.
ChangeInfoIos_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk
