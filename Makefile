export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = rootless

SUBPROJECTS = appdelegate zxtouch-binary pccontrol zxrunner

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "chown -R mobile:mobile /var/mobile/Library/ZXTouch && killall -9 SpringBoard; launchctl bootstrap system /Library/LaunchDaemons/com.zjx.zxrunner.plist 2>/dev/null || launchctl load /Library/LaunchDaemons/com.zjx.zxrunner.plist 2>/dev/null || true"
