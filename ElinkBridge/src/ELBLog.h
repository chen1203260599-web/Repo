//
//  ELBLog.h
//  ElinkBridge
//
//  全局日志入口：写 /var/mobile/Library/Logs/ElinkBridge.log。
//  单独成文件确保符号 _ELBLog 一定参与链接（Logos 预处理产物可能不导出符号）。
//

#ifndef ELBLog_h
#define ELBLog_h

#import <Foundation/Foundation.h>

// 日志总开关（Tweak.xm 设置面板加载时写入）
extern BOOL ELBLogEnabled;

void ELBLog(NSString *fmt, ...);

#endif /* ELBLog_h */
