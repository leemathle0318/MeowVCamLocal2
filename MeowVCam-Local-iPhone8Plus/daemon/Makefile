ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TOOL_NAME = MeowVCamLocalDecoder
MeowVCamLocalDecoder_FILES = main.m ../core/MMLocalDecoder.m ../core/MMIPC.c
MeowVCamLocalDecoder_CFLAGS = -O2 -Wno-deprecated-declarations
MeowVCamLocalDecoder_OBJCFLAGS = -fobjc-arc
MeowVCamLocalDecoder_FRAMEWORKS = Foundation AVFoundation AudioToolbox CoreMedia CoreVideo CoreGraphics
MeowVCamLocalDecoder_INSTALL_PATH = /usr/libexec/meowvcam-local
include $(THEOS_MAKE_PATH)/tool.mk
