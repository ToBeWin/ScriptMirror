# 贡献指南

感谢你对镜词 / ScriptMirror 的兴趣。

## 开始之前

1. 阅读 [README.md](README.md) 和 [PROJECT.md](PROJECT.md)，了解当前产品边界与技术决策。
2. 使用 Flutter stable 安装依赖：`flutter pub get`。
3. 相机、麦克风、旋转、前置镜像和离线 ASR 改动，请优先在真实 Android 设备上验证；模拟器只作为辅助。

## 提交变更

- 保持现有的深色视觉系统和离线优先原则。
- 不要引入需要网络上传文稿、音频或视频的流程。
- 提交前运行：

  ```sh
  flutter analyze
  flutter test
  (cd android && ./gradlew lintRelease)
  ```

- 涉及录制的变更请在 PR 描述中注明设备型号、Android 版本、前/后置镜头、分辨率和镜像设置。
- UI 变更请附上更新前后的截图；新增界面截图可以放入 `artifacts/audit/`。

## Issue 建议

请尽量提供复现步骤、设备/系统信息、应用版本和日志。涉及视频方向时，说明“录制预览”和“相册回放”各自的左右方向，不要只写“镜像异常”。
