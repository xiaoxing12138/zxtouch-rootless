from zxtouch.client import zxtouch
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_UP
from zxtouch.toasttypes import TOAST_MESSAGE

device = zxtouch("127.0.0.1")
ok, size = device.get_screen_size()
if not ok:
    device.show_toast(TOAST_MESSAGE, "Could not read screen size", 2)
    device.disconnect()
    raise SystemExit

width = int(float(size["width"]))
height = int(float(size["height"]))
points = [(40, 40), (width - 40, 40), (width - 40, height - 40), (40, height - 40)]

device.show_toast(TOAST_MESSAGE, "Tapping four screen corners", 2)
for x, y in points:
    device.touch(TOUCH_DOWN, 1, x, y)
    device.accurate_usleep(80000)
    device.touch(TOUCH_UP, 1, x, y)
    device.accurate_usleep(180000)

device.disconnect()
