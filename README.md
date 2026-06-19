# ffmpeg-nvenc-lite

基于 FFmpeg n8.1.1 的专用 GPU 转码工具，面向 NVIDIA 显卡用户。

## 设计目标

解码任意格式 → CUDA/NPP 滤镜处理 → NVENC 编码输出 HEVC 或 AV1。
全程 GPU 流水线，零 CPU 编码回退。

---

## 编码器

| 编码器 | 类型 | 说明 |
|---|---|---|
| hevc_nvenc | 视频 | H.265 硬件编码 |
| av1_nvenc | 视频 | AV1 硬件编码（需 RTX 40xx+）|
| libfdk_aac | 音频 | AAC 高质量编码 |

仅保留以上 3 个编码器，所有软件编码器（x264, x265, SVT-AV1 等）均已移除，二进制体积最小化。

---

## 解码器

### 未来将会除去部分解码器

493 个解码器全量保留，覆盖：

- **现代视频：** H.264, HEVC, AV1, VP8, VP9, VVC (H.266), ProRes, DNxHD
- **传统视频：** MPEG-1/2/4, WMV, RealVideo, Theora, Cinepak, Indeo, Bink
- **图像：** MJPEG, JPEG2000, PNG, WebP, BMP, TIFF, GIF, DPX, EXR
- **现代音频：** AAC, MP3, Opus, Vorbis, FLAC, ALAC, WavPack, TrueHD, E-AC3, AC-3, DTS
- **传统音频：** RealAudio, WMA 全系, AMR, aptX, SBC
- **字幕：** SRT, SSA/ASS, WebVTT, PGS, DVB

---

## CUDA 滤镜（10 个）

| 滤镜 | 功能 |
|---|---|
| scale_cuda | GPU 缩放 |
| bilateral_cuda | GPU 双边降噪 |
| bwdif_cuda | GPU Bob Weaver 去隔行 |
| yadif_cuda | GPU Yadif 去隔行 |
| chromakey_cuda | GPU 色度键抠像 |
| colorspace_cuda | GPU 色彩空间转换 |
| overlay_cuda | GPU 视频叠加 |
| pad_cuda | GPU 填充/加边框 |
| thumbnail_cuda | GPU 缩略图选取 |
| hwupload_cuda | CPU→CUDA 帧上传 |

## NPP 滤镜（2 个）

| 滤镜 | 功能 |
|---|---|
| sharpen_npp | NPP 锐化（弥补无 sharpen_cuda）|
| transpose_npp | NPP 旋转/转置 |

> scale_npp / scale2ref_npp 已显式禁用，功能由 scale_cuda 覆盖。

## 软件滤镜

### 未来将会大量软件滤镜

492 个内置滤镜全量保留，含 libzimg (zscale)、libass (drawtext/subtitles) 等高质量外部库滤镜。

---

## 增强特性

### CUDA / NVENC / NVDEC
- CUDA Toolkit 13.3.0，NVCC 编译（非 LLVM）
- NVENC 硬件编码：HEVC + AV1
- NVDEC 硬件解码：通过 `-hwaccel cuda` 启用
- NPP 13.1.2.48 提供额外 GPU 滤镜

### GPU 架构支持
- SM 7.5 — Turing（RTX 20xx, GTX 16xx）
- SM 8.0 — Ampere（A100）
- SM 8.6 — Ampere（RTX 30xx）
- SM 8.9 — Ada Lovelace（RTX 40xx）
- SM 12.0 — Blackwell（RTX 50xx）

覆盖 2018 年至今所有主流 NVIDIA GPU。

### x86-64-v3 CPU 基线
- 要求 AVX2 + FMA + BMI2（Intel Haswell / AMD Excavator 及以上）
- 启用 -O2 优化、LTO 链接时优化、section GC 死代码消除
- NVCC device 代码使用 -O3 + fast_math + extra-device-vectorization

### 字幕渲染栈
- libass + libfreetype + libharfbuzz + libfontconfig + libfribidi
- 支持 ASS/SSA 高级字幕特效、Unicode 双向文本、系统字体自动发现

### 完全静态链接
- 零 DLL 依赖，单文件即用
- 跨平台构建：Linux → Windows（x86_64-w64-mingw32）

---

## 系统要求

- **GPU：** NVIDIA GTX 16xx / RTX 20xx 及以上
- **CPU：** 支持 AVX2 的 x86-64 处理器（2013 年后）
- **OS：** Windows 10/11 64-bit
