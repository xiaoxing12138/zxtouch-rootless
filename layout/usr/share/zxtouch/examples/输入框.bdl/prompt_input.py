from zxtouch.client import zxtouch
from zxtouch.toasttypes import TOAST_SUCCESS, TOAST_WARNING

device = zxtouch("127.0.0.1")
ok, value = device.prompt_input("ZXTouch Input", "Type something for this script.", "hello", "")
if ok:
    device.show_toast(TOAST_SUCCESS, "You typed: " + value, 3)
else:
    device.show_toast(TOAST_WARNING, "Input cancelled: " + value, 3)
device.disconnect()
