# ChangeInfoIos Tweak Makefile
# Build: THEOS_PACKAGE_SCHEME=rootless make package
# Install: make install THEOS_DEVICE_IP=<ip> THEOS_DEVICE_PORT=22

PACKAGE_VERSION = 2.3.19
ARCHS = arm64 arm64e

TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIos
ChangeInfoIos_FILES = Tweak.xm Hooks.mm
ChangeInfoIos_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
# Link every framework used by Tweak.xm/Hooks.mm. Missing framework → dylib
# has unresolved Obj-C classes at load time → ellekit/substrate skip inject
# silently. This was the v2.3.0–v2.3.4 "Tweak CHƯA inject" root cause.
ChangeInfoIos_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics \
                          CoreTelephony CoreLocation CoreMotion \
                          AdSupport SystemConfiguration WebKit Metal \
                          AVFoundation Security
ChangeInfoIos_PRIVATE_FRAMEWORKS = AppSupport
# MobileGestalt intentionally not linked — MGCopyAnswer is resolved at runtime
# via dlopen/dlsym in %ctor so we don't force-link the private dylib.

include $(THEOS_MAKE_PATH)/tweak.mk
