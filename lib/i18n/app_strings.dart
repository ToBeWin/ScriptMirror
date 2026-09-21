import 'package:flutter/foundation.dart';

/// Languages available in the local-first app. English is intentionally the
/// first-run default for the international release; users can switch to
/// Simplified Chinese from Settings without changing their scripts or media.
enum AppLanguage { english, chinese }

extension AppLanguageX on AppLanguage {
  String get storageValue => name;

  static AppLanguage fromStorage(String? value) => switch (value) {
    'chinese' => AppLanguage.chinese,
    _ => AppLanguage.english,
  };
}

/// Small, dependency-free localization layer for the existing Flutter UI.
///
/// The project deliberately keeps user scripts as user-authored content. Only
/// product chrome is translated here, so changing language never rewrites a
/// script, title, or saved media metadata.
class AppStrings {
  AppStrings._();

  static final ValueNotifier<AppLanguage> language = ValueNotifier<AppLanguage>(
    AppLanguage.english,
  );
  static bool _explicitlySet = false;

  static bool get explicitlySet => _explicitlySet;

  static AppLanguage get currentLanguage => language.value;

  static void setLanguage(AppLanguage next) {
    _explicitlySet = true;
    if (language.value != next) language.value = next;
  }

  static String t(String source) {
    if (language.value == AppLanguage.chinese) return source;
    return _english[source] ?? source;
  }

  static String replace(String template, Map<String, Object?> values) {
    var result = t(template);
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return result;
  }

  static const Map<String, String> _english = {
    '镜词': 'ScriptMirror',
    '镜词 / 创作者工具': 'SCRIPTMIRROR / CREATOR TOOL',
    'SCRIPT MIRROR  /  CREATOR TOOL': 'SCRIPTMIRROR  /  CREATOR TOOL',
    '夏季防晒分享': 'Summer skincare tips',
    '课程开场': 'Course opening',
    '产品介绍短视频': 'Product intro video',
    '看着镜头，\n也不用忘记下一句。': 'Stay focused on the lens.\nNever lose your next line.',
    '把注意力留给镜头，把节奏交给镜词。':
        'Keep your eyes on camera. Let ScriptMirror keep your pace.',
    '开始拍摄': 'Start recording',
    '新建文稿': 'New script',
    '全部文稿': 'All scripts',
    '最近文稿': 'Recent scripts',
    '全部  ›': 'View all  ›',
    '设置': 'Settings',
    '返回': 'Back',
    '离线优先  ·  文稿与视频只保存在本机':
        'Offline-first  ·  Scripts and videos stay on this device',
    '本地离线识别 · 开始前自动准备': 'Offline recognition · Ready before you record',
    '本地离线识别 · 中文模型已内置': 'Offline recognition · Chinese model included',
    '本地离线识别 · 英文模型已内置': 'Offline recognition · English model included',
    '本地离线识别 · 按文稿自动选择': 'Offline recognition · Model selected from script',
    '本地离线处理 · 音频不会上传': 'Processed offline · Audio is never uploaded',
    '本地离线处理 · 中文模型': 'On-device offline · Chinese model',
    '本地离线处理 · 中英文模型': 'On-device offline · Chinese + English models',
    '离线处理 · 文稿不会上传': 'Processed offline · Scripts are never uploaded',
    '准备开始录制': 'Ready to record',
    '镜词只在你点击开始后使用相机和麦克风，视频交给系统相册管理。':
        'ScriptMirror uses your camera and microphone only after you start. Finished videos are managed by your system gallery.',
    '相机': 'Camera',
    '用于录制自拍视频。': 'Used to record your video.',
    '麦克风': 'Microphone',
    '用于保存视频声音与智能跟稿。': 'Used for video audio and smart line tracking.',
    '系统相册': 'System gallery',
    '完成后写入系统媒体库，便于在照片中找到视频。':
        'Saves to the system media library so you can find the video in Photos.',
    '稍后': 'Not now',
    '继续并授权': 'Continue and allow',
    '视频画质': 'Video quality',
    '默认画质': 'Default quality',
    '设备不支持时会自动选择更低画质': 'A lower quality is selected automatically when needed',
    '请先粘贴一段文稿': 'Paste a script first',
    '未命名文稿': 'Untitled script',
    '文稿暂时无法保存，请稍后重试': 'The script could not be saved. Try again in a moment.',
    '画质设置暂时无法保存，将继续使用当前值':
        'Video quality could not be saved. The current value will continue to be used.',
    '暂时无法丢弃这条恢复记录，请稍后重试':
        'The recovery record could not be dismissed. Try again in a moment.',
    '示例文稿': 'Sample script',
    '4 行': '4 lines',
    '行': 'lines',
    '字': 'chars',
    '句台词': 'script lines',
    '秒': 'sec',
    '停': 'Pause',
    '已保存到本机': 'Saved on this device',
    '本机文稿': 'Local script',
    '拍摄草稿': 'Recording draft',
    '还没有保存的文稿': 'No saved scripts yet',
    '回到首页粘贴一篇文稿即可开始。': 'Paste a script on the home screen to get started.',
    '发现未完成录制': 'Unfinished recording found',
    '从第 {line} 行继续': 'Continue from line {line}',
    '已保留到第 {line} 行，可从这里继续': 'Saved through line {line}. Continue from here.',
    '继续准备': 'Continue setup',
    '丢弃记录': 'Discard record',
    '先把想说的话放进来': 'Start with what you want to say',
    '镜词会按中英文标点自动拆成可提词的台词行。':
        'ScriptMirror turns Chinese and English punctuation into easy-to-read lines.',
    '文稿信息': 'Script details',
    '台词内容': 'Script content',
    '文稿标题': 'Script title',
    '例如：夏季防晒分享': 'e.g. Summer skincare tips',
    '等待输入': 'Waiting for input',
    '输入或粘贴整篇台词……\n\n每个句号、问号或换行都会成为自然的提词停顿。':
        'Type or paste your full script…\n\nPeriods, question marks, and line breaks become natural teleprompter pauses.',
    '导入文稿': 'Import script',
    '支持 TXT / Markdown': 'TXT / Markdown supported',
    '选择一个 TXT 或 Markdown 文件': 'Choose a TXT or Markdown file',
    '文稿已导入': 'Script imported',
    '文件读取失败，请重试': 'The file could not be read. Try again.',
    '这个文件没有可用的文字内容': 'This file does not contain usable text.',
    '整理台词并继续': 'Organize and continue',
    '本机': 'On this device',
    '先输入一段台词，镜词才能帮你整理节奏': 'Add some lines so ScriptMirror can shape the pacing',
    '放弃这篇文稿？': 'Discard this script?',
    '已经输入的标题和台词还没有保存，离开后需要重新录入。':
        'Your title and lines are not saved. Leaving now means entering them again.',
    '继续编辑': 'Keep editing',
    '放弃文稿': 'Discard script',
    '保存这次改动？': 'Save these changes?',
    '你修改了台词内容或节奏，保存后下次拍摄会使用最新版本。':
        'You changed the lines or pacing. Save to use the latest version next time.',
    '放弃改动': 'Discard changes',
    '保存并返回': 'Save and go back',
    '已添加台词，可点击右侧按钮编辑内容和时长':
        'Line added. Tap the row to edit its text and timing.',
    '节奏设置': 'Pacing',
    '已拆分为': 'Split into',
    '重命名文稿': 'Rename script',
    '删除文稿': 'Delete script',
    '本机保存': 'Saved locally',
    '添加台词': 'Add line',
    '长按拖动排序 · 点击编辑时长与停顿': 'Drag to reorder · Tap to edit timing and pauses',
    '进入拍摄准备': 'Continue to setup',
    '请填写有效的台词、时长和停顿': 'Enter valid lines, durations, and pauses',
    '编辑这句台词': 'Edit this line',
    '调整内容与镜头前的节奏': 'Tune the words and pacing for camera',
    '预计时长（秒）': 'Estimated duration (sec)',
    '句后停顿（秒）': 'Pause after line (sec)',
    '保存这句': 'Save line',
    '拆分这句': 'Split line',
    '合并下一句': 'Merge with next',
    '这句暂时找不到合适的拆分位置，请先加入标点或空格':
        'No split point found. Add punctuation or a space first.',
    '最后一句没有可合并的下一句': 'There is no next line to merge.',
    '已与下一句合并': 'Merged with the next line',
    '删除这篇文稿？': 'Delete this script?',
    '取消': 'Cancel',
    '删除': 'Delete',
    '文稿暂时无法删除，请稍后重试': 'The script could not be deleted. Try again in a moment.',
    '标题暂时无法保存，请稍后重试': 'The title could not be saved. Try again in a moment.',
    '台词': 'Lines',
    '预计时长': 'Estimated time',
    '模式': 'Mode',
    '离线优先': 'Offline-first',
    '提词速度': 'Prompt speed',
    '控制自动推进每句台词的等待时间': 'Controls how long each line stays on screen',
    '慢速': 'Slow',
    '给停顿和思考留出更多时间': 'More room for pauses and thought',
    '中速': 'Medium',
    '适合大多数自拍视频': 'Good for most selfie videos',
    '快速': 'Fast',
    '更紧凑地推进台词': 'Moves through lines more tightly',
    '权限未开启，无法开始录制；请在系统设置重新允许相机和麦克风':
        'Camera and microphone access is required. Allow them in System Settings and try again.',
    '打开设置': 'Open Settings',
    '拍摄准备': 'Recording setup',
    '镜头选择': 'Camera',
    '前置镜头': 'Front camera',
    '后置镜头': 'Rear camera',
    '录制设置': 'Recording settings',
    '自动推进': 'Auto advance',
    '按预设时长自动滚动': 'Advance using line timing',
    '手动翻句': 'Manual advance',
    '上一句': 'Previous line',
    '下一句': 'Next line',
    '停止': 'Stop',
    '继续': 'Continue',
    '正在准备…': 'Preparing…',
    '开始录制': 'Start recording',
    '提词预览': 'Teleprompter preview',
    '相机没有准备好，请返回后重试': 'The camera is not ready. Go back and try again.',
    '麦克风无法启动，请检查权限后重试':
        'The microphone could not start. Check permissions and try again.',
    '可用存储空间不足，请清理后重试':
        'There is not enough storage. Free up space and try again.',
    '上一段录制正在保存，请稍候再试':
        'The previous recording is still being saved. Try again shortly.',
    '已取消录制准备，请返回拍摄准备后重试':
        'Recording setup was cancelled. Return to setup and try again.',
    '相机编码器未能生成视频，请返回后重试':
        'The camera encoder could not create a video. Go back and try again.',
    '录制已被中断，视频未保存': 'Recording was interrupted and the video was not saved.',
    '录制过程中出现问题，视频未保存，请返回后重试':
        'Something went wrong while recording. The video was not saved.',
    '相机初始化失败，请返回准备页检查权限或更换镜头':
        'Camera setup failed. Check permissions or switch cameras.',
    '相机初始化失败，请返回后重试': 'Camera setup failed. Go back and try again.',
    '录制启动失败，视频未保存，请返回后重试':
        'Recording could not start. The video was not saved.',
    '录制准备被中断，请回到拍摄准备后重试':
        'Recording setup was interrupted. Return to setup and try again.',
    '返回拍摄准备': 'Back to recording setup',
    '录制已中断，保存结果暂未返回，请稍后到系统相册查看':
        'Recording was interrupted. Check the system gallery shortly for the saved result.',
    '录制服务暂时不可用，视频未保存':
        'The recording service is unavailable. The video was not saved.',
    '录制服务已关闭': 'The recording service is closed.',
    '录制尚未开始': 'Recording has not started yet.',
    '停止操作已在处理中': 'The stop request is already being processed.',
    '录制准备已取消': 'Recording setup was cancelled.',
    '可用存储空间不足，至少需要 100 MB':
        'There is not enough storage. At least 100 MB is required.',
    '无法启动共享麦克风音频': 'Shared microphone audio could not start.',
    '麦克风权限不可用': 'Microphone permission is unavailable.',
    '录制服务暂时不可用': 'The recording service is temporarily unavailable.',
    '相机权限不可用': 'Camera permission is unavailable.',
    '相机在此设备上不可用': 'The camera is not available on this device.',
    '系统相册权限不可用': 'System Photos permission is unavailable.',
    '视频文件写入相册失败': 'The video could not be saved to Photos.',
    '录制没有生成视频文件': 'The recording did not produce a video file.',
    '视频已保存，但音频合并失败':
        'The video was saved, but its audio could not be finalized.',
    '相机尚未准备好': 'The camera is not ready yet.',
    '录制启动正在处理中': 'Recording startup is already being processed.',
    '相机初始化失败': 'Camera setup failed.',
    '正在保存录制结果，请稍候': 'Saving the recording. Please wait.',
    '结束这次录制？': 'Finish this recording?',
    '离开拍摄准备？': 'Leave recording setup?',
    '确认后会结束并保存当前视频。': 'This will finish and save the current video.',
    '确认后会取消本次录制准备，不会生成视频。':
        'This cancels recording setup and no video will be created.',
    '继续录制': 'Keep recording',
    '结束并保存': 'Finish and save',
    '离开': 'Leave',
    '录制中设置': 'Recording settings',
    '本次录制的镜头、画质和镜像状态已锁定，下一次录制前可在设置中调整。':
        'The camera, quality, and mirror state are locked for this take. Change them in Settings before the next recording.',
    '知道了': 'Got it',
    '跟稿中': 'Tracking',
    '准备本地识别': 'Preparing offline recognition',
    '按节奏提词': 'Pacing mode',
    '设备温度较高，建议录制完成后切换到 720p':
        'The device is warm. Consider switching to 720p after this recording.',
    '设备温度较高 · 本次录制不会中断，下一次可切换 720p':
        'The device is warm · this take will continue; switch to 720p next time.',
    '录制已中断': 'Recording interrupted',
    '暂时无法开始录制': 'Recording unavailable',
    '正在保存录制结果': 'Saving recording',
    '请稍候，音视频正在完成合并。': 'Please wait while audio and video are finalized.',
    '录制完成': 'Recording complete',
    '录制未保存': 'Recording not saved',
    '录制被中断，但视频已保存': 'Recording was interrupted, but the video was saved',
    '录制被中断，视频未保存': 'Recording was interrupted and the video was not saved',
    '视频已保存到相册': 'Video saved to the gallery',
    '视频文件没有写入相册': 'The video was not written to the gallery',
    '分辨率': 'Resolution',
    '未读取': 'Unavailable',
    '未生成': 'Not created',
    '时长': 'Duration',
    '文件大小': 'File size',
    '由系统相册管理': 'Managed by the system gallery',
    '保存位置': 'Saved location',
    '系统没有可打开此视频的相册或播放器': 'No gallery or player can open this video',
    '打开已保存视频': 'Open saved video',
    '完成': 'Done',
    '再录一次': 'Record again',
    '从第': 'Continue from line',
    '继续拍同一文稿': 'Record the same script again',
    '设置暂时无法保存，将继续使用当前值':
        'Settings could not be saved. The current values will continue to be used.',
    '默认字号': 'Default text size',
    '背景透明度': 'Background opacity',
    '行距': 'Line spacing',
    '前瞻行数': 'Look-ahead lines',
    '当前及后续 {count} 句': 'Current line + next {count}',
    '当前句 + 后续 {count} 句': 'Current line + next {count}',
    '当前句 + 后续': 'Current line + next',
    '自拍镜像': 'Selfie mirroring',
    '前置预览和保存视频保持一致的镜像效果':
        'Keep the front preview and saved video mirrored consistently',
    '预览与成片均镜像': 'Preview and video mirrored',
    '预览与成片均正常': 'Preview and video natural',
    '已恢复默认设置': 'Default settings restored',
    '存储位置': 'Storage location',
    '录制完成后，视频会交给系统相册管理，优先保存到 DCIM/ScriptMirror。\n\nAndroid 8/9 如果设备不允许创建自定义目录，会自动回退到系统共享视频位置；应用不会清理其他相册内容。':
        'After recording, the system gallery manages your video and saves it to DCIM/ScriptMirror when possible.\n\nOn Android 8/9, the app falls back to the shared system video location if a custom folder is unavailable. It never removes other gallery content.',
    '语音识别': 'Speech recognition',
    '当前内置模型主要支持中文；英文脚本可以继续使用按节奏或手动提词。':
        'The bundled model currently focuses on Chinese. English scripts can still use timed or manual prompting.',
    '镜词内置 sherpa-onnx 中英文流式识别模型，识别在本机 CPU 完成，不需要网络，也不会上传录音。\n\n默认会根据文稿中的中英文字符自动选择模型，也可以在“识别语言”中手动指定。\n\n如果设备无法初始化模型，录制仍会继续，并自动切换为按节奏或手动提词。':
        'ScriptMirror bundles separate Chinese and English sherpa-onnx streaming models. Recognition runs on-device with no network and no audio upload.\n\nThe model is selected from the script by default, and you can override it in Recognition language.\n\nIf a model cannot initialize, recording continues with pacing or manual prompting.',
    '关于镜词': 'About ScriptMirror',
    '本地优先的自拍视频提词器': 'An offline-first teleprompter for selfie videos',
    '镜词是一款本地优先的自拍视频提词器：让你看着镜头，也不用忘记下一句。\n\n版本':
        'ScriptMirror is an offline-first teleprompter that keeps you looking at the lens without losing your next line.\n\nVersion',
    '文稿、录音和视频默认只保存在本机。':
        'Scripts, recordings, and videos stay on this device by default.',
    '“{title}”以及它的台词行会从本机移除。':
        '“{title}” and its lines will be removed from this device.',
    '语言': 'Language',
    '默认语言，适合国际版发布': 'Default language for the international release',
    '中文界面与本地离线识别': 'Chinese UI with offline recognition',
    '识别语言': 'Recognition language',
    '自动（按文稿）': 'Automatic (from script)',
    '中文': '中文',
    '自动按文稿选择，也可以手动指定':
        'Choose from the script automatically or specify it manually',
    '根据文稿中英文字符自动选择模型':
        'Choose a model from Chinese and English characters in the script',
    '使用中文离线模型': 'Use the Chinese offline model',
    '使用英文离线模型': 'Use the English offline model',
    '提词器偏好': 'Teleprompter preferences',
    '录制与行为': 'Recording & behavior',
    '隐私与识别': 'Privacy & recognition',
    '关于': 'About',
    '恢复默认设置': 'Restore defaults',
    '保存': 'Save',
    '编辑台词': 'Edit line',
  };
}

String tr(String source) => AppStrings.t(source);
