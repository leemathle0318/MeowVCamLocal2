ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
THEOS ?= $(HOME)/theos
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MeowVCamLocalMedia MeowVCamLocalMenu
MeowVCamLocalMedia_FILES = tweak/SystemCapture.m tweak/MMEngine.m core/MMRemoteDecoder.c core/MMIPC.c core/MMTimeline.c core/MMAudioMix.c
MeowVCamLocalMedia_CFLAGS = -O2 -Wno-deprecated-declarations
MeowVCamLocalMedia_OBJCFLAGS = -fobjc-arc
MeowVCamLocalMedia_FRAMEWORKS = Foundation AVFoundation AudioToolbox CoreMedia CoreVideo CoreImage CoreGraphics
MeowVCamLocalMedia_LIBRARIES = substrate
MeowVCamLocalMenu_FILES = tweak/LocalMenu.m core/MMHotkey.c
MeowVCamLocalMenu_CFLAGS = -O2
MeowVCamLocalMenu_OBJCFLAGS = -fobjc-arc
MeowVCamLocalMenu_FRAMEWORKS = Foundation UIKit UniformTypeIdentifiers QuartzCore PhotosUI
MeowVCamLocalMenu_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += daemon
include $(THEOS_MAKE_PATH)/aggregate.mk
