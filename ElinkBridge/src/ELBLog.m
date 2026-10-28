//
//  ELBLog.m
//  ElinkBridge
//
//  日志写入串行化 + 全消息落盘。独立 .m 文件：保证全局符号 _ELBLog
//  在任何链接顺序下都被导出（避免 Logos 预处理产物符号问题）。
//

#import "ELBLog.h"
#include <stdarg.h>
#include <sys/time.h>

BOOL ELBLogEnabled = YES;

static NSString *ELBLogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    return [[paths firstObject] stringByAppendingPathComponent:@"Logs/ElinkBridge.log"];
}

static void ELBWriteLog(NSString *msg) {
    // 日志写入串行化，避免多线程（协议服务器/轮询/通知）交错写同一文件
    static dispatch_queue_t logQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logQ = dispatch_queue_create("elb.log", DISPATCH_QUEUE_SERIAL); });
    dispatch_sync(logQ, ^{
        NSString *logPath = ELBLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [logPath stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}

void ELBLog(NSString *fmt, ...) {
    if (!ELBLogEnabled) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    ELBWriteLog(msg);
}
