# FFmpeg NVENC Lite · Windows x64

面向 NVIDIA 显卡的 FFmpeg 构建，提供 **HEVC / AV1 硬件编码、NVDEC 解码、CUDA 滤镜、libplacebo，以及 AAC / Opus 音频处理**。

程序采用静态链接，运行文件为单个 **`ffmpeg.exe`**，适合本地文件转码与 FFmpegFreeUI 的 NVIDIA 工作流。

[下载 Release](https://github.com/Dominic485649/ffmpeg-nvenc-lite/releases) · [Full](https://github.com/Dominic485649/ffmpeg-full) · [QSV Lite](https://github.com/Dominic485649/ffmpeg-qsv-lite)

## 主要功能

| 类别 | 提供的能力 |
|---|---|
| 视频编码 | **`hevc_nvenc`、`av1_nvenc`** |
| 原始帧输出 | `rawvideo` |
| 音频编码 | 原生 `aac`（含 NMR 参数）、`libopus` |
| 视频解码 | H.264、HEVC、AV1、VP8/VP9、MPEG-2/4、VC-1、MJPEG、ProRes、原生 AVS1 等白名单 |
| 音频解码 | AAC、MP3、AC-3/E-AC-3、TrueHD、DTS、FLAC、Opus、Vorbis、WavPack、ALAC、部分 PCM 等白名单 |
| NVIDIA 硬解 | NVDEC，结合 FFmpeg 原生解码器与 `-hwaccel cuda` 使用 |
| CUDA 滤镜 | `scale_cuda`、`overlay_cuda`、`pad_cuda`、`colorspace_cuda`、`yadif_cuda`、`bwdif_cuda`、`bilateral_cuda`、`chromakey_cuda`、`thumbnail_cuda`、`transpose_cuda`、`hwupload_cuda` |
| 图像与色彩处理 | libplacebo、Vulkan、Shaderc、SPIR-V 与硬件上下文互操作 |
| CPU 与基础滤镜 | `scale`、`crop`、`fps`、旋转、翻转、时间戳处理与硬件帧上传/下载 |
| 音频处理 | SoXR 重采样与基础音频格式、时间戳处理 |
| 常用文件 | Matroska、MP4/MOV、MPEG-TS、Ogg、WAV、FLAC，以及白名单中的裸流与原始数据 |
| 输入输出协议 | `file`、`pipe`，用于本地文件与管道工作流 |
| 元数据与比特流处理 | HEVC HDR Vivid T.35 元数据解析、上游 Dolby Vision 相关解析、`dovi_rpu` / `dovi_split` |

可通过 `-encoders`、`-decoders`、`-filters`、`-demuxers`、`-muxers` 查询程序的实际功能列表。硬件能力取决于 GPU 型号、驱动、编码格式和输入素材。

## 下载与安装

从 [Releases](https://github.com/Dominic485649/ffmpeg-nvenc-lite/releases) 选择版本并查看对应说明。

- 使用该版本提供的 `*-setup.exe` 时，可运行 7-Zip SFX 安装器，选择有写入权限的目录，并决定是否加入当前用户 PATH。
- 便携使用时，可用 7-Zip 提取 `ffmpeg.exe` 并按需手动设置 PATH。
- 运行环境为 **64 位 Windows**，CPU 须满足 **x86-64-v3（含 AVX2 等指令）**。
- 硬件处理需要支持相应功能的 NVIDIA GPU 和驱动；AV1 编码需使用具备 AV1 编码能力的型号。
- 单 EXE 采用静态链接，并通过 Windows 系统组件与 GPU / Vulkan 驱动运行时使用硬件。

设置 PATH 后重新打开终端。以下命令假定 `ffmpeg.exe` 已加入 PATH，也可使用完整路径。

```bash
ffmpeg.exe -version
```

```bash
ffmpeg.exe -encoders
```

```bash
ffmpeg.exe -filters
```

## 使用示例

以下视频命令用于普通 SDR 转码；HDR 工作流应根据素材匹配位深、色彩信息与处理链。

### HEVC 硬件编码

```bash
ffmpeg.exe -i input.mkv -map 0:v:0 -map "0:a:0?" -c:v hevc_nvenc -preset p6 -rc vbr -cq 24 -b:v 0 -c:a aac -b:a 192k output-hevc.mkv
```

### AV1 硬件编码

```bash
ffmpeg.exe -i input.mkv -map 0:v:0 -map "0:a:0?" -c:v av1_nvenc -preset p6 -rc vbr -cq 28 -b:v 0 -c:a libopus -b:a 128k output-av1.mkv
```

质量参数应按编码格式、素材和目标体积分别调节。

### NVDEC + CUDA 缩放 + HEVC 编码

```bash
ffmpeg.exe -hwaccel cuda -hwaccel_output_format cuda -i input.mkv -map 0:v:0 -map "0:a:0?" -vf "scale_cuda=w=1920:h=1080:format=nv12" -c:v hevc_nvenc -preset p6 -rc vbr -cq 24 -b:v 0 -c:a aac -b:a 192k output-1080p.mkv
```

此示例使用受支持的 NVDEC 输入，并缩放到指定尺寸。组合硬件与 CPU 滤镜时，应根据帧格式要求配置上传、下载与映射步骤。

### SoXR 重采样与 Opus 编码

```bash
ffmpeg.exe -i input.wav -vn -af "aresample=48000:resampler=soxr" -c:a libopus -b:a 128k -f ogg output.ogg
```

### 原生 AAC / NMR

```bash
ffmpeg.exe -i input.wav -vn -c:a aac -aac_coder nmr -aac_nmr_speed 0 -b:a 192k output.m4a
```

## 从源码构建

在 Linux/WSL2 中交叉编译，使用完整配套的根 `ffmpeg.sh`、`scripts/`、`shared-patches/` 和 `build-manifests/write_manifest.py`。

构建环境包括：

- 受管理的 LLVM-MinGW，以及 CMake、Ninja、Meson、NASM、Make、pkg-config、Git、Python 3。
- 可用的原生 C/C++ 编译器，用于构建 host-glslc。
- CUDA Toolkit 与 `nvcc`。

工具安装入口位于 [Full 仓库的构建说明](https://github.com/Dominic485649/ffmpeg-full#从源码构建)。在该仓库通过 `tool` 准备配套工具后，回到 NVENC Lite 仓库执行以下命令。

更新源码：

```bash
./ffmpeg.sh update
```

使用现有源码构建：

```bash
./ffmpeg.sh build
```

不带参数或使用 `all` 会依次更新源码并构建。构建期间会核验受管理工具链，工具链版本查询与 Shaderc 固定依赖准备可能需要联网。

| 用途 | 默认路径 |
|---|---|
| 依赖源码 | `sources/` |
| 依赖安装前缀 | `bin_nvenc/` |
| 构建与内容缓存 | `build_nvenc/` |
| 最终程序 | **`nvenc/ffmpeg.exe`** |

目标外部依赖为 nv-codec-headers、Opus、SoXR、Shaderc、Vulkan-Headers 和 libplacebo，另有原生 host-glslc 构建阶段。阶段缓存按源码、配置、工具链、依赖和产物内容核验；构建清单记录实际提交、参数与程序身份。FFmpeg 默认跟踪 `master`。

## FFmpegFreeUI 预设

若 Release 附带 JSON，可作为 [FFmpegFreeUI](https://github.com/Lake1059/FFmpegFreeUI) v6 用户预设放入 `Preset_v6\User`。预设作为可选独立附件提供；使用前请确认编码器、滤镜与本机路径匹配。

## 实测与许可证

2026-11-03 本地产物已通过隔离运行与导入依赖检查，并在 RTX 4060 Laptop 上完成 CUDA 缩放、HEVC/AV1 NVENC 编码和 libplacebo/Vulkan 处理。SoXR、Opus 编码/原生解码与 AAC 编码通过；相同输入的二次构建为 **8/8 唯一阶段内容缓存复用**。

各版本的程序身份、文件体积与验证信息见对应 Release。

自有脚本与文档采用 [MIT License](https://github.com/Dominic485649/ffmpeg-nvenc-lite/blob/main/LICENSE)。本配置的 FFmpeg 标识为 **`nonfree and unredistributable`**；FFmpeg、外部库、驱动与安装器组件适用各自许可证，使用与分发须满足相应许可要求。
