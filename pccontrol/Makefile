include $(THEOS)/makefiles/common.mk

TWEAK_NAME = pccontrol
pccontrol_FILES = Tweak.xm SocketServer.xm Touch.xm Screen.xm Task.xm Process.xm AlertBox.xm Common.xm Record.xm Play.xm Window.xm Toast.xm UIKeyboard.xm DeviceInfo.xm TouchIndicator/TouchIndicatorWindow.xm TouchIndicator/TouchIndicatorView.xm TouchIndicator/TouchIndicatorCoordinateView.xm TouchIndicator/TouchIndicatorViewList.xm ScriptPlayer.xm TextRecognization/VKOcrManager.xm TextRecognization/TextRecognizer.xm UpdateCache.xm ColorPicker.xm TemplateMatch.xm ScreenMatch.xm NetSpeedIndicator.xm TouchCoordinateIndicator.xm FloatingMenu.xm TapTestWindow.xm ScriptFunctions.xm FunctionWindow.xm FlowScript.xm PickOverlay.xm FlowWindow.xm Schedule.xm \
	../zxtouch/zxtouch/RemoteDashboardServer.m \
	../zxtouch/zxtouch/GCDWebServer/Core/GCDWebServerResponse.m \
	../zxtouch/zxtouch/GCDWebServer/Core/GCDWebServerRequest.m \
	../zxtouch/zxtouch/GCDWebServer/Core/GCDWebServerFunctions.m \
	../zxtouch/zxtouch/GCDWebServer/Core/GCDWebServer.m \
	../zxtouch/zxtouch/GCDWebServer/Core/GCDWebServerConnection.m \
	../zxtouch/zxtouch/GCDWebServer/Responses/GCDWebServerErrorResponse.m \
	../zxtouch/zxtouch/GCDWebServer/Responses/GCDWebServerFileResponse.m \
	../zxtouch/zxtouch/GCDWebServer/Responses/GCDWebServerDataResponse.m \
	../zxtouch/zxtouch/GCDWebServer/Responses/GCDWebServerStreamedResponse.m \
	../zxtouch/zxtouch/GCDWebServer/Requests/GCDWebServerURLEncodedFormRequest.m \
	../zxtouch/zxtouch/GCDWebServer/Requests/GCDWebServerMultiPartFormRequest.m \
	../zxtouch/zxtouch/GCDWebServer/Requests/GCDWebServerDataRequest.m \
	../zxtouch/zxtouch/GCDWebServer/Requests/GCDWebServerFileRequest.m
pccontrol_CFLAGS = -Wno-error -Wno-module-import-in-extern-c -fobjc-arc \
	-Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function \
	-Wno-format -Wno-return-type -Wno-incomplete-implementation \
	-Wno-unused-but-set-variable -Wno-macro-redefined -Wno-unicode-whitespace \
	-Wno-block-capture-autoreleasing -Wno-shadow-ivar -Wno-nonnull \
	-Wno-format-extra-args -DZX_DASHBOARD_SPRINGBOARD_SERVER=1 \
	-I../zxtouch/zxtouch/GCDWebServer/Core \
	-I../zxtouch/zxtouch/GCDWebServer/Responses \
	-I../zxtouch/zxtouch/GCDWebServer/Requests
pccontrol_FRAMEWORKS = UIKit AssetsLibrary AVFoundation CoreMedia CoreVideo CoreImage IOSurface IOMobileFramebuffer Accelerate MobileCoreServices QuartzCore
pccontrol_ARCHS = arm64 arm64e

pccontrol_PRIVATE_FRAMEWORKS = IOKit
pccontrol_LIBRARIES = substrate
pccontrol_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk

# ── zxrunner 守护进程 PoC（直接 clang 编译，不走 Theos program.mk）──
ZXRUNNER_SRC = $(THEOS_PROJECT_DIR)/zxrunner/main.m
ZXRUNNER_BIN = $(THEOS_OBJ_DIR)/zxrunner
ZXRUNNER_ARCH = -arch arm64 -arch arm64e
# iOS 15+ SDK，和 tweak 同 target
ZXRUNNER_SDK  = $(THEOS)/sdks/iphoneos$(THEOS_SDK_VERSION).sdk
ZXRUNNER_CLANG = $(THEOS)/toolchain/Xcode.xctoolchain/usr/bin/clang

zxrunner-bin:
	@echo "==> Building zxrunner daemon (PoC)..."
	$(ZXRUNNER_CLANG) $(ZXRUNNER_ARCH) \
		-isysroot $(ZXRUNNER_SDK) \
		-target arm64-apple-ios15.0 \
		-fobjc-arc -framework Foundation \
		$(ZXRUNNER_SRC) -o $(ZXRUNNER_BIN)
	@echo "zxrunner built → $(ZXRUNNER_BIN)"

# 把 daemon 二进制和 plist 放进 packages/<tweak>/ 让 dpkg 打包时带上
after-pccontrol-all:: zxrunner-bin
	@echo "==> Installing zxrunner into tweak bundle..."
	@mkdir -p $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec
	@cp $(ZXRUNNER_BIN) $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec/zxrunner
	@chmod 0755 $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec/zxrunner
	@mkdir -p $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/LaunchDaemons
	@cp $(THEOS_PROJECT_DIR)/zxrunner/resources/com.zjx.zxrunner.plist \
	   $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/LaunchDaemons/com.zjx.zxrunner.plist

after-install::
	install.exec "chown -R mobile:mobile /var/mobile/Library/ZXTouch && killall -9 SpringBoard; launchctl bootstrap system /Library/LaunchDaemons/com.zjx.zxrunner.plist 2>/dev/null || launchctl load /Library/LaunchDaemons/com.zjx.zxrunner.plist 2>/dev/null || true"
