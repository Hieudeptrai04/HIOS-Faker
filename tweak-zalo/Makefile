PACKAGE_VERSION = 2.7.2
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosZalo
ChangeInfoIosZalo_FILES = Tweak.xm
ChangeInfoIosZalo_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ChangeInfoIosZalo_FRAMEWORKS = Foundation UIKit AdSupport CoreTelephony
ChangeInfoIosZalo_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
