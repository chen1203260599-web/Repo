//
//  CarLifeProto.h
//  ElinkBridge
//
//  CarLife/亿连驾驶伴侣兼容协议的轻量 protobuf 编解码（wire format）。
//  参考：CarPToCarL 实测逆向（carlife-hijack-findings.md）
//  帧格式：
//    Channel 1/6（CMD/CTRL）: [u16 len][u16 rsv][u32 type] + protobuf payload
//    其他通道（VIDEO/MEDIA/TTS/VR/TOUCH）: [u32 len][u32 seq][u32 type] + payload
//  消息号（十进制）：
//    98305 版本协商  65538 matchStatus  98343 统计  65563 前台
//    65540 手机设备信息  98307 HU_INFO  65574 模块状态  98344 模块控制
//    98386 特征配置  98311 视频初始化  65544 编码参数确认  98313 视频启动
//    131074 心跳  425985 触摸 等
//

#ifndef CarLifeProto_h
#define CarLifeProto_h

#import <Foundation/Foundation.h>

// ---- 轻量 protobuf 写入器 ----
@interface PBWriter : NSObject
+ (NSData *)varint:(uint64_t)v;
+ (NSData *)fieldVarint:(int)fieldNo value:(uint64_t)v;
+ (NSData *)fieldString:(int)fieldNo value:(NSString *)s;
+ (NSData *)fieldBytes:(int)fieldNo value:(NSData *)d;
@end

// ---- 轻量 protobuf 读取器 ----
@interface PBReader : NSObject
@property (nonatomic, readonly) NSData *data;
- (instancetype)initWithData:(NSData *)data;
// 返回 {fieldNo: [values]}，value 为 NSNumber 或 NSData(字符串字段)
- (NSDictionary *)parseAll;
- (uint64_t)varintAtOffset:(NSUInteger)off nextOffset:(NSUInteger *)next;
@end

// ---- CarLife 消息帧 ----
@interface CarLifeFrame : NSObject
@property (nonatomic) uint32_t type;        // 消息号（10 进制）
@property (nonatomic) NSData *payload;      // protobuf payload
+ (NSData *)encodeChannel1:(uint32_t)type payload:(NSData *)payload;  // [u16 len][u16 rsv][u32 type]
+ (NSData *)encodeChannelN:(uint32_t)type seq:(uint32_t)seq payload:(NSData *)payload; // [u32 len][u32 seq][u32 type]
// 从指定通道的数据流中尝试解析一帧（返回 nil 表示数据不足）
+ (instancetype)tryParseChannel1:(NSData *)buf;
+ (instancetype)tryParseChannelN:(NSData *)buf;
@end

// ---- 常用消息构造 ----
@interface CarLifeMessages : NSObject
// 65538 版本协商应答：matchStatus=1
+ (NSData *)versionMatchAck;
// 65563 前台状态
+ (NSData *)foregroundStatus;
// 65540 手机（iPhone）设备信息 —— 字段序来自官方车机版 APK 逆向
+ (NSData *)phoneDeviceInfo;
// 65574 模块状态应答
+ (NSData *)moduleStatusAck:(uint64_t)flags;
// 65544 编码参数确认（视频初始化应答）
+ (NSData *)encoderParamAck:(uint32_t)width height:(uint32_t)height frameRate:(uint32_t)fps bitrate:(uint32_t)bps;
@end

#endif /* CarLifeProto_h */
