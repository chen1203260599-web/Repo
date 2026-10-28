TARGET := iphone:clang:latest:14.5
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ElinkBridge
ElinkBridge_FILES = Tweak.xm src/ELBLog.m src/CarLifeProto.m src/CarLifeServer.m
ElinkBridge_CFLAGS = -fobjc-arc
ElinkBridge_FRAMEWORKS = Foundation UIKit SystemConfiguration
ElinkBridge_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
# 固定修订号：每次构建产出同名 DEB（com.elinkbridge.ios_1.0.0-1+debug_iphoneos-arm64.deb），
# 配合 workflow 发布前清理旧包，保证源内每个包只有最新一个版本
ElinkBridge_REVISION = 1

include $(THEOS_MAKE_PATH)/tweak.mk

# 设置面板资源放在 layout/ 下，Theos 打包时会自动并入 DEB
