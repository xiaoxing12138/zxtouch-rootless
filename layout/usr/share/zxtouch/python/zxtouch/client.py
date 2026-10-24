import time
import socket
from zxtouch import tasktypes
from zxtouch import datahandler
from zxtouch import kbdtasktypes
from zxtouch import deviceinfotasktypes
from zxtouch import colorsearchtasktypes


class zxtouch:
    def __init__(self, ip):
        self.s = socket.socket()
        self._recv_buffer = bytearray()
        self.s.connect((str(ip), 6000))
        time.sleep(0.1)

    def _recv_line(self):
        """Receive one CRLF-terminated protocol line without losing extra bytes."""
        delimiter = b"\r\n"
        while True:
            delimiter_index = self._recv_buffer.find(delimiter)
            if delimiter_index >= 0:
                line_end = delimiter_index + len(delimiter)
                line = bytes(self._recv_buffer[:line_end])
                del self._recv_buffer[:line_end]
                return line

            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("ZXTouch connection closed before a complete response header was received")
            self._recv_buffer.extend(chunk)
            if len(self._recv_buffer) > 1024 * 1024:
                raise RuntimeError("ZXTouch response header exceeds 1 MiB")

    def _recv_exact(self, size):
        """Receive exactly size bytes, preserving any following response bytes."""
        if size < 0:
            raise ValueError("size must not be negative")

        while len(self._recv_buffer) < size:
            remaining = size - len(self._recv_buffer)
            chunk = self.s.recv(remaining)
            if not chunk:
                raise ConnectionError(
                    "ZXTouch connection closed after {}/{} screenshot bytes".format(
                        len(self._recv_buffer), size
                    )
                )
            self._recv_buffer.extend(chunk)

        data = bytes(self._recv_buffer[:size])
        del self._recv_buffer[:size]
        return data

    def _recv_response(self):
        return datahandler.decode_socket_data(self._recv_line())

    def screenshot(self) -> bytes:
        """Capture the current screen and return its raw JPEG bytes over TCP."""
        self.s.sendall(datahandler.format_socket_data(tasktypes.TASK_SCREENSHOT))

        header = self._recv_line()[:-2]
        fields = header.split(b";;")
        if not fields or fields[0] != b"0":
            error_message = "Unknown screenshot error"
            if len(fields) >= 2 and fields[1]:
                error_message = fields[1].decode("utf-8", errors="replace")
            raise RuntimeError("ZXTouch screenshot failed: {}".format(error_message))

        if len(fields) != 3:
            raise RuntimeError("Malformed ZXTouch screenshot response header")

        try:
            content_type = fields[1].decode("ascii")
            content_length = int(fields[2].decode("ascii"))
        except (UnicodeDecodeError, ValueError) as error:
            raise RuntimeError("Malformed ZXTouch screenshot response header") from error

        if content_type != "image/jpeg":
            raise RuntimeError("Unexpected ZXTouch screenshot content type: {}".format(content_type))
        if content_length <= 0:
            raise RuntimeError("Invalid ZXTouch screenshot content length: {}".format(content_length))

        return self._recv_exact(content_length)

    def touch(self, type, finger_index, x, y):
        """Perform a touch event

        :param type: touch type
        :param finger_index: which finger you want to perform touch
        :param x: x coordinate
        :param y: y coordinate
        :return: None
        """
        if int(type) > 19:
            print("Touch index should not be greater than 19.")
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PERFORM_TOUCH,
                                                   '1{}{:02d}{:05d}{:05d}'.format(type, finger_index, int(x * 10),
                                                                                  int(y * 10))))

    def touch_with_list(self, touch_list: list):
        """Perform touch events with a list of events
        touch list should be a list of dictionary that you want to perform touch with following format

        :param touch_list: [{"type": ?, "finger_index": ?, "x": ?, "y": ?}]
        :return: None
        """
        event_data = ''
        for touch_event in touch_list:
            event_data += '{}{:02d}{:05d}{:05d}'.format(touch_event['type'], touch_event['finger_index'],
                                                        touch_event['x'] * 10,
                                                        touch_event['y'] * 10)
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PERFORM_TOUCH, str(len(touch_list)) + event_data))

    def switch_to_app(self, bundle_identifier):
        """Bring an application to foreground

        :param bundle_identifier: the bundle identifier of the application
        :return: Result tuple

        The format of the result tuple:
        result_tuple[0]: True if no error happens when executing the command on your device. False otherwise
        result_tuple[1]: error info if result_tuple[0] == False. Otherwise ""
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PROCESS_BRING_FOREGROUND, bundle_identifier))
        return self._recv_response()

    def go_home(self):
        """Return to the home screen

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GO_HOME))
        return self._recv_response()

    def kill_app(self, bundle_identifier):
        """Kill a running application (remove it from the app switcher)

        :param bundle_identifier: the bundle identifier of the application
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_KILL_APP, bundle_identifier))
        return self._recv_response()

    def play_ring(self, sound, seconds=3):
        """Play a system ringtone

        :param sound: ringtone file name (searched in the system ringtone folder) or an absolute path
        :param seconds: how long to keep playing
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PLAY_RING, sound, seconds))
        return self._recv_response()

    def set_volume(self, percent):
        """Set the device volume to an absolute level

        :param percent: volume level, 0 - 100
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SET_VOLUME, "percent", percent))
        return self._recv_response()

    def change_volume(self, steps):
        """Raise or lower the device volume by a number of system steps (1 step = 1/16)

        :param steps: positive to raise, negative to lower
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SET_VOLUME, "delta", steps))
        return self._recv_response()

    def change_volume_percent(self, percent):
        """Raise or lower the device volume by a percentage of the full scale

        :param percent: positive to raise, negative to lower, 0 - 100
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SET_VOLUME, "deltaPercent", percent))
        return self._recv_response()

    def stop_all_scripts(self):
        """Stop every script that is currently running

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_STOP_ALL_SCRIPTS))
        return self._recv_response()

    def make_call(self, number, sim="default"):
        """Place a phone call

        :param number: the phone number to dial
        :param sim: which SIM to use: "default" / "1" / "2"
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_MAKE_CALL, number, sim))
        return self._recv_response()

    def send_sms(self, number, text, sim="default"):
        """Send an SMS

        :param number: the phone number to send to
        :param text: the message body
        :param sim: which SIM to use: "default" / "1" / "2"
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SEND_SMS, number, text, sim))
        return self._recv_response()

    def set_wifi(self, enabled):
        """Turn Wi-Fi on or off

        :param enabled: True to turn Wi-Fi on, False to turn it off
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SET_WIFI, "1" if enabled else "0"))
        return self._recv_response()

    def save_screenshot(self):
        """Take a screenshot in the background and save it into the photo library

        No system screenshot preview is shown.

        :return: Result tuple: (success?, error_message/file path)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SAVE_SCREENSHOT))
        return self._recv_response()

    def show_alert_box(self, title, content, duration):
        """Show alert box on device

        Args:
            title: title of the alert box
            content: content of the alert box
            duration: the time the alert box shows before disappear

        Returns:
            Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SHOW_ALERT_BOX, title, content, duration))
        return self._recv_response()

    def run_shell_command(self, command):
        """Run shell command on device as root

        :param command: command to run
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_RUN_SHELL, command))
        return self._recv_response()

    def prompt_input(self, title="ZXTouch", message="", placeholder="", default_value=""):
        """Ask the user for text using a native alert.

        Returns:
            Result tuple: (success?, entered_text/error_message)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PROMPT_INPUT, title, message, placeholder, default_value))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, result[1][0] if len(result[1]) else ""

    def start_touch_recording(self):
        """Start recording touch events

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_TOUCH_RECORDING_START))
        return self._recv_response()

    def stop_touch_recording(self):
        """Stop recording touch events

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_TOUCH_RECORDING_STOP))
        return self._recv_response()

    def accurate_usleep(self, microseconds):
        """Don't know why, but python on ios will not sleep accurately sometimes. So you can use this to sleep

        :param microseconds: microseconds to sleep
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_USLEEP, microseconds))
        return self._recv_response()

    def play_script(self, script_absolute_path):
        """Play a script

        :param script_absolute_path: the absolute path of the script
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PLAY_SCRIPT, script_absolute_path))
        return self._recv_response()

    def force_stop_script_play(self):
        """Force stopping playing current script"""
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_PLAY_SCRIPT_FORCE_STOP))
        return self._recv_response()

    def image_match(self, template_path, acceptable_value=0.8, max_try_times=2, scaleRation=0.8, region=(0, 0, 0, 0)):
        """Get the coordinate of a image

        :param template_path: template path on your ios device
        :param acceptable_value: for a successful match, the acceptable value
        :param max_try_times: how many times you want to try with different size of the template
        :param scaleRation: for each time you try, what the template size should be
        :param region: (x, y, width, height) search region, width or height 0 means the whole screen

        :return: Result tuple: (success?, error_message/return value)
                 success 时返回的字典除 x/y/width/height 外，还含 "score"（本次扫到的最高匹配分）
                 失败时 error_message 里也已经带了「最高得分：x.xxx，要求得分：x.xxx」
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_TEMPLATE_MATCH, template_path, max_try_times,
                                                   acceptable_value, scaleRation,
                                                   region[0], region[1], region[2], region[3]))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        return True, {"x": result[1][0], "y": result[1][1], "width": result[1][2], "height": result[1][3],
                      "score": float(result[1][4]) if len(result[1]) > 4 else 0.0}

    def show_toast(self, toast_type, content, duration, position=0, fontSize=0):
        """Show toast on ios device

        :param type: type of the toast.
        :param content: content of the toast
        :param duration: duration of the toast
        :param position: position of the toast. 0 for top, 1 for bottom
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_SHOW_TOAST, toast_type, content, duration, position,
                                                   fontSize))
        return self._recv_response()

    def pick_color(self, x, y):
        """Get the rgb value from the screen. The format returned is (red, green, blue)

        :param x: x coordinate of the point on the screen
        :param y: y coordinate of the point on the screen
        :return: Result tuple: (success?, error_message/dictionary that stores the result)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_COLOR_PICKER, x, y))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        return True, {"red": result[1][0], "green": result[1][1], "blue": result[1][2]}

    def search_color(self, region, red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip = 0):
        """Search color from a region

        Args:
            region: a tuple containing start_x, start_y, width, height of the region to search. Format: (x, y, width, height)
            red_min: min value of the red color of the point to search.
            red_max: max value of the red color of the point to search.
            green_min: min value of the green color of the point to search.
            green_max: max value of the green color of the point to search.
            blue_min: min value of the blue color of the point to search.
            blue_max: max value of the blue color of the point to search.
            pixel_to_skip: how many pixel to skip when searching.
                            For example, if the value is 1, and the start point is (0,0). Then it will only search for (0, 0), (0, 2), (0, 4) .... (2, 0), (2, 2)
                            For example, if the value is 2, and the start point is (0,0). Then it will only search for (0, 0), (0, 3), (0, 5) .... (3, 0), (3, 2)

        Returns:
            Result tuple: (success?, error_message/return value)

            if the operation successes, the return value will be an array of texts in the region.
        """
        if len(region) != 4:
            raise RuntimeError("The format of the region should be (x, y, width, height)")
            return

        self.s.send(datahandler.format_socket_data(tasktypes.TASK_COLOR_SEARCHER, colorsearchtasktypes.SEARCH_RGB_SINGLE_POINT, region[0], region[1], region[2], region[3], red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        return True, {"x": result[1][0], "y": result[1][1], "red": result[1][2], "green": result[1][3], "blue": result[1][4]}

    def count_color(self, region, red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip = 0):
        """Count pixels inside a region that fall into the given RGB range

        Args:
            region: a tuple containing start_x, start_y, width, height of the region to search. Format: (x, y, width, height)
            red_min: min value of the red color of the point to count.
            red_max: max value of the red color of the point to count.
            green_min: min value of the green color of the point to count.
            green_max: max value of the green color of the point to count.
            blue_min: min value of the blue color of the point to count.
            blue_max: max value of the blue color of the point to count.
            pixel_to_skip: how many pixel to skip when counting.

        Returns:
            Result tuple: (success?, error_message/pixel count)
        """
        if len(region) != 4:
            raise RuntimeError("The format of the region should be (x, y, width, height)")
            return

        self.s.send(datahandler.format_socket_data(tasktypes.TASK_COLOR_SEARCHER, colorsearchtasktypes.SEARCH_RGB_COUNT, region[0], region[1], region[2], region[3], red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        return True, int(result[1][0])



    def show_keyboard(self):
        """Show the keyboard

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_VIRTUAL_KEYBOARD, 2))
        return self._recv_response()

    def hide_keyboard(self):
        """hide the keyboard

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_VIRTUAL_KEYBOARD, 1))
        return self._recv_response()

    def paste_from_clipboard(self):
        """paste text from clip board

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_PASTE_FROM_CLIPBOARD))
        return self._recv_response()

    def get_text_from_clipboard(self):
        """Get text from clip board

        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_GET_TEXT_FROM_CLIPBOARD))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, result[1][0]

    def set_clipboard_text(self, text):
        """Set clipboard text

        :param text: text to set
        :return: Result tuple: (success?, error_message/return value)
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_SAVE_TEXT_TO_CLIPBOARD, text))
        return self._recv_response()

    def insert_text(self, text):
        """Insert text into the text field

        :param text: text to insert
        :return:
        """
        for i, ch in enumerate(text):
            if ch == "\b":
                self.s.send(
                    datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_DELETE_CHARACTERS,
                                                   1))
                self._recv_response()
            else:
                self.s.send(
                    datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_INSERT_TEXT, ch))
                self._recv_response()
        return True, ""


    def move_cursor(self, offset):
        """Move the cursor on the text field

        :param offset: the related position you want to move. To move left, offset should be negative. For moving right, it should be positive.
        :return:
        """
        self.s.send(
            datahandler.format_socket_data(tasktypes.TASK_KEYBOARDIMPL, kbdtasktypes.KEYBOARD_MOVE_CURSOR, offset))
        return self._recv_response()

    def get_screen_size(self):
        """Get screen size in pixels

        :return: Result tuple: (success?, error_message/dictionary that stores the result)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GET_DEVICE_INFO,
                                                   deviceinfotasktypes.DEVICE_INFO_TASK_GET_SCREEN_SIZE))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, {"width": result[1][0], "height": result[1][1]}

    def get_screen_orientation(self):
        """Get orientation of the screen

        :return: Result tuple: (success?, error_message/screen orientation(str, can be convert to int))
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GET_DEVICE_INFO,
                                                   deviceinfotasktypes.DEVICE_INFO_TASK_GET_SCREEN_ORIENTATION))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, result[1][0]

    def get_screen_scale(self):
        """Get screen scale

        :return: Result tuple: (success?, error_message/screen scale(str, can be convert to int))
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GET_DEVICE_INFO,
                                                   deviceinfotasktypes.DEVICE_INFO_TASK_GET_SCREEN_SCALE))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, result[1][0]

    def get_device_info(self):
        """Get information of the device

        :return: Result tuple: (success?, error_message/dictionary that stores device information)
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GET_DEVICE_INFO,
                                                   deviceinfotasktypes.DEVICE_INFO_TASK_GET_DEVICE_INFO))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        return True, {"name": result[1][0], "system_name": result[1][1], "system_version": result[1][2],
                      "model": result[1][3], "identifier_for_vendor": result[1][4]}

    def get_battery_info(self):
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_GET_DEVICE_INFO,
                                                   deviceinfotasktypes.DEVICE_INFO_TASK_GET_BATTERY_INFO))
        result = self._recv_response()
        if not result[0]:
            return False, result[1]
        battery_state_return = int(result[1][0])
        battery_state_list = ["Unknown", "Unplugged", "Charging", "Full"]

        return True, {"battery_state": result[1][0], "battery_level": str(int(float(result[1][1]))),
                      "battery_state_string": battery_state_list[battery_state_return]}  # state: 0 unknown, 1 unplegged, 2 charging, 3 full

    def ocr(self, region, custom_words=[], minimum_height="", recognition_level=0, languages=[], auto_correct=0, debug_image_path=""):
        """Get text from a region

        Args:
            region: a tuple containing start_x, start_y, width, height of the region to ocr. Format: (x, y, width, height)
            custom_words: an array of strings to supplement the recognized languages at the word recognition stage.
            minimum_height: the minimum height of the text expected to be recognized, relative to the image height. The default value is 1/32
            recognition_level: a value that determines whether the request prioritizes accuracy or speed in text recognition. 0 means accurate. 1 means faster.
            languages: an array of languages to detect, in priority order.  Default: english. Use get_supported_ocr_languages() to get the language list.
            auto_correct: whether ocr engine applies language correction during the recognition process. 0 means no, 1 means yes
            debug_image_path: debug image path. If you DONT want the ocr engine to output the debug image, leave it blank

        Returns:
            Result tuple: (success?, error_message/return value)

            if the operation successes, the return value will be an array of texts in the region.
        """
        if len(region) != 4:
            raise RuntimeError("The format of the region should be (x, y, width, height)")
            return

        rect_data = ",,".join(map(str, region))
        custom_words_data = ",,".join(map(str, custom_words))
        languages_data = ",,".join(map(str, languages))

        self.s.send(datahandler.format_socket_data(tasktypes.TASK_TEXT_RECOGNIZER,
                                                   1, rect_data, custom_words_data, minimum_height, recognition_level,
                                                   languages_data, auto_correct, debug_image_path))

        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        string_info_list = []
        raw_info_list = result[1]
        for raw_info in raw_info_list:
            if not raw_info:
                continue
            single_string_info = raw_info.split(",,")
            temp_dict = {"text": single_string_info[0], "x": single_string_info[1], "y": single_string_info[2],
                         "width": single_string_info[3], "height": single_string_info[4]}
            string_info_list.append(temp_dict)

        return True, string_info_list

    def get_supported_ocr_languages(self, recognition_level):
        """Get languages that can be recognized by ocr

        Args:
            recognition_level: a value that determines whether the request prioritizes accuracy or speed in text recognition. 0 means accurate. 1 means faster.

        Returns:
            Result tuple: (success?, error_message/return value)

            if the operation successes, the return value will be an array of available languages .
        """
        self.s.send(datahandler.format_socket_data(tasktypes.TASK_TEXT_RECOGNIZER,
                                                   2, recognition_level))

        result = self._recv_response()
        if not result[0]:
            return False, result[1]

        return True, result[1]

    def disconnect(self):
        self.s.close()
