//
//  CarLifeServer.m
//  ElinkBridge
//
#import "CarLifeServer.h"
#import "CarLifeProto.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <fcntl.h>
#import <sys/select.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>
#import <SystemConfiguration/SystemConfiguration.h>

NSString *const ELBServerStateChangedNotification = @"com.elinkbridge.ios/statechanged";

// 日志转发（由 Tweak.xm 注入层实现，写 /var/mobile/Library/Logs/ElinkBridge.log）
extern void ELBLog(NSString *fmt, ...);

@interface CarLifeServer () {
    dispatch_queue_t _cmdQueue;
    NSMutableDictionary<NSNumber *, NSMutableData *> *_readBufs;   // fd -> 累积缓冲
    BOOL _running;
}
@property (nonatomic, strong) NSMutableArray<NSNumber *> *listenFds;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@property (nonatomic, readwrite) ELBConnectPhase phase;
@property (nonatomic, readwrite) NSString *huAddress;
@end

@implementation CarLifeServer

static CarLifeServer *g_server;

+ (instancetype)sharedServer {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_server = [[CarLifeServer alloc] init];
    });
    return g_server;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _supportedPorts = @[@7240, @8240, @9240, @9241, @9242, @9340, @9440];
        self.listenFds = [NSMutableArray array];
        _readBufs = [NSMutableDictionary dictionary];
        self.acceptQueue = dispatch_queue_create("elb.accept", DISPATCH_QUEUE_SERIAL);
        _cmdQueue = dispatch_queue_create("elb.cmd", DISPATCH_QUEUE_SERIAL);
        _phase = ELBPhaseIdle;
    }
    return self;
}

- (NSString *)phaseName {
    switch (_phase) {
        case ELBPhaseIdle: return @"待连接";
        case ELBPhaseVersionAck: return @"版本已应答";
        case ELBPhaseInfoExchanged: return @"设备信息已交换";
        case ELBPhaseModuleReady: return @"模块控制就绪";
        case ELBPhaseFeatureConfigured: return @"特征配置已收";
        case ELBPhaseVideoNegotiated: return @"视频参数已确认";
        case ELBPhaseVideoRunning: return @"视频启动（可推流）";
    }
}

- (void)setPhase:(ELBConnectPhase)phase {
    if (_phase != phase) {
        _phase = phase;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ELBServerStateChangedNotification object:self];
        });
    }
}

- (void)setHuAddress:(NSString *)huAddress {
    _huAddress = [huAddress copy];
}

- (void)start {
    if (_running) return;
    _running = YES;
    dispatch_async(_acceptQueue, ^{
        for (NSNumber *portNum in self.supportedPorts) {
            int port = portNum.intValue;
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                ELBLog(@"[server] 端口 %d socket 创建失败 errno=%d", port, errno);
                continue;
            }
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(port);
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
            if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                ELBLog(@"[server] 端口 %d bind 失败 errno=%d（可能被占用）", port, errno);
                close(fd);
                continue;
            }
            listen(fd, 4);
            [self.listenFds addObject:@(fd)];
            ELBLog(@"[server] ✅ 监听端口 %d (fd=%d)", port, fd);
            // 每个端口一个 accept 循环
            dispatch_async(self.acceptQueue, ^{
                [self acceptLoop:fd port:port];
            });
        }
        if (self.listenFds.count == 0) {
            ELBLog(@"[server] ❌ 所有端口监听失败");
        }
        // 车机热点模式：监听建立后同时开始主动探测连接
        [self startProbe];
    });
}

- (void)stop {
    _running = NO;
    for (NSNumber *fdNum in _listenFds) {
        close(fdNum.intValue);
    }
    [_listenFds removeAllObjects];
    ELBLog(@"[server] 已停止");
}

// ---------- 车机热点模式：主动连接 ----------
// 网关探测策略（iOS 上 SCDynamicStore API 标记为不可用，故采用）：
// 1) getifaddrs 取 WiFi(en0) 本机 IP → 推 x.x.x.1 / x.x.x.254；
// 2) 常见手机热点网段兜底（Android 192.168.43.x、iPhone 172.20.10.x、家用 192.168.1/0.x）。
+ (NSArray<NSString *> *)candidateHostIPs {
    NSMutableArray *cands = [NSMutableArray array];
    struct ifaddrs *ifas = NULL;
    if (getifaddrs(&ifas) == 0) {
        for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
            if (![name hasPrefix:@"en"]) continue;
            struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
            char ip[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
            NSString *ipStr = [NSString stringWithUTF8String:ip];
            NSArray *parts = [ipStr componentsSeparatedByString:@"."];
            if (parts.count == 4) {
                NSString *subnet = [NSString stringWithFormat:@"%@.%@.%@", parts[0], parts[1], parts[2]];
                [cands addObject:[subnet stringByAppendingString:@".1"]];
                [cands addObject:[subnet stringByAppendingString:@".254"]];
            }
        }
        freeifaddrs(ifas);
    }
    // 常见热点网段兜底
    [cands addObject:@"192.168.43.1"];  // Android 热点（车机驾驶伴侣常见）
    [cands addObject:@"192.168.43.254"];
    [cands addObject:@"172.20.10.1"];   // iPhone 个人热点
    [cands addObject:@"192.168.1.1"];
    [cands addObject:@"192.168.0.1"];
    // 去重保序
    NSMutableArray *uniq = [NSMutableArray array];
    for (NSString *c in cands) {
        if (![uniq containsObject:c]) [uniq addObject:c];
    }
    return uniq;
}

- (void)startProbe {
    dispatch_async(_cmdQueue, ^{
        NSArray *cands = [[self class] candidateHostIPs];
        ELBLog(@"[probe] 车机热点候选 IP: %@", [cands componentsJoinedByString:@" "]);
        for (NSString *ip in cands) {
            if (!self.running) break;
            ELBLog(@"[probe] 尝试主动连接车机 %@:7240 ...", ip);
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) continue;
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(7240);
            inet_pton(AF_INET, ip.UTF8String, &addr.sin_addr);
            // 非阻塞 connect + 2s 超时
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
            if (rc < 0 && errno == EINPROGRESS) {
                struct timeval tv = {2, 0};
                fd_set wset;
                FD_ZERO(&wset);
                FD_SET(fd, &wset);
                int sel = select(fd + 1, NULL, &wset, NULL, &tv);
                if (sel <= 0) {
                    close(fd);
                    ELBLog(@"[probe] %@:7240 连接超时/不可达", ip);
                    continue;
                }
                int soerr = 0;
                socklen_t slen = sizeof(soerr);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
                if (soerr != 0) {
                    close(fd);
                    ELBLog(@"[probe] %@:7240 连接失败 errno=%d", ip, soerr);
                    continue;
                }
            } else if (rc < 0) {
                close(fd);
                ELBLog(@"[probe] %@:7240 连接失败 errno=%d", ip, errno);
                continue;
            }
            fcntl(fd, F_SETFL, flags);
            // 连接成功：车机驾驶伴侣已接受 → 进入同一状态机（等车机发 98305）
            self.huAddress = ip;
            ELBLog(@"[probe] ✅ 已连接车机驾驶伴侣 %@:7240，等待车机握手（98305）", ip);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self readLoop:fd port:7240];
            });
            return;
        }
        ELBLog(@"[probe] 候选 IP 均未连通 → 保持监听模式，等待车机主动连入");
    });
}

- (void)acceptLoop:(int)listenFd port:(int)port {
    while (self.running) {
        struct sockaddr_in cli;
        socklen_t cliLen = sizeof(cli);
        int fd = accept(listenFd, (struct sockaddr *)&cli, &cliLen);
        if (fd < 0) {
            if (errno == EBADF || errno == EINVAL) break;  // socket 已关闭
            continue;
        }
        char ip[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &cli.sin_addr, ip, sizeof(ip));
        ELBLog(@"[server] 端口 %d 收到连接: %s:%d (fd=%d)", port, ip, ntohs(cli.sin_port), fd);
        if (port == 7240) {
            self.huAddress = [NSString stringWithUTF8String:ip];
            ELBLog(@"[server] 车机驾驶伴侣 IP=%@", self.huAddress);
        }
        // 读循环（每个 fd 独立并发读；状态机处理在 cmdQueue 串行化）
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self readLoop:fd port:port];
        });
    }
}

- (void)readLoop:(int)fd port:(int)port {
    uint8_t buf[4096];
    NSMutableData *acc = [NSMutableData data];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [acc appendBytes:buf length:(NSUInteger)n];
        [self processIncoming:acc fd:fd port:port];
    }
    if (n == 0) {
        ELBLog(@"[server] 端口 %d 连接被关闭", port);
    } else if (n < 0 && errno != EINTR) {
        ELBLog(@"[server] 端口 %d 读错误 errno=%d", port, errno);
    }
    close(fd);
}

- (void)processIncoming:(NSMutableData *)acc fd:(int)fd port:(int)port {
    // 状态机串行化到 cmdQueue，避免多连接并发改 phase/写日志竞争
    dispatch_sync(_cmdQueue, ^{
        // 持续解帧：CMD 通道 Channel1 格式（8B 头 + payload）
        while (YES) {
            CarLifeFrame *frame = (port == 7240)
                ? [CarLifeFrame tryParseChannel1:acc]
                : [CarLifeFrame tryParseChannelN:acc];
            if (!frame) break;
            // 移除已消费字节
            NSUInteger consumed = (port == 7240) ? (8 + frame.payload.length) : (12 + frame.payload.length);
            [acc replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
            [self handleFrame:frame port:port fd:fd];
        }
    });
}

// ---------- 握手状态机（手机端「输出端」角色） ----------
- (void)handleFrame:(CarLifeFrame *)frame port:(int)port fd:(int)fd {
    uint32_t t = frame.type;
    // 心跳：131074 每 1s，立即回
    if (t == 131074) {
        NSData *ack = [CarLifeFrame encodeChannel1:131074 payload:[NSData data]];
        write(fd, ack.bytes, ack.length);
        return;
    }
    ELBLog(@"[msg] 端口 %d 收到消息 %u (payload %luB)", port, t, (unsigned long)frame.payload.length);

    if (port != 7240) {
        // 非 CMD 通道消息（触摸/媒体等）暂记录；触摸帧转发给挂载点
        if (port == 9340) {
            if (self.onTouchFrame) self.onTouchFrame(frame.payload, t);
            ELBLog(@"[msg] 触摸通道 %u 收到 %luB", t, (unsigned long)frame.payload.length);
        }
        return;
    }

    switch (t) {
        case 98305: {  // 车机版本协商
            // payload protobuf: field1 major, field2 minor —— 记录车机版本
            PBReader *r = [[PBReader alloc] initWithData:frame.payload];
            NSDictionary *kv = [r parseAll];
            NSNumber *major = [(NSArray *)kv[@1] firstObject];
            NSNumber *minor = [(NSArray *)kv[@2] firstObject];
            ELBLog(@"[handshake] 车机版本协商 major=%@ minor=%@", major, minor);
            NSData *ack = [CarLifeFrame encodeChannel1:65538 payload:[CarLifeMessages versionMatchAck]];
            write(fd, ack.bytes, ack.length);
            self.phase = ELBPhaseVersionAck;
            ELBLog(@"[handshake] → 回 65538 matchStatus=1");
            break;
        }
        case 98343: {  // 车机统计信息请求
            ELBLog(@"[handshake] 收到 98343 统计请求 → 回前台/设备信息/模块状态");
            NSData *fg = [CarLifeFrame encodeChannel1:65563 payload:[CarLifeMessages foregroundStatus]];
            write(fd, fg.bytes, fg.length);
            NSData *info = [CarLifeFrame encodeChannel1:65540 payload:[CarLifeMessages phoneDeviceInfo]];
            write(fd, info.bytes, info.length);
            NSData *mod = [CarLifeFrame encodeChannel1:65574 payload:[CarLifeMessages moduleStatusAck:0]];
            write(fd, mod.bytes, mod.length);
            self.phase = ELBPhaseInfoExchanged;
            break;
        }
        case 98307: {  // 车机 HU_INFO
            ELBLog(@"[handshake] 收到 98307 HU_INFO（车机已就绪）→ 回模块状态");
            NSData *mod = [CarLifeFrame encodeChannel1:65574 payload:[CarLifeMessages moduleStatusAck:0]];
            write(fd, mod.bytes, mod.length);
            break;
        }
        case 98344: {  // 车机模块控制（全开）
            ELBLog(@"[handshake] 收到 98344 模块控制 → 回模块全开状态");
            NSData *mod = [CarLifeFrame encodeChannel1:65574 payload:[CarLifeMessages moduleStatusAck:0x3f]];
            write(fd, mod.bytes, mod.length);
            self.phase = ELBPhaseModuleReady;
            break;
        }
        case 98386: {  // 车机特征配置（主动推）
            ELBLog(@"[handshake] 收到 98386 特征配置");
            self.phase = ELBPhaseFeatureConfigured;
            break;
        }
        case 98311: {  // 车机视频编码初始化请求
            // 解析请求中的宽高（字段 1/2，若无则用默认 1280x720）
            uint32_t w = 1280, h = 720, fps = 30;
            PBReader *r = [[PBReader alloc] initWithData:frame.payload];
            NSDictionary *kv = [r parseAll];
            NSNumber *wv = [(NSArray *)kv[@1] firstObject];
            NSNumber *hv = [(NSArray *)kv[@2] firstObject];
            NSNumber *fv = [(NSArray *)kv[@3] firstObject];
            if (wv) w = wv.unsignedIntValue;
            if (hv) h = hv.unsignedIntValue;
            if (fv) fps = fv.unsignedIntValue;
            ELBLog(@"[handshake] 收到 98311 视频初始化 %ux%u@%u → 回 65544 编码参数确认",
                   w, h, fps);
            NSData *ack = [CarLifeFrame encodeChannel1:65544
                                               payload:[CarLifeMessages encoderParamAck:w height:h frameRate:fps bitrate:8000000]];
            write(fd, ack.bytes, ack.length);
            self.phase = ELBPhaseVideoNegotiated;
            break;
        }
        case 98313: {  // 车机视频启动
            ELBLog(@"[handshake] 收到 98313 视频启动 → 进入 VIDEO_RUNNING（v1.1 在此推 H.264）");
            self.phase = ELBPhaseVideoRunning;
            break;
        }
        default:
            ELBLog(@"[msg] 未识别消息 %u", t);
            break;
    }
}

// v1.1 挂载点：把编码好的 H.264 帧写入 8240 连接（每帧 12B 头 + Annex-B）
- (void)pushVideoFrame:(NSData *)annexBNalu frameType:(uint32_t)frameType {
    // v1.0 预留：找到 8240 的写入 fd 由外部维护；此处仅占位
    (void)annexBNalu;
    (void)frameType;
    ELBLog(@"[video] pushVideoFrame 挂载点（v1.1 实现）");
}

@end
