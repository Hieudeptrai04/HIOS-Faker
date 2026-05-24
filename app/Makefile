PACKAGE_VERSION = 3.0.0
ARCHS = arm64
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = HIOSFakerV3
HIOSFakerV3_FILES = main.m
HIOSFakerV3_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
HIOSFakerV3_FRAMEWORKS = UIKit Foundation Security CoreTelephony AdSupport AppTrackingTransparency
HIOSFakerV3_CODESIGN_FLAGS = -Sentitlements.plist
HIOSFakerV3_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
