from zxtouch.client import zxtouch
from zxtouch.toasttypes import TOAST_MESSAGE

device = zxtouch("127.0.0.1")
size_ok, size = device.get_screen_size()
scale_ok, scale = device.get_screen_scale()
orientation_ok, orientation = device.get_screen_orientation()

if size_ok and scale_ok and orientation_ok:
    message = "Screen: {width}x{height} scale {scale} orientation {orientation}".format(
        width=size["width"],
        height=size["height"],
        scale=scale,
        orientation=orientation,
    )
else:
    message = "Unable to read all screen info"

print(message)
device.show_toast(TOAST_MESSAGE, message, 4)
device.disconnect()
