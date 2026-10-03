#ifndef CONFIG_H
#define CONFIG_H

#include <roothide.h>

#define DOCUMENT_ROOT_FOLDER_NAME "ZXTouch"
#define RECORDING_FILE_FOLDER_NAME "录制脚本"
#define SCRIPT_FOLDER_NAME "scripts"
#define CONFIG_FOLDER_NAME "config/tweak"
#define COMMON_CONFIG_NAME "config.plist"
#define SCRIPT_PLAY_CONFIG_PATH @"/var/mobile/Library/ZXTouch/config/tweak/script_play_settings.plist"
#define SCRIPT_FUNCTIONS_CONFIG_PATH @"/var/mobile/Library/ZXTouch/config/tweak/script_functions.plist"
// 选项面板脚本列表的界面状态（目前只有「哪些文件夹是展开的」）
#define PANEL_STATE_CONFIG_PATH @"/var/mobile/Library/ZXTouch/config/tweak/panel_state.plist"

#endif
