# ffmpeg-nvenc-lite

基于 FFmpeg n8.1.2 的 NVIDIA GPU 专用转码构建，面向 Windows 用户。

本项目专注于：

> 现代格式解码 → CUDA 滤镜处理 → NVENC 编码输出 HEVC / AV1

目标不是做“全功能 FFmpeg”，而是构建一个体积更小、组件更少、路径更明确的 GPU 转码版 `ffmpeg.exe`。

### 如果需要intel的qsv硬编解码器支持，请看[ffmpeg-qsv-lite](https://github.com/Dominic485649/ffmpeg-qsv-lite)

---

## 设计目标

* 只保留必要编码器，禁用 x264 / x265 / SVT-AV1 等软件编码器
* 使用 NVENC 输出 HEVC / AV1
* 使用 CUDA / NVDEC / libdav1d 覆盖常见转码输入
* 使用 CUDA 滤镜完成缩放、色彩、反交错、叠加、填充、基础降噪
* 剔除 NPP、字幕渲染栈、图片编码器、质量评测滤镜和大量非必要组件
* 尽量减少误调用 CPU 滤镜导致的性能回退

---

## 版本信息

| 项目           | 版本 / 配置                         |
| ------------ | ------------------------------- |
| FFmpeg       | n8.1.2                          |
| Compiler     | GCC 13-posix                    |
| Target       | Windows x86_64                  |
| Toolchain    | Linux / WSL2 → MinGW-w64        |
| CUDA         | CUDA 13.3.0                     |
| GPU 架构       | SM 7.5 / 8.0 / 8.6 / 8.9 / 12.0 |
| CPU baseline | x86-64-v3                       |
| Link         | Static build                    |
| ffprobe      | 默认不构建                           |

---

## 编码器

| 编码器               | 类型      | 说明                                     |
| ----------------- | ------- | -------------------------------------- |
| `hevc_nvenc`      | 视频      | H.265 / HEVC NVENC 硬件编码                |
| `av1_nvenc`       | 视频      | AV1 NVENC 硬件编码                         |
| `libfdk_aac`      | 音频      | Fraunhofer FDK AAC 高质量编码               |
| `aac_at`          | 音频      | Apple AudioToolbox AAC 编码              |
| `wrapped_avframe` | 内部 / 测试 | 用于 `-f null -`、滤镜 smoke test、benchmark |

> 所有通用软件视频编码器均已禁用，视频编码路径只保留 NVENC。

注意：`aac_at` 依赖 AudioToolboxWrapper。部分环境可能仍需要可加载的 Apple CoreAudioToolbox 运行时；如果只追求稳定 AAC 输出，推荐使用 `libfdk_aac`。

---

## 解码器

本构建使用 decoder 白名单，而不是 FFmpeg 默认全量 decoder。

### 视频 decoder

| 类型      | 保留内容                                                     |
| ------- | -------------------------------------------------------- |
| 现代主流    | `h264`, `hevc`, `av1`, `libdav1d`, `vp9`, `vp8`          |
| 常见兼容    | `mpeg2video`, `mpeg4`, `msmpeg4v3`, `vc1`, `wmv3`        |
| 中间格式    | `prores`, `dnxhd`, `cfhd`                                |
| 图像输入    | `mjpeg`, `jpeg2000`, `png`, `webp`, `bmp`, `tiff`, `gif` |
| 原始 / 内部 | `rawvideo`, `wrapped_avframe`                            |

`libdav1d` 用于可靠的 AV1 软件解码。对于 AV1 输入文件，如果 NVDEC 或 FFmpeg native AV1 路径不稳定，可以显式使用：

```powershell
.\ffmpeg.exe -c:v libdav1d -i input_av1.mkv ...
```

### 音频 decoder

保留常见转码和封装所需音频 decoder：

```text
aac, mp3, ac3, eac3, truehd, dca, flac, opus, vorbis,
wavpack, alac,
pcm_s16le, pcm_s24le, pcm_s32le, pcm_f32le, pcm_f64le
```

### 字幕

本构建不保留字幕解码、字幕编码、字幕烧录和字幕渲染滤镜。

目标仅保留容器层面的 `-c:s copy` 能力。字幕 copy 是否成功取决于输入 / 输出容器是否支持该字幕 packet。推荐需要保留字幕时输出 MKV。

---

## CUDA 滤镜

| 滤镜                | 功能                 |
| ----------------- | ------------------ |
| `scale_cuda`      | GPU 缩放             |
| `bilateral_cuda`  | GPU 双边滤波 / 基础降噪    |
| `bwdif_cuda`      | GPU BWDIF 反交错      |
| `yadif_cuda`      | GPU YADIF 反交错      |
| `chromakey_cuda`  | GPU 色度键            |
| `colorspace_cuda` | GPU 色彩范围转换         |
| `overlay_cuda`    | GPU 视频叠加           |
| `pad_cuda`        | GPU 填充 / 加边框       |
| `thumbnail_cuda`  | GPU 缩略图选帧          |
| `hwupload_cuda`   | CPU frame 上传到 CUDA |
| `hwdownload`      | CUDA frame 下载到 CPU |
| `hwmap`           | 硬件帧映射              |

---

## 基础软件滤镜

由于本构建使用 `--disable-filters`，仅保留必要基础滤镜：

```text
format, aformat,
null, anull,
fps,
trim, atrim,
setpts, asetpts,
settb, asettb,
setparams, setsar,
aresample
```

同时保留少量 CPU 几何滤镜作为实用回退：

```text
crop, hflip, vflip, rotate, transpose
```

这些滤镜不是 CUDA 滤镜。如果你追求更极限的 GPU-only 构建，可以在脚本中继续移除它们。

---

## 已移除 / 不包含

### 不包含 NPP

本构建不启用 `libnpp`，也不包含任何 `*_npp` 滤镜：

```text
scale_npp, scale2ref_npp, sharpen_npp, transpose_npp
```

### 不包含质量评测滤镜

本构建默认不包含：

```text
libvmaf, libvmaf_cuda, psnr, ssim, xpsnr
```

原因是 FFmpegFreeUI 等 GUI 的质量评测路径通常还依赖 `ffprobe`、`scale`、`wrapped_avframe`、VMAF 模型、双输入滤镜链等大量组件。为了保持转码构建精简，本项目不默认内置评测功能。

如需质量评测，建议单独维护 `ffmpeg-eval.exe`。

### 不包含字幕渲染栈

默认禁用：

```text
libass, freetype, fontconfig, fribidi, harfbuzz
subtitles, ass, drawtext, textsub
```

### 不包含 FFmpeg 原生 BM3D

当前 FFmpeg 构建不包含：

```text
bm3d
bm3d_cuda
```

FFmpeg 官方有 CPU `bm3d` 滤镜，但本构建未启用。CUDA BM3D 推荐走 VapourSynth-BM3DCUDA，而不是期待 `ffmpeg.exe -vf bm3d_cuda`。

---

## 容器与封装

### Demuxer

保留常见输入：

```text
matroska, mov, mpegts,
h264, hevc, av1,
rawvideo, image2, concat,
aac, mp3, flac, ogg, wav
```

### Muxer

保留常见输出：

```text
matroska, mp4, mpegts,
null, rawvideo, image2,
adts, flac, ogg, wav
```

### Bitstream filters

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

## 示例命令

### HEVC / AV1 输入 → AV1 NVENC 输出

```powershell
.\ffmpeg.exe -hide_banner -y `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "scale_cuda=1920:1080:interp_algo=lanczos" `
  -c:v av1_nvenc -preset p7 -cq 34 `
  -c:a libfdk_aac -vbr 5 `
  "output.mkv"
```

### AV1 输入强制使用 libdav1d 软件解码

```powershell
.\ffmpeg.exe -hide_banner -y `
  -c:v libdav1d `
  -i "input_av1.mkv" `
  -vf "format=yuv420p10le,hwupload_cuda,scale_cuda=1920:1080:interp_algo=lanczos" `
  -c:v av1_nvenc -preset p7 -cq 34 `
  -c:a copy `
  "output.mkv"
```

### CUDA 双边降噪

```powershell
.\ffmpeg.exe -hide_banner -y `
  -hwaccel cuda -hwaccel_output_format cuda `
  -i "input.mkv" `
  -vf "bilateral_cuda=sigmaS=3.0:sigmaR=50.0:window_size=9" `
  -c:v hevc_nvenc -preset p7 -cq 28 `
  -c:a copy `
  "output.mkv"
```

### 保留字幕 packet copy

```powershell
.\ffmpeg.exe -hide_banner -y `
  -i "input.mkv" `
  -map 0:v -map 0:a? -map 0:s? `
  -c:v av1_nvenc -preset p7 -cq 34 `
  -c:a copy `
  -c:s copy `
  "output.mkv"
```

---

## 验证命令

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
.\ffmpeg.exe -hide_banner -encoders | findstr /i "nvenc libfdk_aac aac_at wrapped_avframe"
.\ffmpeg.exe -hide_banner -decoders | findstr /i "libdav1d av1 h264 hevc vp9"
.\ffmpeg.exe -hide_banner -filters  | findstr /i "cuda bilateral scale_cuda"
.\ffmpeg.exe -hide_banner -filters  | findstr /i "_npp libvmaf psnr ssim xpsnr bm3d subtitles drawtext"
```

最后一条在本构建中应无输出，或只出现非目标误匹配项。

---

## 系统要求

| 项目        | 要求                             |
| --------- | ------------------------------ |
| OS        | Windows 10 / 11 x64            |
| GPU       | NVIDIA GTX 16xx / RTX 20xx 及以上 |
| AV1 NVENC | RTX 40xx 及以上推荐                 |
| CPU       | 支持 x86-64-v3 的处理器              |
| Driver    | 建议使用较新的 NVIDIA 驱动              |

---

## 适用场景

适合：

* NVIDIA 显卡用户
* HEVC / AV1 硬件编码
* CUDA 缩放、色彩、反交错、基础降噪
* 精简单用途压制工具
* 不需要完整 FFmpeg 生态的专用构建

不适合：

* 字幕烧录
* 质量评测
* 全格式考古解码
* 图片编码
* 软件编码器压制
* FFmpegFreeUI 全功能模式
* BM3D / AI 降噪一体化处理
