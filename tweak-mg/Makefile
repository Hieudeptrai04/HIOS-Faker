PACKAGE_VERSION = 3.0.0
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosMG
ChangeInfoIosMG_FILES = Tweak.xm
ChangeInfoIosMG_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ChangeInfoIosMG_FRAMEWORKS = Foundation
ChangeInfoIosMG_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
