# ffmpeg-nvenc-lite

面向 Windows x64 和 NVIDIA 显卡的精简 FFmpeg 构建脚本，产物是单个静态链接的 `ffmpeg.exe`。

## 主要功能

- 基于 FFmpeg master，在 Linux/WSL 中交叉编译。
- 保留 HEVC/AV1 NVENC、NVDEC、常用 CUDA 滤镜和原生 NMR AAC。
- 支持 VapourSynth 输入与 libplacebo，适合 FFmpegFreeUI 的 NVIDIA 转码流程。
- 不包含 `ffprobe`、`ffplay` 和大部分无关组件。

## 构建

```bash
chmod +x ffmpeg.sh
./ffmpeg.sh          # 更新源码后完整编译
./ffmpeg.sh build    # 使用现有源码编译
./ffmpeg.sh update   # 只更新源码
./ffmpeg.sh clean
```

产物位于当前目录的 `ffmpeg.exe`。

## FFmpegFreeUI 预设

Release 中的 `NVENC*.json` 和通用 JSON 是 [FFmpegFreeUI](https://github.com/Lake1059/FFmpegFreeUI) v6 预设，放入 `Preset_v6\User` 后读取。BM3D CUDA 的 Python、VapourSynth 和 VPy 安装方法见 [Wiki](https://github.com/Dominic485649/ffmpeg-nvenc-lite/wiki/BM3D%E2%80%90CUDA%E2%80%90%E9%99%8D%E5%99%AA%E6%95%99%E7%A8%8B)。

其他版本：[ffmpeg-full](https://github.com/Dominic485649/ffmpeg-full) · [ffmpeg-qsv-lite](https://github.com/Dominic485649/ffmpeg-qsv-lite)

> 构建启用了 nonfree 组件，FFmpeg 会将二进制标记为 `nonfree and unredistributable`。请自行确认使用与再分发合规性。
