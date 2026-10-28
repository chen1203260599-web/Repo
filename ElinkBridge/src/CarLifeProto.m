//
//  CarLifeProto.m
//  ElinkBridge
//
#import "CarLifeProto.h"

@implementation PBWriter

+ (NSData *)varint:(uint64_t)v {
    NSMutableData *d = [NSMutableData data];
    do {
        uint8_t b = (uint8_t)(v & 0x7f);
        v >>= 7;
        if (v) b |= 0x80;
        [d appendBytes:&b length:1];
    } while (v);
    return d;
}

+ (NSData *)fieldVarint:(int)fieldNo value:(uint64_t)v {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self varint:(uint64_t)((fieldNo << 3) | 0)]];   // wire type 0
    [d appendData:[self varint:v]];
    return d;
}

+ (NSData *)fieldString:(int)fieldNo value:(NSString *)s {
    NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self varint:(uint64_t)((fieldNo << 3) | 2)]];   // wire type 2
    [d appendData:[self varint:bytes.length]];
    [d appendData:bytes];
    return d;
}

+ (NSData *)fieldBytes:(int)fieldNo value:(NSData *)d0 {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self varint:(uint64_t)((fieldNo << 3) | 2)]];
    [d appendData:[self varint:d0.length]];
    [d appendData:d0];
    return d;
}

@end

@implementation PBReader {
    NSData *_data;
    NSUInteger _pos;
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) { _data = data; _pos = 0; }
    return self;
}

- (NSData *)data { return _data; }

- (uint64_t)varintAtOffset:(NSUInteger)off nextOffset:(NSUInteger *)next {
    uint64_t res = 0;
    NSUInteger shift = 0;
    const uint8_t *p = _data.bytes;
    while (off < _data.length && shift < 64) {
        uint8_t b = p[off++];
        res |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) break;
        shift += 7;
    }
    if (next) *next = off;
    return res;
}

- (NSDictionary *)parseAll {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSUInteger len = _data.length;
    NSUInteger off = 0;
    while (off < len) {
        NSUInteger keyOff = off;
        uint64_t key = [self varintAtOffset:off nextOffset:&off];
        if (key == 0) break;
        int fieldNo = (int)(key >> 3);
        int wire = (int)(key & 7);
        id value = nil;
        if (wire == 0) {                       // varint
            value = @([self varintAtOffset:off nextOffset:&off]);
        } else if (wire == 2) {                // length-delimited
            uint64_t l = [self varintAtOffset:off nextOffset:&off];
            if (off + l > len) break;
            value = [_data subdataWithRange:NSMakeRange(off, (NSUInteger)l)];
            off += (NSUInteger)l;
        } else {                               // 其他 wire type：跳过（fixed32/64 等）
            if (wire == 1) off += 8;
            else if (wire == 5) off += 4;
            else if (wire == 3) { /* group：暂不支持 */ }
            value = @(keyOff); // 占位
        }
        NSMutableArray *arr = map[@(fieldNo)];
        if (!arr) { arr = [NSMutableArray array]; map[@(fieldNo)] = arr; }
        [arr addObject:value];
    }
    return map;
}

@end

@implementation CarLifeFrame

+ (NSData *)encodeChannel1:(uint32_t)type payload:(NSData *)payload {
    NSMutableData *d = [NSMutableData data];
    uint16_t len = (uint16_t)payload.length;
    uint16_t rsv = 0;
    uint8_t head[8];
    head[0] = (len >> 8) & 0xff; head[1] = len & 0xff;
    head[2] = (rsv >> 8) & 0xff; head[3] = rsv & 0xff;
    head[4] = (type >> 24) & 0xff; head[5] = (type >> 16) & 0xff;
    head[6] = (type >> 8) & 0xff;  head[7] = type & 0xff;
    [d appendBytes:head length:8];
    [d appendData:payload];
    return d;
}

+ (NSData *)encodeChannelN:(uint32_t)type seq:(uint32_t)seq payload:(NSData *)payload {
    NSMutableData *d = [NSMutableData data];
    uint8_t head[12];
    uint32_t len = (uint32_t)payload.length;
    head[0] = (len >> 24) & 0xff; head[1] = (len >> 16) & 0xff;
    head[2] = (len >> 8) & 0xff;  head[3] = len & 0xff;
    head[4] = (seq >> 24) & 0xff;  head[5] = (seq >> 16) & 0xff;
    head[6] = (seq >> 8) & 0xff;   head[7] = seq & 0xff;
    head[8] = (type >> 24) & 0xff; head[9] = (type >> 16) & 0xff;
    head[10] = (type >> 8) & 0xff; head[11] = type & 0xff;
    [d appendBytes:head length:12];
    [d appendData:payload];
    return d;
}

+ (instancetype)tryParseChannel1:(NSData *)buf {
    if (buf.length < 8) return nil;
    const uint8_t *p = buf.bytes;
    uint16_t len = ((uint16_t)p[0] << 8) | p[1];
    uint32_t type = ((uint32_t)p[4] << 24) | ((uint32_t)p[5] << 16) | ((uint32_t)p[6] << 8) | p[7];
    if (buf.length < 8 + len) return nil;
    CarLifeFrame *f = [[CarLifeFrame alloc] init];
    f.type = type;
    f.payload = [buf subdataWithRange:NSMakeRange(8, len)];
    return f;
}

+ (instancetype)tryParseChannelN:(NSData *)buf {
    if (buf.length < 12) return nil;
    const uint8_t *p = buf.bytes;
    uint32_t len = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    uint32_t type = ((uint32_t)p[8] << 24) | ((uint32_t)p[9] << 16) | ((uint32_t)p[10] << 8) | p[11];
    if (buf.length < 12 + len) return nil;
    CarLifeFrame *f = [[CarLifeFrame alloc] init];
    f.type = type;
    f.payload = [buf subdataWithRange:NSMakeRange(12, len)];
    return f;
}

@end

@implementation CarLifeMessages

+ (NSData *)versionMatchAck {
    // 65538 matchStatus=1（与实测配方一致：手机端回 matchStatus=1）
    NSMutableData *d = [NSMutableData data];
    [d appendData:[PBWriter fieldVarint:1 value:1]];
    return d;
}

+ (NSData *)foregroundStatus {
    // 65563：前台状态 protobuf（值保持 1）
    NSMutableData *d = [NSMutableData data];
    [d appendData:[PBWriter fieldVarint:1 value:1]];
    return d;
}

+ (NSData *)phoneDeviceInfo {
    // 65540 设备信息。字段序（1..24）来自官方车机版 APK 逆向：
    // os board bootloader brand cpuAbi cpuAbi2 device display fingerprint hardware
    // host cid manufacturer model product serial codename incremental release sdk
    // token btaddress carlifeversion sdkInt(整型)
    NSMutableData *d = [NSMutableData data];
    [d appendData:[PBWriter fieldString:1 value:@"iOS"]];
    [d appendData:[PBWriter fieldString:2 value:@"iPhone"]];
    [d appendData:[PBWriter fieldString:3 value:@"unknown"]];
    [d appendData:[PBWriter fieldString:4 value:@"Apple"]];
    [d appendData:[PBWriter fieldString:5 value:@"arm64e"]];
    [d appendData:[PBWriter fieldString:6 value:@"arm64"]];
    [d appendData:[PBWriter fieldString:7 value:@"iPhone14,3"]];   // iPhone 14 Pro
    [d appendData:[PBWriter fieldString:8 value:@"ElinkBridge-iOS"]];
    [d appendData:[PBWriter fieldString:9 value:@"Apple/iPhone14,3"]];
    [d appendData:[PBWriter fieldString:10 value:@"s5l8965x"]];
    [d appendData:[PBWriter fieldString:11 value:@"localhost"]];
    [d appendData:[PBWriter fieldString:12 value:@"CN"]];
    [d appendData:[PBWriter fieldString:13 value:@"Apple"]];
    [d appendData:[PBWriter fieldString:14 value:@"iPhone 14 Pro"]];
    [d appendData:[PBWriter fieldString:15 value:@"iPhone14,3"]];
    [d appendData:[PBWriter fieldString:16 value:@"unknown"]];
    [d appendData:[PBWriter fieldString:17 value:@"unknown"]];
    [d appendData:[PBWriter fieldString:18 value:@"unknown"]];
    [d appendData:[PBWriter fieldString:19 value:@"16.4.1"]];
    [d appendData:[PBWriter fieldString:20 value:@"21E236"]];
    [d appendData:[PBWriter fieldString:21 value:@"elinkbridge"]];
    [d appendData:[PBWriter fieldString:22 value:@"00:00:00:00:00:00"]];
    [d appendData:[PBWriter fieldString:23 value:@"4.0.0"]];
    [d appendData:[PBWriter fieldVarint:24 value:16]];
    return d;
}

+ (NSData *)moduleStatusAck:(uint64_t)flags {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[PBWriter fieldVarint:1 value:flags]];
    return d;
}

+ (NSData *)encoderParamAck:(uint32_t)width height:(uint32_t)height frameRate:(uint32_t)fps bitrate:(uint32_t)bps {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[PBWriter fieldVarint:1 value:width]];
    [d appendData:[PBWriter fieldVarint:2 value:height]];
    [d appendData:[PBWriter fieldVarint:3 value:fps]];
    [d appendData:[PBWriter fieldVarint:4 value:bps]];
    return d;
}

@end
