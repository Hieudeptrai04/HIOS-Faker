PACKAGE_VERSION = 4.3.56
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = HIOSFakerV3
HIOSFakerV3_FILES = main.m
HIOSFakerV3_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
HIOSFakerV3_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia Photos Security Contacts CoreLocation
HIOSFakerV3_LIBRARIES = sqlite3
HIOSFakerV3_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
