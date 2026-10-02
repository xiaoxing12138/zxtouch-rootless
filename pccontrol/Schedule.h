#ifndef SCHEDULE_H
#define SCHEDULE_H

#import <Foundation/Foundation.h>

// 脚本定时调度器。
//
// 常驻 SpringBoard，每 20 秒扫一遍脚本目录，读每个 .bdl 的 info.plist 里的
// `Schedule` 字典，决定是否自动启动 / 自动结束。脚本自己解析不了这个需求
// （脚本没跑起来时没人读它），所以只能放在引擎里。
void ZXScheduleInit();

#endif
