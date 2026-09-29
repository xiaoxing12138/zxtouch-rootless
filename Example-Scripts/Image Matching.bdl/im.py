from zxtouch.client import zxtouch
from zxtouch.toasttypes import *
import time

device = zxtouch("127.0.0.1")
template = "/var/mobile/Library/ZXTouch/scripts/examples/Image Matching.bdl/examples_folder.jpg"

toast_result = device.show_toast(TOAST_WARNING, "Matching the visible word: examples", 2, TOAST_TOP)
print("start toast result:", toast_result)
time.sleep(1.0)

started = time.time()
result_tuple = device.image_match(template)
elapsed = time.time() - started
print("image_match result:", result_tuple, "elapsed:", round(elapsed, 3))

if not result_tuple[0]:
    toast_result = device.show_toast(
        TOAST_ERROR,
        "No match. Best info in log. %.2fs" % elapsed,
        4,
        TOAST_TOP
    )
    print("failure toast result:", toast_result)
else:
    result_dict = result_tuple[1]
    toast_result = device.show_toast(
        TOAST_SUCCESS,
        "Found examples at X:%s Y:%s %.2fs" % (result_dict["x"], result_dict["y"], elapsed),
        4,
        TOAST_TOP
    )
    print("success toast result:", toast_result)

time.sleep(4.5)
device.disconnect()
