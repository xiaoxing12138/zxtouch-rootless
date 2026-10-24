import base64
import hashlib
import hmac
import json
import time
import urllib.parse
import urllib.request

from zxtouch.client import zxtouch
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP

设备 = zxtouch("127.0.0.1")


def 点(x, y, 次数=1, 间隔=0.02, 按住=0.02):
    x, y = int(round(float(x))), int(round(float(y)))
    for _ in range(max(1, int(float(次数)))):
        设备.touch(TOUCH_DOWN, 1, x, y)
        if 按住 > 0:
            time.sleep(按住)
        设备.touch(TOUCH_UP, 1, x, y)
        if 间隔 > 0:
            time.sleep(间隔)


def 滑(x1, y1, x2, y2, 时长=0.4):
    x1, y1, x2, y2 = (int(round(float(v))) for v in (x1, y1, x2, y2))
    步数 = 12
    设备.touch(TOUCH_DOWN, 1, x1, y1)
    for i in range(1, 步数 + 1):
        time.sleep(float(时长) / 步数)
        设备.touch(TOUCH_MOVE, 1, x1 + (x2 - x1) * i / 步数, y1 + (y2 - y1) * i / 步数)
    设备.touch(TOUCH_UP, 1, x2, y2)


def 取色(x, y):
    ok, c = 设备.pick_color(int(x), int(y))
    if not ok:
        return -1, -1, -1
    return int(c["red"]), int(c["green"]), int(c["blue"])


def 是色(x, y, 色, 容差=10):
    目标 = str(色).lstrip("#")
    r, g, b = 取色(x, y)
    return (abs(r - int(目标[0:2], 16)) <= 容差
            and abs(g - int(目标[2:4], 16)) <= 容差
            and abs(b - int(目标[4:6], 16)) <= 容差)


def 找色(x, y, 宽, 高, 色, 容差=10, 步长=1):
    目标 = str(色).lstrip("#")
    r, g, b = int(目标[0:2], 16), int(目标[2:4], 16), int(目标[4:6], 16)
    ok, 结果 = 设备.search_color((int(x), int(y), int(宽), int(高)),
                                 max(0, r - 容差), min(255, r + 容差),
                                 max(0, g - 容差), min(255, g + 容差),
                                 max(0, b - 容差), min(255, b + 容差), int(步长))
    if not ok:
        return None
    return int(结果["x"]), int(结果["y"])


def 数色(x, y, 宽, 高, 色="FFFFFF", 容差=10, 步长=1, 范围=None):
    if 范围 is None:
        目标 = str(色).lstrip("#")
        r, g, b = int(目标[0:2], 16), int(目标[2:4], 16), int(目标[4:6], 16)
        范围 = (max(0, r - 容差), min(255, r + 容差),
                max(0, g - 容差), min(255, g + 容差),
                max(0, b - 容差), min(255, b + 容差))
    ok, 数量 = 设备.count_color((int(x), int(y), int(宽), int(高)), *范围, int(步长))
    if not ok:
        return 0
    return int(数量)


def 找图(模板, 阈值=0.8, x=0, y=0, 宽=0, 高=0):
    ok, 结果 = 设备.image_match(模板, float(阈值), 0, 0.8, (int(x), int(y), int(宽), int(高)))
    if not ok:
        return None
    return (float(结果["x"]) + float(结果["width"]) / 2.0,
            float(结果["y"]) + float(结果["height"]) / 2.0)


def 识字(x, y, 宽, 高, 语言="zh-Hans,en-US"):
    语言列表 = [s for s in str(语言).replace("，", ",").split(",") if s]
    ok, 结果 = 设备.ocr((int(x), int(y), int(宽), int(高)), languages=语言列表)
    if not ok:
        return ""
    return "".join(str(项.get("text", "")) for 项 in 结果)


def 发送钉钉(webhook, 加签密钥="", 内容=""):
    地址 = str(webhook).strip()
    if not 地址:
        return False
    密钥 = str(加签密钥).strip()
    if 密钥:
        时间戳 = str(int(time.time() * 1000))
        待签 = "{}\n{}".format(时间戳, 密钥).encode("utf-8")
        签名 = urllib.parse.quote_plus(base64.b64encode(hmac.new(密钥.encode("utf-8"), 待签, hashlib.sha256).digest()))
        连接符 = "&" if "?" in 地址 else "?"
        地址 = "{}{}timestamp={}&sign={}".format(地址, 连接符, 时间戳, 签名)
    报文 = json.dumps({"msgtype": "text", "text": {"content": str(内容)}}).encode("utf-8")
    请求 = urllib.request.Request(地址, data=报文, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(请求, timeout=10) as 响应:
            响应.read()
        return True
    except Exception:
        return False


def 发送企业微信(webhook, 内容=""):
    地址 = str(webhook).strip()
    if not 地址:
        return False
    报文 = json.dumps({"msgtype": "text", "text": {"content": str(内容)}}).encode("utf-8")
    请求 = urllib.request.Request(地址, data=报文, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(请求, timeout=10) as 响应:
            响应.read()
        return True
    except Exception:
        return False
