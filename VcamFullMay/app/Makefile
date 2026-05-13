# VcamFullMay companion app — picks a video from Photos and copies it to
# /var/jb/etc/vcam/video.mp4 (where the tweak reads it).
# Build: THEOS_PACKAGE_SCHEME=rootless make package

PACKAGE_VERSION = 1.0.0
ARCHS = arm64 arm64e

TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VcamFullMayApp
VcamFullMayApp_FILES         = main.m
VcamFullMayApp_CFLAGS        = -fobjc-arc -Wno-deprecated-declarations -Wno-error
VcamFullMayApp_FRAMEWORKS    = UIKit Foundation AVFoundation Photos PhotosUI CoreLocation
VcamFullMayApp_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
