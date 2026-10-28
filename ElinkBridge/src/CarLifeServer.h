//
//  CarLifeServer.h
//  ElinkBridge
//
//  驾驶伴侣（亿连/CarLife 兼容协议）手机端服务器：
//  监听 7 个 TCP 端口，作为「输出端」响应车机驾驶伴侣（HU）的握手并推进连接。
//
//  端口：7240 CMD / 8240 VIDEO / 9240 MEDIA / 9241 TTS / 9242 VR / 9340 TOUCH / 9440 CTRL
//
//  v1.0 范围：完成握手状态机（版本协商→统计→设备信息→模块→特征配置→视频协商），
//  记录全部消息；视频推流与触摸注入作为 v1.1/v1.2 挂载点预留。
//

#ifndef CarLifeServer_h
#define CarLifeServer_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ELBConnectPhase) {
    ELBPhaseIdle = 0,          // 未连接
    ELBPhaseVersionAck,        // 已应答版本协商 65538
    ELBPhaseInfoExchanged,     // 已交换统计/设备信息
    ELBPhaseModuleReady,       // 模块控制已应答
    ELBPhaseFeatureConfigured, // 特征配置已收到
    ELBPhaseVideoNegotiated,   // 视频参数已确认 65544
    ELBPhaseVideoRunning,      // 视频启动已收到（v1.1 在此推流）
};

extern NSString *const ELBServerStateChangedNotification;

@interface CarLifeServer : NSObject
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) ELBConnectPhase phase;
@property (nonatomic, readonly) NSString *huAddress;      // 车机 IP（最近连接的）
@property (nonatomic, readonly) NSArray<NSNumber *> *supportedPorts;

+ (instancetype)sharedServer;
- (void)start;                                     // 监听全部端口（后台线程）
- (void)stop;
- (NSString *)phaseName;

// 车机热点模式：iPhone 连上车机热点后，探测默认网关（车机 IP）并主动
// TCP 连接其 7240 端口建立握手（车机作为 HU 主导协议，手机应答）。
- (void)startProbe;

// v1.1 挂载点：视频编码帧写入（外部提供 H.264 Annex-B 数据）
- (void)pushVideoFrame:(NSData *)annexBNalu frameType:(uint32_t)frameType;
// v1.2 挂载点：车机触摸回调（9340 通道收到的原始触摸帧）
@property (nonatomic, copy) void (^onTouchFrame)(NSData *rawFrame, uint32_t type);
@end

#endif /* CarLifeServer_h */
