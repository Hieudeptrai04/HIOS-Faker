PACKAGE_VERSION = 2.6.0
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosSafari
ChangeInfoIosSafari_FILES = Tweak.xm
ChangeInfoIosSafari_CFLAGS = -fobjc-arc
ChangeInfoIosSafari_FRAMEWORKS = Foundation
ChangeInfoIosSafari_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
