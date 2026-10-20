PACKAGE_VERSION = 1.0.2
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosCT
ChangeInfoIosCT_FILES = Tweak.xm
ChangeInfoIosCT_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
ChangeInfoIosCT_FRAMEWORKS = Foundation CoreTelephony
# roothide: do NOT link libsubstrate(=libellekit) at load — binding the Swift
# ElleKit engine as a tweak dependency crashes the target at dyld-load time
# (before any constructor runs). Resolve MSHook* at runtime via flat/dynamic
# lookup from the injector's already-loaded ElleKit instead.
ChangeInfoIosCT_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
