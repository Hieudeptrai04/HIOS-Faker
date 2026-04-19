PACKAGE_VERSION = 1.0.0
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HelloInject
HelloInject_FILES = Tweak.xm
HelloInject_CFLAGS = -fobjc-arc
HelloInject_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
