# MeetingScribe

macOS 应用：把会议录像/录音变成会议纪要。语音转录与画面识别全程在本机完成，只有生成纪要这一步调用模型。

**核心差异**：不只是转录 + 摘要。屏幕共享的内容（问题清单、告警列表、架构图）会被提取、
去重、OCR，并**按时间轴与逐字稿对齐**后一起送给模型 —— 那些数字、日期、主机名是音频里
根本不存在的信息。

## 快速开始

要求：macOS 14 或更高版本，当前构建脚本面向 Apple Silicon。

```bash
./build.sh --install       # 构建并安装到 /Applications
```

首次打开后进设置：

1. **生成纪要后端** —— 本机 Claude Code、Anthropic API，或 DeepSeek、智谱、Kimi、通义等 OpenAI 兼容服务
2. **下载识别模型** —— 约 1.5GB，只需一次
3. **填会议背景和词表** —— 两分钟的事，纪要质量提升明显
4. **可选：安装说话人分离** —— 约 100MB 运行环境与 28MB 模型

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

## 三种后端的取舍

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

模型优先输出结构化 JSON（问题、需求、待办、责任人、期限和证据时间码），应用在本地校验后
渲染为 Markdown。若某个兼容模型没有返回合法 JSON，会自动保留其原始输出，不让本次生成失败。
保存结果时会同时写出 `纪要.md`、`纪要.json` 和 `逐字稿.txt`。

## 历史会议

每次成功生成纪要后，应用会自动在本机保存一个历史版本。工具栏的“历史会议”支持：

- 按标题、纪要内容或说话人搜索
- 查看过去的 Markdown 纪要
- 打开仍然存在的原始媒体，或重新处理
- 导出纪要、结构化 JSON 和逐字稿
- 删除历史副本（不影响原始媒体和此前导出的文件）

历史库不会复制原始媒体或保存屏幕截图；同一会议重新生成会保留为独立版本。源文件被移动后，
已有纪要仍可正常查看。数据位于：

```text
~/Library/Application Support/MeetingScribe/Meetings/
```

几个设计选择：

- **抽帧用固定间隔 + 感知哈希过滤，而不是 ffmpeg 的场景切变检测。** 录屏里鼠标移动和
  摄像头小窗会让场景检测疯狂误触发；dHash 对这类局部变化几乎不响应，对真正的翻页却
  变化剧烈。实测去重率约 85%。候选画面使用固定容量池，长会议不会因频繁切屏无限增长内存。
- **文字型画面走 OCR 文本，图表型画面才发原图。** 仪表盘截图当图片发要上千 token，
  当文字发只要几百；而架构图靠布局传意，OCR 出来只是一堆散落标签。按识别出的文字量
  自动分流。
- **画面与逐字稿按时间轴交错**，模型才能把某句话和当时屏幕上的内容对上。

## 说话人分离与声纹

说话人分离默认关闭，因为会增加处理时间。开启后，应用会在本机使用 sherpa-onnx、
pyannote 分段模型和 3D-Speaker CAMPPlus 声纹模型，把发言归入“说话人 A/B/C”。

首次登记姓名：

1. 在设置中安装并开启“为纪要区分说话人”。
2. “实际发言人数”知道就填，不知道选“自动判断”。
3. 处理会议后，点击结果页的“X 位说话人”。
4. 试听代表片段、填写姓名，点击“保存并重新生成纪要”。

姓名会立即用于当前纪要，后续会议会自动尝试声纹匹配。可在
`设置 → 说话人分离 → 已登记声纹 → 管理` 中改名或删除。如果自动聚类数量不合理，
修改实际发言人数后点结果页“重新分离”；转录会从缓存复用。

## 缓存与重试

- 转录和说话人分离分别缓存，重复处理时无需重算昂贵阶段。
- 语言、词表、模型、关键参数或缓存 schema 改变时，缓存 key 会自动变化。
- 模型调用失败后可只重试生成纪要，逐字稿和画面仍会保留。
- 设置中的“清除缓存”同时清理转录和说话人缓存，不会删除声纹档案。

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
  Models/       Transcript, ScreenCapture, Settings, SpeakerSegment,
                VoiceProfile, StructuredMinutes, MeetingRecord
  Pipeline/     MediaExtractor, Transcriber, TextRecognizer,
                Diarizer, PromptBuilder, Analyzer, PipelineRunner
  Views/        ContentView, SettingsView, SpeakerNamingView, MeetingHistoryView
  Support/      Shell, Keychain, MarkdownRenderer, StructuredMinutesRenderer,
                MeetingHistoryStore
Tests/          转录、说话人、渲染和子进程回归测试
.github/        GitHub Actions 测试与 Release 构建
```

## 开发与验证

```bash
swift test                 # 单元与回归测试
swift build -c release     # Release 编译
./build.sh                 # 打包到 build/MeetingScribe.app
./build.sh --install       # 打包并安装到 /Applications
```

CI 会在每次 push 和 pull request 上运行测试及 Release 构建。

## 隐私

- 音频、画面、OCR 全在本机，不出网
- 可选的声纹档案属于敏感生物特征，仅保存在本机应用支持目录，文件权限限制为当前用户可读写；可在设置中查看、改名或删除
- **只有最后生成纪要这一步**会把逐字稿和选中的截图发给模型
- API key 保存在 macOS Keychain；远程自定义接口必须使用 HTTPS
- 如果会议内容涉及客户生产环境（IP、主机名、架构），发送前请确认合规要求

## 未做

- 录屏内置（先用系统自带）
- 跨会议台账 diff

## License

MIT
