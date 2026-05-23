PACKAGE_VERSION = 2.5.27
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosLocation
ChangeInfoIosLocation_FILES = Tweak.xm
ChangeInfoIosLocation_CFLAGS = -fobjc-arc
ChangeInfoIosLocation_FRAMEWORKS = Foundation CoreLocation
ChangeInfoIosLocation_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
