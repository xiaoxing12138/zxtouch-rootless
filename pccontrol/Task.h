#ifndef TASK_H
#define TASK_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>


#define TASK_PERFORM_TOUCH 10
#define TASK_PROCESS_BRING_FOREGROUND 11
#define TASK_SHOW_ALERT_BOX 12
#define TASK_RUN_SHELL 13
#define TASK_TOUCH_RECORDING_START 14
#define TASK_TOUCH_RECORDING_STOP 15
#define TASK_CRAZY_TAP 16
#define TASK_RAPID_FIRE_TAP 17
#define TASK_USLEEP 18
#define TASK_PLAY_SCRIPT 19
#define TASK_PLAY_SCRIPT_FORCE_STOP 20
#define TASK_TEMPLATE_MATCH 21
#define TASK_SHOW_TOAST 22
#define TASK_COLOR_PICKER 23
#define TASK_TEXT_INPUT 24
#define TASK_GET_DEVICE_INFO 25
#define TASK_TOUCH_INDICATOR 26
#define TASK_TEXT_RECOGNIZER 27
#define TASK_COLOR_SEARCHER 28
#define TASK_PROMPT_INPUT 29
#define TASK_SCREENSHOT 30
#define TASK_NET_SPEED_INDICATOR 31
#define TASK_FLOATING_MENU 32

// 40;;net_speed → 返回网速窗调试信息（JSON 字典字符串）
// 40;;floating_menu → 返回悬浮按钮调试信息（JSON 字典字符串）
// 40;;all → 返回两者合并后的字典
#define TASK_DEBUG_INFO 40
#define TASK_TAP_TEST 41
#define TASK_TOUCH_COORDINATE_INDICATOR 42
// 43：返回「未转正」的原始竖屏帧 JPEG + 当前方向，响应头 0;;image/jpeg;<字节数>;;<方向>\r\n
// 给可视化编辑器截图框选识图模板用：显示时转正，抠模板时按原始帧抠（见 Screen.h 换算说明）
#define TASK_SCREENSHOT_RAW 43
// 44：可视化编辑器（插件侧悬浮卡片，因为取点必须在 SpringBoard 进程里画覆盖层）
// 44;;open;;<脚本包绝对路径> 打开已存在的可视化脚本
// 44;;new;;<脚本包绝对路径>  新建可视化脚本包（建目录 + flow.plist + main.py）
#define TASK_FLOW_EDITOR 44
// 45：Python 依赖诊断，返回 JSON
#define TASK_PYTHON_CHECK 45

// 46：返回主屏幕（无载荷）
#define TASK_GO_HOME 46
// 47：关闭 App（杀后台）；载荷 = bundle id
#define TASK_KILL_APP 47
// 48：响铃；载荷 = 铃声路径或文件名;;持续秒数
#define TASK_PLAY_RING 48
// 49：调整音量；载荷 = percent|delta|deltaPercent;;数值
//   percent       0-100，绝对值
//   deltaPercent  0-100，增减的百分点（正数调高、负数调低）
//   delta         增减格数（1 格 = 1/16，兼容旧脚本）
#define TASK_SET_VOLUME 49
// 50：停止所有正在运行的脚本（无载荷）
#define TASK_STOP_ALL_SCRIPTS 50
// 51：拨打电话；载荷 = 号码;;卡（default|1|2）
#define TASK_MAKE_CALL 51
// 52：发送短信；载荷 = 号码;;内容;;卡（default|1|2）
#define TASK_SEND_SMS 52
// 53：开关 WiFi；载荷 = 1|0（也认 on|off 字样）
#define TASK_SET_WIFI 53
// 54：后台截屏存进相册（无载荷）；返回 0;;<文件路径>
#define TASK_SAVE_SCREENSHOT 54
// 55：诊断微信快捷指令动作（临时）；返回 0;;<JSON>
#define TASK_INTENT_PROBE 55
// 56：读取 55 落盘的探测结果（无载荷）
#define TASK_INTENT_PROBE_READ 56

#define TASK_UPDATE_CACHE 90

#define TASK_TEST 99

void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef = NULL);
static int getTaskType(UInt8* dataArray);

#endif
