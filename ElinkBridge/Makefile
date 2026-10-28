TARGET := iphone:clang:latest:14.5
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ElinkBridge
ElinkBridge_FILES = Tweak.xm src/ELBLog.m src/CarLifeProto.m src/CarLifeServer.m
ElinkBridge_CFLAGS = -fobjc-arc
ElinkBridge_FRAMEWORKS = Foundation UIKit SystemConfiguration
ElinkBridge_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# 设置面板资源放在 layout/ 下，Theos 打包时会自动并入 DEB
