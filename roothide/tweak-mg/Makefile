PACKAGE_VERSION = 1.0.1
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosMG
ChangeInfoIosMG_FILES = Tweak.xm fishhook.c
ChangeInfoIosMG_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
ChangeInfoIosMG_FRAMEWORKS = Foundation CoreFoundation UIKit IOKit SystemConfiguration CoreLocation WebKit AdSupport Security AVFoundation CoreMedia CoreVideo CoreImage
ChangeInfoIosMG_WEAK_FRAMEWORKS = CoreTelephony DeviceCheck AppTrackingTransparency PushKit
# roothide: do NOT hard-link libsubstrate(=libellekit) at load. Binding the Swift
# ElleKit engine as a load-time dependency makes dyld fail the tweak's load on
# roothide BEFORE any constructor runs, so MG never injects and the whole model
# spoof (MGCopyAnswer/sysctl/IORegistry) is dead — while CT, which already carries
# this flag, keeps working. Resolve MSHook* at runtime via flat/dynamic lookup from
# the injector's already-loaded ElleKit. Mirrors the CT fix (commit 79f75ee) that
# was never applied to MG.
ChangeInfoIosMG_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
