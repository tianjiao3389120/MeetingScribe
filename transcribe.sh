#!/usr/bin/env bash
# 会议音视频转录 —— 本地离线，支持 VAD 降幻觉 + 领域词表纠术语
#
#   ./transcribe.sh 会议.mov
#   ./transcribe.sh 会议.mp3 -g 我的词表.txt
#   ./transcribe.sh 会议.mov -o ~/Desktop/输出目录
#
# 输出：<名字>.txt（纯文本）、<名字>.srt（带时间轴），默认与源文件同目录。

set -euo pipefail

MODEL_DIR="${WHISPER_MODEL_DIR:-$HOME/.cache/whisper.cpp}"
MODEL="${WHISPER_MODEL:-$MODEL_DIR/ggml-large-v3-turbo.bin}"
VAD_MODEL="$MODEL_DIR/ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 优先用本地词表（含真实项目术语，不入库），没有再用仓库里的通用示例
if [ -f "$SCRIPT_DIR/glossary.local.txt" ]; then
    GLOSSARY="$SCRIPT_DIR/glossary.local.txt"
else
    GLOSSARY="$SCRIPT_DIR/glossary.txt"
fi
LANG="zh"
OUTDIR=""
THREADS="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.logicalcpu)"

die() { printf '\033[31m错误：\033[0m%s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m▸\033[0m %s\n' "$*"; }

usage() {
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[ $# -ge 1 ] || usage 1
INPUT="$1"; shift
[ "$INPUT" = "-h" ] || [ "$INPUT" = "--help" ] && usage
[ -f "$INPUT" ] || die "找不到文件：$INPUT"

while [ $# -gt 0 ]; do
    case "$1" in
        -g|--glossary) GLOSSARY="$2"; shift 2 ;;
        -o|--outdir)   OUTDIR="$2";   shift 2 ;;
        -l|--lang)     LANG="$2";     shift 2 ;;
        -h|--help)     usage ;;
        *) die "未知参数：$1" ;;
    esac
done

for tool in ffmpeg ffprobe whisper-cli; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool。安装：brew install ffmpeg whisper-cpp"
done

# 模型按需下载，只下一次
mkdir -p "$MODEL_DIR"
[ -f "$MODEL" ]     || { info "下载识别模型（约 1.5GB，仅首次）…"; curl -L --progress-bar -o "$MODEL" "$MODEL_URL"; }
[ -f "$VAD_MODEL" ] || { info "下载 VAD 模型…"; curl -sL -o "$VAD_MODEL" "$VAD_URL"; }

BASE="$(basename "${INPUT%.*}")"
DEST="${OUTDIR:-$(cd "$(dirname "$INPUT")" && pwd)}"
mkdir -p "$DEST"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | cut -d. -f1)"
info "输入：$(basename "$INPUT")  时长 $((DURATION/60))分$((DURATION%60))秒"

# 视频/音频统一转成 whisper 要的 16kHz 单声道 wav
info "提取音轨…"
ffmpeg -v error -i "$INPUT" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/audio.wav" -y

# 词表作为 initial prompt 注入，纠正领域术语的识别
PROMPT_ARGS=()
if [ -f "$GLOSSARY" ]; then
    PROMPT="$(grep -v '^\s*#' "$GLOSSARY" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$PROMPT" ]; then
        # whisper 的 initial prompt 上限约 224 token，中文按 1.3 token/字保守截断
        PROMPT="$(printf '%s' "$PROMPT" | cut -c1-170)"
        PROMPT_ARGS=(--prompt "$PROMPT" --carry-initial-prompt)
        info "词表：$(basename "$GLOSSARY")（${#PROMPT} 字）"
    fi
fi

info "转录中（$THREADS 线程，Metal 加速）…"
# 参数经 41 分钟真实会议实测定型（见 TUNING.md）：
#   --vad          静音段不再喂给模型，幻觉循环 88 段 → 0，且更快
#   -vmsd 12       单段最长 12 秒，避免出现 180 字的超长片段（影响时间轴对齐）
#   -vsd 220       静音 220ms 即切分
#   -mc -1         保留完整上下文。曾试过 -mc 0，术语准确率从 97% 掉到 82%
whisper-cli \
    -m "$MODEL" -l "$LANG" -t "$THREADS" \
    --vad --vad-model "$VAD_MODEL" -vmsd 12 -vsd 220 \
    -mc -1 \
    "${PROMPT_ARGS[@]}" \
    -of "$WORK/$BASE" -otxt -osrt \
    "$WORK/audio.wav" 2>&1 | grep -vE '^(whisper_|ggml_|main:|system_info|read_audio|$)' || true

[ -f "$WORK/$BASE.txt" ] || die "转录失败，没有生成输出"

mv "$WORK/$BASE.txt" "$WORK/$BASE.srt" "$DEST/"
info "完成 → $DEST/$BASE.txt"
info "      $DEST/$BASE.srt"
