include $(THEOS)/makefiles/common.mk

# zxrunner — 守护进程，launchd 拉起，负责 exec /var/jb/usr/bin/python3
# PoC 阶段：启动时写 /tmp/zxrunner_probe，验证 daemon 能否 exec python

ZXRUNNER_NAME = zxrunner
zxrunner_FILES = main.m
zxrunner_ARCHS = arm64 arm64e
zxrunner_INSTALL_PATH = /usr/libexec

# rootless daemon：不签名或用 ldid 自签；PoC 阶段不指定 CODE_SIGN_ENTITLEMENTS
# 后续 socket server 常驻时可能需要 sandbox 相关 entitlement

include $(THEOS_MAKE_PATH)/program.mk
