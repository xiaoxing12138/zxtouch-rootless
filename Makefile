export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ZX_ROOT_PREFIX = /var/jb
else
ZX_ROOT_PREFIX =
endif
export ZX_ROOT_PREFIX

SUBPROJECTS = appdelegate zxtouch-binary pccontrol

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "chown -R mobile:mobile /var/mobile/Library/ZXTouch && killall SpringBoard; launchctl bootstrap gui/501 $(ZX_ROOT_PREFIX)/Library/LaunchAgents/com.zjx.zxrunner.plist 2>/dev/null || launchctl load $(ZX_ROOT_PREFIX)/Library/LaunchAgents/com.zjx.zxrunner.plist 2>/dev/null || true"
