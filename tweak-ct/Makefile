PACKAGE_VERSION = 4.3.1
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeInfoIosCT
ChangeInfoIosCT_FILES = Tweak.xm
ChangeInfoIosCT_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
ChangeInfoIosCT_FRAMEWORKS = Foundation CoreTelephony
ChangeInfoIosCT_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
