# ffmpeg-nvenc-lite

一个面向 Windows x64 的 NVIDIA GPU 专用 FFmpeg 精简构建脚本。

本项目目标不是构建“全功能 FFmpeg”，而是生成一个路径清晰、组件白名单化、适合日常 GPU 转码的 `ffmpeg.exe`：

> 常见格式输入 → NVDEC / libdav1d / 软件解码 → CUDA 滤镜处理 → NVENC 输出 HEVC / AV1

适合只需要 NVIDIA 硬件编码、CUDA 缩放 / 反交错 / 基础降噪、不需要完整 FFmpeg 生态的场景。

---

## 特性概览

* Windows x64 目标产物：`ffmpeg.exe`
* Linux / WSL2 → MinGW-w64 交叉编译
* 默认启用 CUDA / NVENC / NVDEC
* 默认使用 CUDA 13.3 工具链路径
* 静态链接 FFmpeg 与依赖库
* 白名单化 encoder / decoder / muxer / demuxer / filter
* 默认禁用 `ffprobe`、`ffplay`、文档、调试信息
* 默认启用 LTO、section GC、x86-64-v3 CPU baseline
* 构建完成后复制 `ffmpeg.exe` 到当前 `nvenc` 目录
* 如果检测到 `/mnt/d`，额外复制到 `/mnt/d/ffmpeg.exe`

---

## 重要说明

本项目是“专用转码构建”，不是通用 FFmpeg 发行版。

它默认不包含：

* x264 / x265 / SVT-AV1 等软件视频编码器
* libfdk-aac / AudioToolbox AAC
* libnpp 与所有 `*_npp` 滤镜
* 字幕渲染栈
* 质量评测滤镜
* 全量图片编码能力
* 全量历史 / 冷门格式解码器
* `ffprobe`
* `ffplay`

如果你需要完整 FFmpeg 功能，请使用全功能构建；如果你需要 Intel QSV 专用版本，请使用对应的 QSV Lite 项目。

---

## 当前构建定位

| 项目               | 配置                                                          |
| ---------------- | ----------------------------------------------------------- |
| Target           | Windows x86_64                                              |
| Toolchain        | Linux / WSL2 → MinGW-w64                                    |
| FFmpeg source    | 默认跟踪 `FFMPEG_REF=master`，可自行指定 tag / branch / commit        |
| CUDA             | 默认启用                                                        |
| CUDA redist 默认路径 | `toolchains/cuda-redist-13.3.0/install/linux`               |
| GPU fatbin 架构    | `sm_75`, `sm_80`, `sm_86`, `sm_89`, `sm_120`, `compute_120` |
| CPU baseline     | `x86-64-v3`                                                 |
| Link             | Static                                                      |
| License state    | `nonfree and unredistributable`                             |
| ffmpeg           | 启用                                                          |
| ffprobe          | 默认禁用                                                        |
| ffplay           | 默认禁用                                                        |

如果要固定 FFmpeg 版本，请显式指定：

```bash
FFMPEG_REF=n8.1.2 ./ffmpeg.sh update
./ffmpeg.sh build
```

或者指定某个 commit：

```bash
FFMPEG_REF=<commit-hash> ./ffmpeg.sh update
./ffmpeg.sh build
```

---

## 编码器白名单

本构建只保留以下 encoder：

| Encoder           | 类型      | 说明                                |
| ----------------- | ------- | --------------------------------- |
| `hevc_nvenc`      | 视频      | H.265 / HEVC NVENC 硬件编码           |
| `av1_nvenc`       | 视频      | AV1 NVENC 硬件编码                    |
| `aac`             | 音频      | FFmpeg 内置 AAC 编码器                 |

说明：

* 软件视频编码器默认全部禁用。
* `libfdk_aac` 不启用。
* `aac_at` 不启用。
* `libsvtav1` / `libx264` / `libx265` 不启用。
* 如果你的 GPU 不支持 AV1 NVENC，请使用 `hevc_nvenc`。

---

## 解码器白名单

### 视频解码器

保留常见视频输入与中间格式：

```text
h264, hevc, av1,
vp9, vp8,
mpeg2video, mpeg4, msmpeg4v3,
vc1, wmv3,
prores, dnxhd, cfhd,
mjpeg, jpeg2000, png, webp, bmp, tiff, gif,
rawvideo, wrapped_avframe,
libdav1d
```

明确排除部分老旧 / 非目标解码器：

```text
indeo2, indeo3, indeo4, indeo5,
cinepak, rv10, rv20,
h261, h263, h263i,
flv, svq1, svq3,
binkvideo, cineform
```

### 音频解码器

```text
aac, mp3,
ac3, eac3, truehd, dca,
flac, opus, vorbis,
wavpack, alac,
pcm_s16le, pcm_s24le, pcm_s32le,
pcm_f32le, pcm_f64le
```

### 字幕

本构建不保留字幕解码、字幕编码、字幕烧录和字幕渲染滤镜。

如果只是保留字幕 packet，可尝试：

```powershell
.\ffmpeg.exe -i "input.mkv" `
  -map 0:v -map 0:a? -map 0:s? `
  -c:v av1_nvenc -preset p7 -cq:v 34 `
  -c:a copy `
  -c:s copy `
  "output.mkv"
```

字幕 copy 是否成功取决于输入 / 输出容器是否支持对应字幕流。需要保留字幕时，推荐优先输出 MKV。

---

## 硬件加速器白名单

```text
h264_nvdec,
hevc_nvdec,
av1_nvdec,
vp8_nvdec,
vp9_nvdec,
mpeg2_nvdec,
vc1_nvdec,
mjpeg_nvdec
```

---

## CUDA 滤镜白名单

```text
scale_cuda
overlay_cuda
pad_cuda
colorspace_cuda
yadif_cuda
bwdif_cuda
bilateral_cuda
chromakey_cuda
thumbnail_cuda
hwupload_cuda
hwdownload
hwmap
```

用途说明：

| Filter            | 说明                  |
| ----------------- | ------------------- |
| `scale_cuda`      | CUDA 缩放             |
| `overlay_cuda`    | CUDA 叠加             |
| `pad_cuda`        | CUDA 填充 / 加边框       |
| `colorspace_cuda` | CUDA 色彩空间 / 色彩范围处理  |
| `yadif_cuda`      | CUDA YADIF 反交错      |
| `bwdif_cuda`      | CUDA BWDIF 反交错      |
| `bilateral_cuda`  | CUDA 双边滤波 / 基础降噪    |
| `chromakey_cuda`  | CUDA 色度键            |
| `thumbnail_cuda`  | CUDA 缩略图选帧          |
| `hwupload_cuda`   | 上传 CPU frame 到 CUDA |
| `hwdownload`      | 下载硬件帧到 CPU          |
| `hwmap`           | 硬件帧映射               |

---

## 基础软件滤镜白名单

除 CUDA 滤镜外，仅保留少量必要基础滤镜：

```text
buffer, buffersink,
abuffer, abuffersink,
format, aformat,
null, anull,
fps,
trim, atrim,
setpts, asetpts,
settb, asettb,
setparams, setsar,
aresample,
transpose, crop, hflip, vflip, rotate
```

这些 CPU 滤镜主要用于基础兼容、简单几何处理和滤镜链衔接。
如果你追求更极限的 GPU-only 构建，可以继续从脚本白名单中移除 CPU 几何滤镜。

---

## 容器 / 封装支持

### Demuxer

```text
matroska,
mov,
mpegts,
h264,
hevc,
av1,
rawvideo,
image2,
concat,
aac,
mp3,
flac,
ogg,
wav,
vapoursynth
```

### Muxer

```text
matroska,
mp4,
mpegts,
null,
rawvideo,
image2,
adts,
flac,
ogg,
wav,
mov,
ipod
```

### Parser

```text
h264,
hevc,
av1,
aac,
mp3,
opus,
vorbis
```

### Bitstream filter

```text
h264_mp4toannexb
hevc_mp4toannexb
av1_metadata
h264_metadata
hevc_metadata
aac_adtstoasc
extract_extradata
```

---

## 依赖源码

脚本会克隆 / 更新以下上游源码：

```text
FFmpeg/FFmpeg
FFmpeg/nv-codec-headers
sekrit-twc/zimg
videolan/dav1d
vapoursynth/vapoursynth
```

构建阶段顺序：

```text
nv-codec-headers
zimg
dav1d
vapoursynth
ffmpeg
```

---

## 构建环境

推荐环境：

* Windows 10 / 11 x64
* WSL2 Ubuntu 22.04 / 24.04
* NVIDIA 显卡与较新的 NVIDIA 驱动
* MinGW-w64
* CUDA Toolkit for WSL
* 支持 x86-64-v3 的 CPU

脚本的 `tool` 阶段会安装常用构建依赖：

```text
build-essential, autoconf, automake, libtool, make,
cmake, meson, ninja-build,
pkg-config, nasm, yasm,
git, curl, ca-certificates,
python3, gettext, gperf,
mingw-w64, mingw-w64-tools,
binutils-mingw-w64-x86-64,
gcc/g++ mingw-w64 posix toolchain
```

---

## 使用方法

脚本要求在 `nvenc` 目录中运行。
如果脚本不在 `nvenc` 目录下，会自动复制自身到 `nvenc/ffmpeg.sh` 并提示重新运行。

推荐目录结构：

```text
workspace/
├─ nvenc/
│  └─ ffmpeg.sh
├─ ffmpeg-source/
├─ nv-codec-headers/
├─ zimg/
├─ dav1d/
├─ vapoursynth/
├─ build_nvenc/
└─ bin_nvenc/
```

进入脚本目录：

```bash
cd /path/to/workspace/nvenc
chmod +x ./ffmpeg.sh
```

完整构建：

```bash
./ffmpeg.sh all
```

等价于：

```bash
./ffmpeg.sh tool
./ffmpeg.sh update
./ffmpeg.sh build
```

仅安装工具链：

```bash
./ffmpeg.sh tool
```

仅更新源码：

```bash
./ffmpeg.sh update
```

仅构建：

```bash
./ffmpeg.sh build
```

从指定阶段继续：

```bash
./ffmpeg.sh build ffmpeg
./ffmpeg.sh build zimg
./ffmpeg.sh build dav1d
./ffmpeg.sh build vapoursynth
```

只构建指定阶段：

```bash
./ffmpeg.sh build --only zimg dav1d
./ffmpeg.sh build --only ffmpeg
```

清理：

```bash
./ffmpeg.sh clean
```

---

## 常用环境变量

### 指定 FFmpeg 版本

```bash
FFMPEG_REF=n8.1.2 ./ffmpeg.sh update
./ffmpeg.sh build
```

### 禁用 CUDA

```bash
CUDA_ENABLE=0 ./ffmpeg.sh build
```

### 修改 CPU baseline

默认：

```bash
CPU_FLAGS="-march=x86-64-v3 -mtune=generic"
```

如果目标机器较旧，可改为：

```bash
CPU_FLAGS="-march=x86-64-v2 -mtune=generic" ./ffmpeg.sh build
```

### 修改并行数

```bash
JOBS=16 FFMPEG_JOBS=16 ./ffmpeg.sh build
```

### 指定 CUDA_HOME

```bash
CUDA_HOME=/usr/local/cuda ./ffmpeg.sh build
```

### 指定 CUDA redist 路径

```bash
CUDA_REDIST_ROOT=/path/to/cuda-redist/install/linux ./ffmpeg.sh build
```

---

## 示例命令

### HEVC / AV1 输入 → AV1 NVENC 输出

```powershell
.\ffmpeg.exe -hide_banner -y `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "scale_cuda=1920:1080:interp_algo=lanczos" `
  -c:v av1_nvenc -preset p7 -cq:v 34 `
  -c:a aac -b:a 320k `
  "output.mkv"
```

### HEVC NVENC 输出

```powershell
.\ffmpeg.exe -hide_banner -y `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "scale_cuda=1920:1080:interp_algo=lanczos" `
  -c:v hevc_nvenc -preset p7 -cq:v 28 `
  -c:a copy `
  "output.mkv"
```

### AV1 输入强制使用 libdav1d 解码

```powershell
.\ffmpeg.exe -hide_banner -y `
  -c:v libdav1d `
  -i "input_av1.mkv" `
  -vf "format=yuv420p10le,hwupload_cuda,scale_cuda=1920:1080:interp_algo=lanczos" `
  -c:v av1_nvenc -preset p7 -cq:v 34 `
  -c:a copy `
  "output.mkv"
```

### CUDA 双边滤波 / 基础降噪

```powershell
.\ffmpeg.exe -hide_banner -y `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "bilateral_cuda=sigmaS=3.0:sigmaR=50.0:window_size=9" `
  -c:v hevc_nvenc -preset p7 -cq:v 28 `
  -c:a copy `
  "output.mkv"
```

### 只测试解码 / 滤镜链

```powershell
.\ffmpeg.exe -hide_banner -benchmark `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "scale_cuda=1920:1080" `
  -f null -
```

---

## 验证构建结果

列出组件：

```powershell
.\ffmpeg.exe -hide_banner -encoders
.\ffmpeg.exe -hide_banner -decoders
.\ffmpeg.exe -hide_banner -filters
.\ffmpeg.exe -hide_banner -hwaccels
.\ffmpeg.exe -hide_banner -demuxers
.\ffmpeg.exe -hide_banner -muxers
.\ffmpeg.exe -hide_banner -bsfs
```

关键检查：

```powershell
.\ffmpeg.exe -hide_banner -encoders | findstr /i "hevc_nvenc av1_nvenc aac wrapped_avframe"
.\ffmpeg.exe -hide_banner -filters  | findstr /i "scale_cuda bilateral_cuda bwdif_cuda yadif_cuda"
.\ffmpeg.exe -hide_banner -hwaccels | findstr /i "nvdec cuda"
```

这些内容不应出现：

```powershell
.\ffmpeg.exe -hide_banner -encoders | findstr /i "libfdk libsvt libx264 libx265"
.\ffmpeg.exe -hide_banner -filters  | findstr /i "_npp libvmaf psnr ssim xpsnr bm3d subtitles drawtext"
```

---

## 输出位置

构建成功后，脚本会生成：

```text
bin_nvenc/bin/ffmpeg.exe
nvenc/ffmpeg.exe
```

如果 WSL 中存在 `/mnt/d`，还会复制到：

```text
/mnt/d/ffmpeg.exe
```

也就是 Windows 下的：

```text
D:\ffmpeg.exe
```

---

## 适用场景

适合：

* NVIDIA 显卡用户
* HEVC / AV1 NVENC 转码
* CUDA 缩放
* CUDA 反交错
* CUDA 基础降噪
* GUI / 脚本内部调用的轻量专用 `ffmpeg.exe`
* 不需要完整 FFmpeg 生态的专用压制流程

不适合：

* 字幕烧录
* 质量评测
* 全格式考古解码
* 全量图片编码
* 软件编码器压制
* 完整 FFmpeg CLI 学习环境
* 依赖 `ffprobe` 的工具链
* 依赖 `libfdk_aac` / `aac_at` 的音频压制流程
* 需要 NPP 滤镜的处理流程

---

## License / Distribution Notice

本脚本启用了 `--enable-gpl` 与 `--enable-nonfree`，并在构建校验中要求 FFmpeg license 状态为：

```text
nonfree and unredistributable
```

因此，使用本脚本生成的二进制文件不应被描述为可自由再分发的通用 FFmpeg 发行版。

如需发布可再分发版本，请重新审查 FFmpeg configure 选项、第三方库许可、NVIDIA 相关组件许可，并确保生成产物满足对应分发条件。
