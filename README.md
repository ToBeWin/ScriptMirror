# 镜词 / ScriptMirror

这是一个 mobile-first、local-first 的自拍视频提词器。当前首批界面基于 `stitch_scriptmirror_app_design_ui` 的视觉稿实现为 Flutter UI，并已适配 Android 与 iOS（当前验收版本 `0.1.3+2010`）：

- 首页与最近文稿
- 文稿行编辑、拆分/合并、重命名、删除和拖动排序；新建与编辑返回时都保护未保存改动
- 独立的新建文稿工作台（实时字数/分句统计、TXT/Markdown 导入、离线提示、大输入区）
- 拍摄准备（镜头、画质、提词速度、自动推进开关）
- 沉浸式录制页（Android CameraX / iOS AVFoundation 原生预览与录制、计时、手动翻句、ASR 视觉状态）
- 完成页、录制中断恢复提示与设置页
- 首次启动默认 English；设置中可切换 English / 简体中文，选择会保存在本机
- 英文界面已覆盖首页、文稿录入与编辑、拍摄准备、录制、完成和设置等核心路径
- iPad 与 Android 平板的编辑/设置页面使用居中限宽布局，拖动文稿列表时会自动收起键盘

首页的“开始拍摄”从稳定的默认示例文稿进入，首次录制被系统打断后也能恢复；停止后音视频合并期间会锁定录制控制，避免误触改变即将保存的提词位置。

后续用 v0.dev 做视觉精修时，可直接使用项目内的 [V0_REFINEMENT_PROMPT.md](V0_REFINEMENT_PROMPT.md)，并把 `stitch_scriptmirror_app_design_ui` 中的截图作为参考输入。

Pen.dev 高保真精修稿已保存在 [ScriptMirror_UI_Refined.pen](ScriptMirror_UI_Refined.pen)，包含首页、脚本编辑、新建文稿、拍摄准备、沉浸式录制、完成页和设置画板，并额外保留了可复用的提词预览组件。设计稿只负责视觉与交互评审，Flutter 的 SQLite、原生相机、恢复和 ASR 契约保持不变。

极简版 App logo 已落在 [assets/branding/scriptmirror-logo-v2.png](assets/branding/scriptmirror-logo-v2.png)，同时用于首页品牌标记、Android launcher、iOS AppIcon 和两端冷启动画面；设计说明见 [assets/branding/README.md](assets/branding/README.md)。Android 12+ 使用 adaptive icon 安全区，避免系统圆形遮罩裁切 Logo。

## 界面预览

下面是当前 Flutter 实现的主要界面，覆盖从文稿录入到录制完成的完整路径：

<table>
  <tr>
    <td align="center"><img src="artifacts/audit/02-home-current.png" width="210" alt="首页"><br><sub>首页</sub></td>
    <td align="center"><img src="artifacts/audit/03-entry-current.png" width="210" alt="新建文稿"><br><sub>新建文稿</sub></td>
    <td align="center"><img src="artifacts/audit/04-editor-current.png" width="210" alt="文稿编辑"><br><sub>文稿编辑</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="artifacts/audit/06-prepare-current.png" width="210" alt="拍摄准备"><br><sub>拍摄准备</sub></td>
    <td align="center"><img src="artifacts/audit/08-recording-front-camera.png" width="210" alt="沉浸式录制"><br><sub>沉浸式录制</sub></td>
    <td align="center"><img src="artifacts/audit/09-complete-front-camera.png" width="210" alt="录制完成"><br><sub>录制完成</sub></td>
  </tr>
</table>

设计探索和交互精修文件也随仓库提供：

- [Stitch 设计稿与导出截图](stitch_scriptmirror_app_design_ui)
- [Pen.dev 高保真精修稿](ScriptMirror_UI_Refined.pen)
- [v0 精修提示词](V0_REFINEMENT_PROMPT.md)

## 当前状态

当前已经接入 Android CameraX（Camera2 之上的原生相机栈）和 iOS AVFoundation 的预览、默认 1080p 录制（可切换 720p，设备不支持时自动降级）、单一原生麦克风所有者、共享 PCM 音频分发、AAC/MOV 音频编码与系统媒体库保存，以及 SQLite 文稿/设置/恢复记录。前置自拍预览可按“自拍镜像”设置保持熟悉的镜像取景；开启时 Android `VideoCapture` 与 iOS `AVCaptureConnection` 都保持预览和成片一致，关闭时预览与成片均为正常方向。两端都在原生层绑定录制旋转，避免成片横向、画面倾斜或构图偏移；Android 10+ 写入 `DCIM/ScriptMirror`，iOS 写入系统 Photos，完成页提供直接打开已保存视频的入口。录制页支持慢速/中速/快速的按时长自动推进和手动翻句，长台词会在提词面板内自适应缩放；宿主暂停时原生录制会主动收尾，并在恢复后显示真实的保存结果和可继续的台词位置；系统检测到高温时仅显示建议切换 720p 的提示，不强行中断当前录制。取消按钮在原生录制刚完成启动、Flutter 状态尚未切换的竞态窗口里也会由原生层丢弃刚启动的片段；系统切后台则保留已开始的片段并走中断恢复流程，系统返回键也会先确认“结束并保存”或“离开”，避免误触直接销毁录制页。Flutter 侧现在使用随包内置的 sherpa-onnx 中文 streaming CTC 与英文 streaming Zipformer transducer 模型，并在倒计时前完成本地模型预热：识别完全在本机 CPU 运行，不申请网络权限、不上传录音，Android 与 iOS 都消费录制所有者共享的 PCM（iOS 会将设备硬件采样率转换为模型需要的 16 kHz 单声道）。识别语言默认根据文稿中英文字符自动选择，也可以在设置中手动指定。桌面端和 Flutter widget 测试使用预览录制服务，不会伪报视频已保存。

模型和词表在复制到应用私有目录前会校验固定 SHA-256；已有缓存若校验不通过会自动重写，校验失败则明确降级为定时/手动提词。每次进入录制准备时，还会仅清理应用自己的 `DCIM/ScriptMirror` 下超过 1 小时的 pending 媒体行和 `.pending-…ScriptMirror_*.mp4` 孤儿临时文件，避免进程异常退出后的残留空间长期累积。

英文界面会明确显示当前随包模型的语言范围；中文与英文文稿都使用对应的离线模型，模型初始化失败时会自动降级为按节奏或手动翻句，不会阻断录制。

项目的 Flutter SDK 安装与平台模板生成必须在可运行的 Flutter/Dart 环境中完成：

```sh
flutter pub get
flutter run -d <android-device>
flutter build apk --release
# 可选：生成可互相覆盖安装的分 ABI 包
flutter build apk --release --split-per-abi --android-project-arg force-version-code-ignoring-abi=true

# iOS（需要 macOS + Xcode；真机需要自己的签名团队）
flutter run -d <ios-device-or-simulator>
flutter build ios --release --no-codesign
open ios/Runner.xcworkspace
```

最后一轮真机验收请按 [DEVICE_QA.md](DEVICE_QA.md) 执行；模拟器无法代替真实镜头、麦克风和系统相册对前置镜像、旋转及离线识别的确认。

若要单独回归随包模型，可用项目内的主机端烟测脚本（需要一个 16 kHz、单声道 WAV；脚本不会打开麦克风）：

```sh
dart run tool/sherpa_asr_smoke.dart /path/to/16k-mono.wav
# 英文模型
dart run tool/sherpa_asr_smoke.dart /path/to/16k-mono.wav --english
```

若要同时回归“ASR partial → 稳定翻句”，可运行组合烟测；第二个参数可要求至少翻过几句：

```sh
dart run tool/sherpa_alignment_smoke.dart /path/to/16k-mono.wav
# 多句连续口播至少验证两次单调推进
dart run tool/sherpa_alignment_smoke.dart /path/to/16k-mono.wav 2
```

该脚本同样不会打开麦克风或联网。

## 开源开发

代码以 [MIT License](LICENSE) 发布，欢迎通过 Issue 或 Pull Request 改进 UI、补充设备兼容性记录或完善录制体验。提交前请运行：

```sh
flutter analyze
flutter test
(cd android && ./gradlew lintRelease)
```

贡献相机、音频、镜像、旋转或 ASR 相关功能时，请在说明中记录真实设备型号、系统版本、前/后置镜头和复现步骤。完整约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

随包 sherpa-onnx 运行时来自 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)；英文 20M 模型来自 [csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17)，模型卡标注 Apache-2.0。重新分发包含模型的构建时，请同时核对上游项目及模型文件的许可证和署名要求。

Release APK 已启用 R8/ProGuard、资源压缩和 JNI 库压缩；当前同时内置中英文模型，通用包约 116MB，arm64 手机包约 80MB，模拟器 x86_64 包约 82MB，均包含离线识别模型。分 ABI 构建建议带上 `--android-project-arg force-version-code-ignoring-abi=true`，这样通用包和分 ABI 包保持同一 versionCode，可互相覆盖安装。原生 `NativeCaptureController` + `NativeAudioCapture`（Android）或 `ScriptMirrorCaptureController`（iOS）是录制期间唯一的音频所有者；`SherpaAsrProvider` 订阅同一条共享 PCM 流，避免多个插件同时抢占麦克风。这里的“原生相机”指 App 内嵌的 Android CameraX/Camera2 或 iOS AVFoundation 相机栈；若改为直接拉起手机自带相机 App，提词文字将无法继续叠加在取景画面上。

当前 Release APK 使用本地测试签名，适合直接安装验收；正式发布到应用商店前仍需替换为项目自己的 release keystore。iOS 的 `--no-codesign` 构建只用于 CI/模拟器和源码验收，提交 App Store 前需在 Xcode 中配置自己的 Team、Bundle ID、证书与 provisioning profile。
