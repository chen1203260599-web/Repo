# ElinkBridge v1.0（com.elinkbridge.ios）

**iPhone 作为「输出端」，向车机自带「驾驶伴侣」发送亿连/CarLife 兼容握手协议，打通 CarPlay 显示链路。**

目标环境：iOS 14–16.x **rootless**（dopamine / palera1n），iPhone 14 Pro 16.4.1 验证基线。
场景：吉利 SX11 / EX3 功夫牛车机自带「驾驶伴侣」（亿连车机端），**无 CarPlay 盒子**。

---

## 1. 目标链路

```
iPhone（输出端 / 发送端）
   ↕ 驾驶伴侣握手协议（亿连/CarLife 兼容，WiFi 或 USB）
车机「驾驶伴侣」（HU / 接收端，车机自带）
```

- 车机「驾驶伴侣」是接收端（HU），**主动**发起协议连接：连入 iPhone 监听的 7 个 TCP 端口。
- iPhone 侧由本插件承担「手机端」角色：监听端口 → 应答版本协商 → 上报设备信息 → 模块控制 → 特征配置 → 视频参数协商 → （v1.1）推 H.264 → （v1.2）注入触摸。
- 最终目标（v1.2）：iPhone 系统 CarPlay UI（CarPlayApp）渲染画面 → H.264 推流 → 车机驾驶伴侣屏幕显示 **CarPlay 界面**。

## 2. 协议依据（已实测验证的来源）

协议细节来自 CarPToCarL（github.com/jjuugk/CarPToCarL）`docs/carlife-hijack-findings.md` 对 CarLife/亿连兼容协议的实测逆向：

- **帧格式**：CMD 通道 `[u16 len][u16 rsv][u32 type]`（8B）；其余通道 `[u32 len][u32 seq][u32 type]`（12B）。
- **握手时序**（手机端视角）：收 `98305` 版本协商 → 回 `65538 matchStatus=1`；收 `98343` 统计 → 回 `65563 前台` + `65540 设备信息` + `65574 模块状态`；收 `98307 HU_INFO` → 回 `65574`；收 `98344 模块控制` → 回模块全开；收 `98386 特征配置`；收 `98311 视频初始化` → 回 `65544 编码参数确认`；收 `98313 视频启动` → 进入推流态；心跳 `131074` 每秒互答。
- **设备信息 protobuf 字段序**（1..24）：os, board, bootloader, brand, cpuAbi, cpuAbi2, device, display, fingerprint, hardware, host, cid, manufacturer, model, product, serial, codename, incremental, release, sdk, token, btaddress, carlifeversion, sdkInt。

> 注意：实测配方中 HU 主动发 `98305` 等；若你车机驾驶伴侣的组网是「车机开热点/同网」由车机主动连入 iPhone 端口，则本插件直接可用。若组网是「手机开热点、车机连手机」，需要把监听改为主动连接（v1.0 后按实测反馈调整）。

## 3. v1.0 已实现

| 模块 | 状态 |
|---|---|
| 7 端口 TCP 监听（7240/8240/9240/9241/9242/9340/9440） | ✅ |
| 握手状态机（版本→统计→设备信息→模块→特征→视频协商） | ✅ |
| protobuf 编解码（PBWriter/PBReader，支持 varint/string/bytes） | ✅ |
| 全消息日志（/var/mobile/Library/Logs/ElinkBridge.log） | ✅ |
| 设置面板（协议服务器开关 / 诊断开关 / 端口与路径说明） | ✅ |
| 触摸帧回调挂载点（onTouchFrame，v1.2 注入 CarPlay UI） | ✅ |
| 视频推流挂载点（pushVideoFrame，v1.1 接 VideoToolbox 编码） | ✅ |
| CarPlayApp 拉起（Ignition 思路，iOS 16 适配） | ⏳ v1.2 |
| H.264 编码 + 8240 推流 | ⏳ v1.1 |

## 4. 安装与使用

1. 编译出 DEB（见 §7），Sileo/Zebra 安装（rootless），重启 SpringBoard。
2. **组网（已确认）**：**车机「驾驶伴侣」开热点**，iPhone 连接该热点。
3. 连接后，插件自动执行：
   - **主动探测**：读取热点网关（车机 IP，如 192.168.43.1）→ 主动 TCP 连接车机 7240 端口（`[probe] ✅ 已连接车机驾驶伴侣`）
   - **监听兜底**：7 端口同时保持监听，若车机反过来主动连入也能应答
4. 握手由车机（HU）主导：车机发 98305 等，iPhone 应答。
5. 查看日志确认握手进度：
   ```
   [server] ✅ 监听端口 7240 (fd=…)
   [probe] 车机热点候选 IP: 192.168.43.1 192.168.43.254
   [probe] 尝试主动连接车机 192.168.43.1:7240 ...
   [probe] ✅ 已连接车机驾驶伴侣 192.168.43.1:7240，等待车机握手（98305）
   [msg] 端口 7240 收到消息 98305 (payload 4B)
   [handshake] 车机版本协商 major=3 minor=0
   [handshake] → 回 65538 matchStatus=1
   [handshake] 收到 98343 统计请求 → 回前台/设备信息/模块状态
   [handshake] 收到 98311 视频初始化 1280x720@30 → 回 65544 编码参数确认
   [handshake] 收到 98313 视频启动 → 进入 VIDEO_RUNNING
   ```

## 5. 卡点自检

| 日志特征 | 结论 | 处理 |
|---|---|---|
| 一直无「尝试主动连接」 | 未连上车机热点 | 确认 iPhone 已连车机热点；确认插件已加载（日志有 loaded） |
| 候选 IP 均未连通 | 车机 7240 未监听/不在线 | 确认车机驾驶伴侣处于「等待连接」状态；把热点网关 IP 反馈（日志已打印） |
| 已连接但无 98305 | 车机握手包格式不同 | 抓包回传（Tools/analyze_pcap.py），核对帧格式 |
| 98305 后无 98343 | 版本/设备信息不匹配 | 把 65540 设备信息按你车机接受的字段补全 |
| 卡在 98311 视频协商 | 编码参数不被接受 | 调整宽高/帧率/码率重试 |
| 到 VIDEO_RUNNING | 握手完成 ✅ | 进入 v1.1 推流阶段 |

## 6. 路线图

- **v1.1**：VideoToolbox H.264 编码 + `pushVideoFrame` 写入 8240 + 心跳保活 → 车机显示 iPhone 投屏画面（先验证视频通道）。
- **v1.2**：Ignition 式 CarPlayApp 拉起（FrontBoard 关联，iOS 16 适配）+ IOSurface 画面捕获 → 车机显示 **系统 CarPlay 界面**；9340 触摸注入回 CarPlay UI。
- **v1.3**：USB 模式（Lightning 直连车机 USB，走 CarLife USB 协议）。

## 7. 编译（出 DEB）

### 方式 A：GitHub Actions（推荐）
1. 推 GitHub 仓库 → Actions 手动运行 **Build ElinkBridge DEB**（或打 `v*` tag）。
2. 下载 artifact `*.deb` 安装。

### 方式 B：本地 macOS/Linux
```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
make package
```

## 8. 文件结构

```
├─ Tweak.xm                                # 注入层：启动协议服务器、日志、设置
├─ src/CarLifeServer.h/.m                  # 7 端口 TCP 服务 + 握手状态机
├─ src/CarLifeProto.h/.m                   # protobuf 编解码 + 消息构造
├─ Makefile / control / ElinkBridge.plist
├─ layout/Library/PreferenceLoader/...     # 设置面板
├─ .github/workflows/build.yml             # 云编译
└─ Tools/analyze_pcap.py                   # CarPlay/CarLife 握手 PCAP 分析
```
