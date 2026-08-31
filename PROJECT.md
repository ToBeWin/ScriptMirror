# 镜词 / ScriptMirror — 项目规格与开发路线

## 0. 项目摘要

**镜词**是一款 Android-first、为日常自拍视频口播设计的本地优先 App。用户先粘贴文稿，系统把文稿拆成台词行；用户使用前/后摄像头录制视频时，在屏幕上半部看到当前句和未来 2–3 句。系统在可用时接收实时 ASR 的临时结果，并将它与已知文稿对齐，谨慎推进台词；不可用时仍可使用定时和手动翻句完成录制。

### 成功定义

用户可以在不登录、不联网、不学习复杂设置的情况下，选择一篇文稿，在一分钟内完成一次自然的自拍视频录制。ASR 能增强体验，但它失败绝不能让录制失败。

## 1. 范围与约束

### V1 必须交付

1. 本地文稿 CRUD，整篇粘贴后自动分句。
2. 每句的预计时长和句后停顿，提供默认值和手动编辑。
3. 前/后摄像头视频录制，默认前置、1080p、带音频；前置“自拍镜像”开关会同步作用于预览和成片，保证两者方向一致。
4. 上半部分半透明提词覆盖层；当前句 + 后 2 句；已读内容消失。
5. 字号、行距、透明度、显示行数、镜像预览的设置。
6. 定时推进、手动上/下一句、开始倒计时。
7. 实时 ASR 适配层、部分识别结果上报、文稿对齐与保守自动推进。
8. 录制完成保存到系统相册，出现异常时尽可能保留视频。
9. 无网络时，基础拍摄和提词完整可用。

### V1 明确不做

- 注册、登录、同步、订阅、广告、社交分享。
- 云端视频备份、AI 文案生成、自动剪辑、滤镜、美颜。
- 双摄同时录制、视频暂停拼接、外接设备。
- 保证所有机型离线 ASR 都可用。

### 非功能约束

| 项目 | 目标 |
|---|---|
| 首装包 | 使用 ABI 拆分；arm64 Release 约 40 MB（内置一套中文离线模型） |
| 首选平台 | Android，minSdk 26；UI 保持 iOS 可移植性 |
| 默认网络 | 不需要；V1 识别默认使用本地离线模型，不接入在线 ASR |
| 默认视频 | 1080p；低端/高温设备可建议 720p |
| 隐私 | 文稿、视频、识别结果默认本地保存，不发送遥测 |
| 录制稳定性 | ASR、网络或对齐失败不应中断视频录制；合并音视频不得丢失原生旋转信息 |

## 2. 建议技术架构

```text
Flutter UI / Domain
├─ presentation
│  ├─ Home, Script Editor, Preparation, Capture, Completion
│  └─ TeleprompterRenderer / CaptureViewModel
├─ domain
│  ├─ Script, ScriptLine, TeleprompterSession
│  ├─ AlignmentEngine, AdvancePolicy, TextNormalizer
│  └─ repositories interfaces
├─ data
│  ├─ local script/settings database
│  └─ platform-channel adapters
└─ platform bridge
   ├─ CaptureService (Kotlin)
   │  ├─ CameraX preview + VideoCapture/Recorder
   │  ├─ one microphone/audio pipeline
   │  ├─ ASR audio feed
   │  └─ media-store writer / recovery
   └─ AsrProvider
      ├─ SystemAsrProvider (initial)
      ├─ OnlineAsrProvider (optional)
      └─ OfflineAsrProvider (downloadable later)
```

### 技术选择

| 层 | 选型 | 原因 |
|---|---|---|
| 跨平台 UI | Flutter / Dart | 页面与提词动画统一，后续可扩展 iOS |
| Android 相机 | Kotlin + CameraX | 优先采用官方相机栈与真实设备验证 |
| iOS 后续 | Swift + AVFoundation | 与 Android 保持同一 bridge 契约 |
| 状态管理 | Riverpod 或 BLoC（二选一） | 状态可预测、适合录制会话状态机 |
| 本地存储 | SQLite/Drift 或 Isar（二选一） | 仅存文稿、设置和轻量会话恢复数据 |
| ASR | Provider 抽象 | 避免把产品绑定到单个系统/云服务 |

不要同时使用多个相机插件、音频插件和 ASR 插件去抢同一个麦克风。生产实现必须让原生 `CaptureService` 成为录制期间唯一的音频资源拥有者，向视频编码与 ASR 分发同一音频流。

## 3. 核心数据模型

```dart
class Script {
  String id;
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  List<ScriptLine> lines;
}

class ScriptLine {
  String id;
  int order;
  String text;
  int expectedDurationMs;
  int pauseAfterMs;
  List<String> keywords; // 可空；供后续高级对齐使用
}

enum RecognitionMode { disabled, system, online, offline }
enum CapturePhase { idle, preparing, countdown, recording, stopping, completed, failed }
enum AlignmentState { unavailable, initializing, listening, confirming, degraded }

class TeleprompterSession {
  String scriptId;
  int currentLineIndex;
  int? manualOverrideUntilMs;
  RecognitionMode recognitionMode;
  AlignmentState alignmentState;
  CapturePhase capturePhase;
}
```

文稿以“台词行”为最小单元；不要只存一大段文本再在录制中临时切句。

## 4. 实时跟稿：实现要求

### 4.1 输入与输出

原生桥接向 Flutter 连续发送结构化事件：

```json
{
  "type": "asrPartial",
  "text": "今天我想分享一个很好用的拍摄方式",
  "isFinal": false,
  "confidence": 0.82,
  "timestampMs": 12400
}
```

Flutter 对齐引擎输出：

```json
{
  "type": "alignmentDecision",
  "currentLineIndex": 3,
  "candidateLineIndex": 4,
  "coverage": 0.84,
  "shouldAdvance": true,
  "reason": "stableCoverage"
}
```

### 4.2 对齐算法（V1）

1. 规范化 ASR 文本与文稿：统一大小写、去标点与空白、统一数字、按需去除常见语气词。
2. 只评估 `[current - 1, current, current + 1, current + 2, current + 3]`。
3. 对候选行计算：字符 n-gram 相似度、关键词命中、已读前缀进度、与上一事件的连续性。
4. 将最近 3–5 个 partial 结果做滚动合并，避免只依赖单次不稳定结果。
5. 达到 80% 覆盖率，或达到 65% 且检测到停顿，才能自动推进一行。
6. 跨过一行跳转时，要求更高阈值（例如 90%）且连续两次确认。
7. 系统绝不自动回退；手动回退后，在短时间内冻结自动跳转，避免立即被 ASR 覆盖。
8. ASR 没有可靠进展时，超时后按该行预设时长推进，但该策略必须可关闭。

### 4.3 ASR 策略

- V1 使用随包内置的 sherpa-onnx 中文 streaming CTC 模型；`AsrProvider` 只消费原生录制所有者共享的 PCM。
- 识别在本机 CPU 完成，不申请网络权限、不上传音频；模型初始化失败时必须降级为定时/手动提词，不得中断视频录制。
- 模型在录制倒计时前预热，避免首次加载导致开头语音丢失。
- 不要将 ASR 临时全文直接呈现给用户；它是后台信号，不是产品主界面。

## 5. 关键状态机

```text
IDLE
  → PREPARING (检查文稿、存储、权限、相机、ASR)
  → COUNTDOWN
  → RECORDING
       ├─ ALIGNING（正常子状态）
       ├─ DEGRADED（按节奏/手动子状态）
       └─ INTERRUPTED（来电、权限、资源丢失）
  → STOPPING
  → COMPLETED | FAILED
```

状态机要求：

- `stop` 可重复调用且只会写入一个最终媒体结果。
- 相机初始化失败时允许返回准备页并解释原因。
- ASR 初始化失败只进入 `DEGRADED`，不进入 `FAILED`。
- 录制中 App 生命周期变化必须保存当前文稿行号与临时媒体信息。
- 任何失败都需要说明“视频是否已保存”“台词位置是否保留”“下一步可做什么”。

## 6. 包体积控制

1. 基础安装包内置一套中文小型离线模型；不打包其他语言或重复模型，Release 使用 ABI 拆分控制体积。
2. 使用 R8/ProGuard、资源压缩与 ABI 拆分；只保留确实需要的 native ABI。
3. 图片优先使用矢量图标；不使用大背景图、定制字体包、示例视频或内置教程视频。
4. 新依赖合入前记录其 APK/AAB 增量；大型 SDK 要有明确产品价值。
5. 当前离线模型随包提供，不需要下载；后续增加其他语言时再显示下载大小、存储位置和删除入口。

## 7. 权限、隐私与安全

| 权限/能力 | 请求时机 | 说明 |
|---|---|---|
| 相机 | 用户在拍摄准备点击开始录制 | “用于录制自拍视频。” |
| 麦克风 | 同上 | “用于保存视频声音与智能跟稿。” |
| 相册/媒体写入 | 保存视频时，按 Android 版本处理 | “用于将完成的视频保存到相册。” |
| 网络 | 不申请 | V1 不提供在线识别，音频和文稿不离开设备 |

- 不采集账号信息，不默认上传媒体、文稿、音频或转写文本。
- Release 日志不得输出原始文本、识别结果、视频路径和 token。
- 若未来增加在线 ASR，必须先显示服务性质和数据去向，并提供明确的关闭开关。

## 8. 开发阶段与验收

### Phase 1：可录制的定时提词器

交付：文稿编辑、拍摄准备、前后摄像头、视频保存、上半部提词层、预设时长推进、手动翻句。

验收：没有 ASR 的情况下，用户可完整录制一篇 3 分钟文稿并从相册找到视频。

### Phase 2：ASR 与文稿对齐

交付：系统 ASR adapter、partial 事件、规范化、窗口匹配、稳定确认、降级状态。

验收：在安静环境中读 20 句普通中文稿，正常速度/慢速/快速时均能按顺序推进；人为关闭 ASR 后体验不受阻。

### Phase 3：稳定性与设备测试

交付：中断恢复、低存储检查、权限拒绝路径、长录制测试、发热降级提醒、错误报告（不含内容）。

验收：每台目标设备完成 10 分钟录制；来电/切后台/ASR 失败后给出确定且真实的结果。

### Phase 4：离线识别（当前已接入）

交付：内置中文 streaming 模型、模型文件校验、CPU 推理、共享 PCM 输入和识别失败降级。

验收：在无网络状态下，模型可以初始化；ASR 失败时仍可用定时/手动提词完成录制。

## 9. 测试清单

### 自动化测试

- 文本分句、合并、拆分、排序与本地持久化。
- 文本规范化、同音/漏标点容忍、评分和推进阈值。
- 手动翻句后的自动对齐冻结。
- 录制状态机的合法/非法状态转移。
- 设置影响 UI 的快照/组件测试。

### 真机测试

- 前/后摄像头、前置镜像、横竖屏、耳机/蓝牙/无耳机。
- 首次授权、拒绝授权、再次授权、永久拒绝。
- 弱网、无网、ASR 服务不可用、ASR 中途失败。
- 来电、通知、锁屏、切后台、存储不足、相机被其他 App 占用。
- 光线极亮/极暗；18sp 与 42sp 台词可读性。
- 3 分钟、10 分钟录制；720p 与 1080p；至少一台低端和一台中高端 Android 设备。

## 10. 发布前 Definition of Done

- 所有 V1 功能具备中文 UI 和错误状态。
- 无 ASR、无网络、权限被拒时仍有明确可执行路径。
- 相册保存结果可验证，失败不会虚报成功。
- 不含调试日志、密钥或测试视频；离线模型只保留当前中文小型模型。
- Release 包使用 ABI 拆分，并在目标机型做过长录制与中断测试。
- 用户可在不阅读教程的情况下完成：创建文稿 → 选择前置镜头 → 录制 → 保存视频。
