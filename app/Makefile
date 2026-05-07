# ChangeInfoIos Standalone App Makefile
# Build: THEOS_PACKAGE_SCHEME=rootless make package

PACKAGE_VERSION = 2.4.0
ARCHS = arm64 arm64e

TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ChangeInfoIosApp
ChangeInfoIosApp_FILES = main.m
ChangeInfoIosApp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
ChangeInfoIosApp_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia Photos
ChangeInfoIosApp_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
