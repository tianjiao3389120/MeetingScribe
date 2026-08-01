# MeetingScribe

macOS 应用：把会议录像/录音变成会议纪要。语音转录与画面识别全程在本机完成，只有生成纪要这一步调用模型。

**核心差异**：不只是转录 + 摘要。屏幕共享的内容（问题清单、告警列表、架构图）会被提取、
去重、OCR，并**按时间轴与逐字稿对齐**后一起送给模型 —— 那些数字、日期、主机名是音频里
根本不存在的信息。

## 快速开始

```bash
./build.sh --install       # 构建并安装到 /Applications
```

首次打开后进设置：

1. **生成纪要后端** —— 本机 Claude Code、Anthropic API，或 DeepSeek、智谱、Kimi、通义等 OpenAI 兼容服务
2. **下载识别模型** —— 约 1.5GB，只需一次
3. **填会议背景和词表** —— 两分钟的事，纪要质量提升明显

然后把 `.mov` / `.mp4` / `.m4a` / `.mp3` 拖进窗口即可。

说话人分离设置中的人数指**实际开口人数**，不是参会名单人数。30 人在线但只有约 5 人发言，
就填 5；无法判断时选“自动判断”。自动结果不理想时可修改人数并在结果页点“重新分离”，
逐字稿会从缓存复用，不会重新转录。

## 依赖

| 组件 | 用途 | 安装 |
|---|---|---|
| whisper-cpp | 语音转录 | `brew install whisper-cpp` |
| claude | 生成纪要（仅 CLI 后端需要） | claude.com/claude-code |

音轨提取、抽帧、OCR 都用系统框架（AVFoundation / Vision），**不需要 ffmpeg**。

## 两个后端的取舍

| | 本机 Claude Code | Anthropic API | OpenAI 兼容服务 |
|---|---|---|---|
| 成本 | 零额外成本 | 按量计费 | 取决于服务商，也支持本地 Ollama |
| 架构图等图片 | 只传 OCR 文字 | 作为图片传入 | 取决于所选模型的视觉能力 |
| 配置 | 需安装 Claude Code | 填写 API key | 选择预设或填写自定义地址、模型和 key |

CLI 后端只能接收文本（`claude -p` 走 stdin），所以图表类画面会退化成 OCR 文字。
需要图片理解能力就选 API 后端。API key 存在 keychain，不落 UserDefaults。
远程 OpenAI 兼容接口必须使用 HTTPS；只有本机 localhost 服务（如 Ollama）允许 HTTP。

## 管道

```
视频 ──┬─► 音轨 (AVFoundation) ─► whisper.cpp + VAD ─► 带时间轴逐字稿 ─┐
       │                                                              ├─► 交错合并 ─► 模型 ─► Markdown
       └─► 抽帧 ─► 感知哈希去重 ─► Vision OCR ─► 带时间轴屏幕内容 ─────┘
```

几个设计选择：

- **抽帧用固定间隔 + 感知哈希过滤，而不是 ffmpeg 的场景切变检测。** 录屏里鼠标移动和
  摄像头小窗会让场景检测疯狂误触发；dHash 对这类局部变化几乎不响应，对真正的翻页却
  变化剧烈。实测去重率约 85%。候选画面使用固定容量池，长会议不会因频繁切屏无限增长内存。
- **文字型画面走 OCR 文本，图表型画面才发原图。** 仪表盘截图当图片发要上千 token，
  当文字发只要几百；而架构图靠布局传意，OCR 出来只是一堆散落标签。按识别出的文字量
  自动分流。
- **画面与逐字稿按时间轴交错**，模型才能把某句话和当时屏幕上的内容对上。

## 命令行

App 自带 headless 模式，传文件路径即可（纪要走 stdout，进度走 stderr）：

```bash
/Applications/MeetingScribe.app/Contents/MacOS/MeetingScribe 会议.mov > 纪要.md
```

只要逐字稿不要纪要：

```bash
./transcribe.sh 会议.mov      # 输出 txt + srt
```

## 词表

`设置 → 领域词表` 的内容会作为初始提示注入语音识别，能显著改善专业术语的识别准确率。

写法要点：**写成通顺的句子而非散词罗列**（whisper 对前者响应明显更好），170 字以内。
每次发现新错词就补进去。

命令行版本读 `glossary.local.txt`（不入库），没有时回落到 `glossary.txt`。

## 转录参数

关键参数在 `Pipeline/Transcriber.swift`，经真实会议实测定型：

```
--vad --vad-model ggml-silero-v5.1.2.bin -vmsd 12 -vsd 220 -mc -1
```

- **VAD 是最大的单项收益** —— 静音段不再喂给模型，幻觉循环（连续几十遍重复同一句）
  基本消失，同时耗时减半。质量与速度没有取舍。
- **不要设 `-mc 0`** —— 灭幻觉的功劳全在 VAD；关掉上下文只会让术语准确率明显下降。
- **`-ml` / `-sow` 在 VAD 模式下无效** —— 分段由语音边界决定，这两个参数被绕过。
  控制片段粒度要用 `-vmsd`（单段最长秒数）和 `-vsd`（静音切分阈值）。

## 项目结构

```
MeetingScribe/
  Models/       Transcript, ScreenCapture, Settings, SpeakerSegment, VoiceProfile
  Pipeline/     MediaExtractor, Transcriber, TextRecognizer,
                Diarizer, PromptBuilder, Analyzer, PipelineRunner
  Views/        ContentView, SettingsView, SpeakerNamingView
  Support/      Shell, Keychain, MarkdownRenderer
Tests/          转录、说话人、渲染和子进程回归测试
.github/        GitHub Actions 测试与 Release 构建
```

## 隐私

- 音频、画面、OCR 全在本机，不出网
- 可选的声纹档案属于敏感生物特征，仅保存在本机应用支持目录，文件权限限制为当前用户可读写；可在设置中查看、改名或删除
- **只有最后生成纪要这一步**会把逐字稿和选中的截图发给模型
- 如果会议内容涉及客户生产环境（IP、主机名、架构），发送前请确认合规要求

## 未做

- 录屏内置（先用系统自带）
- 跨会议台账 diff

## License

MIT
