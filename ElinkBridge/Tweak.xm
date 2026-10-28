// ElinkBridge v1.0
// 定位：iPhone ↔ 亿连盒子（EC-HB-4097 / BRC003）无线 CarPlay 连接的
//       「诊断 + 自动连接辅助 + 状态监控」越狱插件。
// 目标环境：iOS 16.x rootless（dopamine），iPhone 14 Pro 16.4.1 验证。
//
// 设计原则：
//  1. 所有对系统私有框架（CarKit / BluetoothManager / WiFiManager）的访问
//     一律走 NSClassFromString + respondsToSelector + performSelector 反射，
//     即使未来 iOS 版本改名也不会导致进程崩溃（返回 nil 只写日志）。
//  2. 不修改任何 CarPlay/蓝牙/WiFi 的握手数据，仅观测与提醒，
//     因此不会破坏系统稳定，也不会被吊销签名。
//  3. 日志写 /var/mobile/Library/Logs/ElinkBridge.log，可用「共享」导出。
//
// v1.0 功能：
//  A. CarPlay 会话状态轮询（车辆列表 / 连接会话 / 蓝牙设备 / WiFi）
//  B. 盒子热点/蓝牙检测与「上车」通知横幅
//  C. 一键打开「设置 → 通用 → CarPlay」引导添加
//  D. 日志开关与日志路径展示（PreferenceLoader 面板）

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "src/CarLifeServer.h"
#include <stdarg.h>
#include <sys/time.h>

// ELBLog 全局日志入口（定义在本文件下部；此处前置声明供早期函数调用，CarLifeServer.m 以 extern 引用）
void ELBLog(NSString *fmt, ...);

static BOOL elb_logEnabled = YES;
static BOOL elb_notifyEnabled = YES;
static BOOL elb_serverEnabled = YES;
static NSString *elb_hotspotSSID = @"CarPlay";   // 默认匹配 CarPlay 热点前缀
static NSString *elb_btName = @"Carplay";        // 默认匹配盒子蓝牙名前缀

// ---------- 设置（NSUserDefaults + Darwin 通知） ----------
static NSString *ELBSettingsSuite(void) { return @"com.elinkbridge.ios"; }

static void ELBReloadSettings(void) {
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:ELBSettingsSuite()];
    elb_logEnabled = [ud objectForKey:@"logEnabled"] ? [ud boolForKey:@"logEnabled"] : YES;
    elb_notifyEnabled = [ud objectForKey:@"notifyEnabled"] ? [ud boolForKey:@"notifyEnabled"] : YES;
    elb_serverEnabled = [ud objectForKey:@"serverEnabled"] ? [ud boolForKey:@"serverEnabled"] : YES;
    NSString *ssid = [ud stringForKey:@"hotspotSSID"];
    if (ssid.length) elb_hotspotSSID = ssid;
    NSString *bt = [ud stringForKey:@"btName"];
    if (bt.length) elb_btName = bt;
    ELBLog(@"设置已加载: log=%d notify=%d server=%d ssid=%@ bt=%@",
           elb_logEnabled, elb_notifyEnabled, elb_serverEnabled, elb_hotspotSSID, elb_btName);
}

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

// 全局日志入口（CarLifeServer.m 以 extern 引用，必须非 static）
void ELBLog(NSString *fmt, ...) {
    if (!elb_logEnabled) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    ELBWriteLog(msg);
}

// ---------- 反射查询 CarKit 状态（永不 crash） ----------
static NSString *ELBSafeString(id obj) {
    if (!obj) return @"(nil)";
    return [NSString stringWithFormat:@"%@", obj];
}

static id ELBSafeCall(id target, NSString *selectorName) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:sel];
#pragma clang diagnostic pop
}

static NSString *ELBCarPlayStateDump(void) {
    NSMutableString *out = [NSMutableString string];

    // 1) CarKit：CRCarPlayManager 车辆与会话
    Class mgrCls = NSClassFromString(@"CRCarPlayManager");
    id mgr = mgrCls ? ELBSafeCall(mgrCls, @"sharedInstance") : nil;
    if (mgr) {
        NSArray *selNames = @[@"connectedVehicles", @"allVehicles", @"vehicles",
                              @"currentSession", @"sessionStatus",
                              @"vehicleDidConnectNotificationName",
                              @"carPlaySessionDidConnectNotificationName"];
        for (NSString *sn in selNames) {
            id val = ELBSafeCall(mgr, sn);
            if (val) {
                [out appendFormat:@" | CarKit.%@=%@", sn, ELBSafeString(val)];
            }
        }
    } else {
        [out appendString:@" | CarKit=unavailable"];
    }

    // 2) 蓝牙：BluetoothManager 连接设备（盒子蓝牙名 Carplay&Auto_EE97 之类）
    Class btCls = NSClassFromString(@"BluetoothManager");
    id bt = btCls ? ELBSafeCall(btCls, @"sharedInstance") : nil;
    if (bt) {
        id devs = ELBSafeCall(bt, @"connectedDevices");
        if (devs) {
            NSMutableArray *names = [NSMutableArray array];
            for (id d in devs) {
                id n = ELBSafeCall(d, @"name");
                if (n) [names addObject:n];
            }
            [out appendFormat:@" | BT.connected=%@", [names componentsJoinedByString:@","]];
        }
    }

    // 3) WiFi：SBWiFiManager / 当前 SSID（反射，宽松）
    Class wifiCls = NSClassFromString(@"SBWiFiManager");
    id wifi = wifiCls ? ELBSafeCall(wifiCls, @"sharedInstance") : nil;
    if (wifi) {
        id ssid = ELBSafeCall(wifi, @"currentNetworkName");
        if (ssid) [out appendFormat:@" | WiFi.ssid=%@", ELBSafeString(ssid)];
        id joined = ELBSafeCall(wifi, @"wiFiEnabled");
        if (joined) [out appendFormat:@" | WiFi.enabled=%@", ELBSafeString(joined)];
    }
    return out.length ? out : @"(empty)";
}

// ---------- 盒子上车检测 ----------
static BOOL ELBHotspotPresent(void) {
    Class wifiCls = NSClassFromString(@"SBWiFiManager");
    id wifi = wifiCls ? ELBSafeCall(wifiCls, @"sharedInstance") : nil;
    if (wifi) {
        id net = ELBSafeCall(wifi, @"currentNetwork");
        if (net) {
            id ssid = ELBSafeCall(net, @"ssid");
            if (ssid && [ssid hasPrefix:elb_hotspotSSID]) return YES;
        }
    }
    // 蓝牙匹配
    Class btCls = NSClassFromString(@"BluetoothManager");
    id bt = btCls ? ELBSafeCall(btCls, @"sharedInstance") : nil;
    if (bt) {
        id devs = ELBSafeCall(bt, @"connectedDevices");
        for (id d in devs) {
            id n = ELBSafeCall(d, @"name");
            if (n && [n hasPrefix:elb_btName]) return YES;
        }
    }
    return NO;
}

static void ELBShowBanner(NSString *title, NSString *body) {
    if (!elb_notifyEnabled) return;
    // 反射方式尝试展示横幅；任何环节不可用都静默返回，只保证日志。
    Class bannerCls = NSClassFromString(@"SBBannerCustomActionAlertItem");
    Class bbCls = NSClassFromString(@"SBBannerController");
    if (!bannerCls || !bbCls) return;
    id item = [[bannerCls alloc] init];
    SEL setTitle = NSSelectorFromString(@"setTitle:");
    SEL setMessage = NSSelectorFromString(@"setMessage:");
    if ([item respondsToSelector:setTitle]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [item performSelector:setTitle withObject:title];
        [item performSelector:setMessage withObject:body];
#pragma clang diagnostic pop
    }
    id bb = ELBSafeCall(bbCls, @"sharedInstance");
    if (bb && [bb respondsToSelector:NSSelectorFromString(@"showAlertItem:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [bb performSelector:NSSelectorFromString(@"showAlertItem:") withObject:item];
#pragma clang diagnostic pop
    }
}

// ---------- 打开 CarPlay 设置（供后续版本 UI 调用） ----------

// ===================== Hook 层 =====================
// hook 点全部使用 %hook + 安全包装；反射逻辑在 %orig 之外，
// 保证系统进程即使遇到未知 API 也只是写日志，不影响原行为。

// SpringBoard：启动后开始轮询
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    ELBLog(@"==== ElinkBridge v1.0 loaded (SpringBoard) ====");
    ELBReloadSettings();
    ELBLog(@"状态初值: %@", ELBCarPlayStateDump());

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 设置变更监听（设置面板 PostNotification: com.elinkbridge.ios/settingschanged）
        __unused int token = 0;
        notify_register_dispatch("com.elinkbridge.ios/settingschanged", &token,
                                 dispatch_get_main_queue(), ^(int t) {
            ELBLog(@"设置面板已变更设置");
            ELBReloadSettings();
        });

        // 驾驶伴侣协议服务器（输出端角色）
        if (elb_serverEnabled) {
            [[CarLifeServer sharedServer] start];
        } else {
            ELBLog(@"协议服务器开关关闭，不监听端口");
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:ELBServerStateChangedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            ELBLog(@"[server] 阶段变化 → %@（车机 %@）",
                   [[CarLifeServer sharedServer] phaseName],
                   [[CarLifeServer sharedServer] huAddress] ?: @"未连接");
        }];

        // 每秒轮询，状态变化时记录；同时做盒子上车检测
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0
                                               repeats:YES
                                                 block:^(NSTimer *t) {
            static NSString *lastState = @"";
            NSString *state = ELBCarPlayStateDump();
            if (![state isEqualToString:lastState]) {
                ELBLog(@"状态变化: %@", state);
                lastState = state;
            }
            static BOOL lastHotspot = NO;
            BOOL hp = ELBHotspotPresent();
            if (hp && !lastHotspot) {
                ELBLog(@"检测到亿连盒子（热点/蓝牙在线）");
                ELBShowBanner(@"ElinkBridge", @"检测到亿连盒子 CarPlay 热点，已就绪");
            }
            lastHotspot = hp;
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    BOOL ret = %orig;
    ELBLog(@"SpringBoard didFinishLaunchingWithOptions (app=%@)", application);
    return ret;
}

%end

// Preferences：记录用户进入 CarPlay 设置页（定位“添加车辆”流程）
%hook PSRootController

- (void)pushController:(id)controller {
    %orig;
    ELBLog(@"Preferences pushController: %@", controller);
    NSString *cls = NSStringFromClass([controller class]);
    if ([cls containsString:@"CarPlay"] || [cls containsString:@"carplay"]) {
        ELBLog(@"用户已进入 CarPlay 设置界面（%@）", cls);
    }
}

%end
