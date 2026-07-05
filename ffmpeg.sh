#!/usr/bin/env bash
# ==============================================================================
# FFmpeg NVENC 极简硬件加速版静态交叉编译集成脚本 (MinGW-w64 x86_64-w64-mingw32)
# ==============================================================================
set -Eeuo pipefail

# 1. 运行路径安全校验
# 必须在 nvenc 目录下运行，如果不在，则自动复制自己到 nvenc 目录并提示用户
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" != */nvenc ]]; then
  mkdir -p "$SCRIPT_DIR/nvenc"
  cp -f "$BASH_SOURCE" "$SCRIPT_DIR/nvenc/ffmpeg.sh"
  chmod +x "$SCRIPT_DIR/nvenc/ffmpeg.sh"
  echo "警告: 检测到当前不在 nvenc 目录下运行！"
  echo "已将脚本自动复制到: $SCRIPT_DIR/nvenc/ffmpeg.sh"
  echo "请切换目录并重新运行: cd \"$SCRIPT_DIR/nvenc\" && ./ffmpeg.sh"
  exit 1
fi

# 2. 全局基础变量与编译配置定义
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PREFIX="${PREFIX:-$ROOT/bin_nvenc}"
BUILDROOT="${BUILDROOT:-$ROOT/build_nvenc}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"
FFMPEG_REF="${FFMPEG_REF:-master}"

# 编译优化选项
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O2 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions -finline-small-functions -findirect-inlining}"
SECTION_GC_ENABLE="${SECTION_GC_ENABLE:-1}"
LTO_ENABLE="${LTO_ENABLE:-1}"
LTO_FLAGS="${LTO_FLAGS:--flto=auto}"
CPU_FLAGS="${CPU_FLAGS:--march=x86-64-v3 -mtune=generic}"

# CUDA/NVENC 配置
CUDA_ENABLE="${CUDA_ENABLE:-1}"
CUDA_REDIST_ROOT="${CUDA_REDIST_ROOT:-$ROOT/toolchains/cuda-redist-13.3.0/install/linux}"
CUDA_HOME="${CUDA_HOME:-}"
NVCC="${NVCC:-}"
NVCC_GENCODE_FLAGS="${NVCC_GENCODE_FLAGS:--gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120}"
NVCC_OPTFLAGS="${NVCC_OPTFLAGS:--O3 --extra-device-vectorization}"
NVCC_THREADS="${NVCC_THREADS:-0}"
NVCC_PTXAS_FLAGS="${NVCC_PTXAS_FLAGS:--O3}"
NVCC_FAST_MATH="${NVCC_FAST_MATH:-1}"

# Git 源码库 URL 映射
declare -A URLS=(
  [ffmpeg-source]="https://github.com/FFmpeg/FFmpeg.git"
  [nv-codec-headers]="https://github.com/FFmpeg/nv-codec-headers.git"
  [zimg]="https://github.com/sekrit-twc/zimg.git"
  [dav1d]="https://code.videolan.org/videolan/dav1d.git"
  [vapoursynth]="https://github.com/vapoursynth/vapoursynth.git"
)

# Git 源码版本 Tag 匹配正则
declare -A TAG_REGEX=(
  [ffmpeg-source]='master'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [zimg]='^release-[0-9]+(\.[0-9]+)*$'
  [dav1d]='^[0-9]+(\.[0-9]+)*$'
  [vapoursynth]='^R[0-9]+(\.[0-9]+)*$'
)

# 编译依赖阶段列表
STAGES=(
  "nv-codec-headers"
  "zimg"
  "dav1d"
  "vapoursynth"
  "ffmpeg"
)

# 滤镜白名单
ALLOWED_FILTERS=(
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

  buffer
  buffersink
  abuffer
  abuffersink
  format
  aformat
  null
  anull
  fps
  trim
  atrim
  setpts
  asetpts
  settb
  asettb
  setparams
  setsar
  aresample

  transpose
  crop
  hflip
  vflip
  rotate
)

# Helper 函数：规范化阶段名称
normalize_stage() {
  local s="${1#--}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    nv|nvcodec|nv-codec|nv-codec-headers|ffnvcodec) echo "nv-codec-headers" ;;
    zimg) echo "zimg" ;;
    dav1d) echo "dav1d" ;;
    vapoursynth|vs) echo "vapoursynth" ;;
    ffmpeg) echo "ffmpeg" ;;
    *) return 1 ;;
  esac
}

# 辅助函数：数组包含性检查
is_in_array() {
  local item="$1"
  shift
  local element
  for element in "$@"; do
    if [[ "$element" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

# 规范化版本号以进行版本排序
normalize_version() {
  local repo="$1"
  local tag="$2"
  case "$repo" in
    ffmpeg-source|nv-codec-headers)
      echo "${tag#n}"
      ;;
    zimg)
      echo "${tag#release-}"
      ;;
    *)
      echo "${tag#v}"
      ;;
  esac
}

# 校验 CUDA_HOME 路径下是否包含关键的 CUDA 及 NVRTC 头文件
is_valid_cuda() {
  local path="$1"
  if [[ -d "$path" && -f "$path/include/cuda.h" && -f "$path/include/nvrtc.h" ]]; then
    return 0
  fi
  return 1
}

find_cuda_home() {
  if [[ -d "$CUDA_REDIST_ROOT" && -x "$CUDA_REDIST_ROOT/bin/nvcc" ]]; then
    CUDA_HOME="$CUDA_REDIST_ROOT"
    return 0
  fi

  if [[ -n "${CUDA_HOME:-}" ]]; then
    if is_valid_cuda "$CUDA_HOME"; then
      return 0
    else
      echo "警告: 指定的 CUDA_HOME 环境变量不完整 (缺少 cuda.h 或 nvrtc.h): $CUDA_HOME"
    fi
  fi

  if is_valid_cuda "/usr/local/cuda"; then
    CUDA_HOME="/usr/local/cuda"
    return 0
  fi

  local latest=""
  latest="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$latest" ]] && is_valid_cuda "$latest"; then
    CUDA_HOME="$latest"
    return 0
  fi

  echo "错误: 未找到完整的 CUDA Toolkit 目录。请将官方 CUDA redist 解压到 $CUDA_REDIST_ROOT，或安装完整 CUDA 并设定环境变量 export CUDA_HOME=/usr/local/cuda"
  exit 1
}

setup_cuda() {
  if [[ "$CUDA_ENABLE" != "1" ]]; then
    echo "CUDA 支持已禁用: CUDA_ENABLE=$CUDA_ENABLE"
    return 0
  fi

  find_cuda_home
  export CUDA_HOME
  export PATH="$CUDA_HOME/bin:$PATH"

  if [[ -z "${NVCC:-}" ]]; then
    NVCC="$CUDA_HOME/bin/nvcc"
  fi
  NVCC="$(canonical_tool "$NVCC")"

  "$NVCC" --version >/dev/null || {
    echo "nvcc 无法运行: $NVCC"
    exit 1
  }

  export NVCC
}

make_nvccflags() {
  local flags="$NVCC_GENCODE_FLAGS $NVCC_OPTFLAGS"
  if [[ -n "${NVCC_THREADS:-}" ]]; then
    flags+=" --threads=$NVCC_THREADS"
  fi
  if [[ -n "${NVCC_PTXAS_FLAGS:-}" ]]; then
    flags+=" -Xptxas=$NVCC_PTXAS_FLAGS"
  fi
  if [[ "$NVCC_FAST_MATH" == "1" ]]; then
    flags+=" --use_fast_math"
  fi
  printf '%s\n' "$flags"
}

print_cuda_summary() {
  if [[ "$CUDA_ENABLE" != "1" ]]; then
    return 0
  fi
  echo "CUDA_HOME=$CUDA_HOME"
  echo "CUDA_REDIST_ROOT=$CUDA_REDIST_ROOT"
  echo "NVCC=$NVCC"
  echo "NVCC_GENCODE_FLAGS=$NVCC_GENCODE_FLAGS"
  echo "NVCC_OPTFLAGS=$NVCC_OPTFLAGS"
  echo "NVCC_THREADS=$NVCC_THREADS"
  echo "NVCC_PTXAS_FLAGS=$NVCC_PTXAS_FLAGS"
  echo "NVCC_FAST_MATH=$NVCC_FAST_MATH"
  "$NVCC" --version
}

make_common_flags() {
  COMMON_OPT_FLAGS="$OPT_CFLAGS_BASE"
  if [[ "$INLINE_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" $INLINE_FLAGS"
  fi
  if [[ -n "${CPU_FLAGS:-}" ]]; then
    COMMON_OPT_FLAGS+=" $CPU_FLAGS"
  fi
  if [[ "$SECTION_GC_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" -ffunction-sections -fdata-sections"
    COMMON_LDFLAGS+=" -Wl,--gc-sections"
  fi
  if [[ "$LTO_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" $LTO_FLAGS"
    COMMON_LDFLAGS+=" $LTO_FLAGS"
  fi
  export COMMON_OPT_FLAGS COMMON_LDFLAGS
  export CFLAGS="${CFLAGS:-$COMMON_OPT_FLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$COMMON_OPT_FLAGS}"
  export LDFLAGS="${LDFLAGS:-$COMMON_LDFLAGS}"
}

meson_quote_array() {
  local flags="$1"
  local arr=()
  local f
  read -r -a arr <<< "$flags"
  printf '['
  local first=1
  for f in "${arr[@]}"; do
    [[ -z "$f" ]] && continue
    f="${f//\\/\\\\}"
    f="${f//\'/\\\'}"
    if [[ "$first" -eq 0 ]]; then
      printf ', '
    fi
    printf "'%s'" "$f"
    first=0
  done
  printf ']'
}

check_cpu_flags() {
  local tmp="$BUILDROOT/.cpu-flags-test.o"
  mkdir -p "$BUILDROOT"
  printf 'int main(void){return 0;}\n' | "$CC" $CFLAGS -x c -c -o "$tmp" - || {
    echo "当前交叉编译器不支持设定的 CPU/LTO 参数:"
    echo "  CFLAGS=$CFLAGS"
    echo "可能是不兼容的 -march 选项或 LTO 特性未就绪。请尝试更保守的参数重新编译，例如："
    echo '  CPU_FLAGS="-march=x86-64-v2 -mtune=generic" ./ffmpeg.sh build'
    exit 1
  }
  rm -f "$tmp"
}

# 检出源码树
stage_src() {
  local name="$1"
  local src="$ROOT/$name"
  local stage="$BUILDROOT/_src/$name"
  rm -rf "$stage"
  mkdir -p "$(dirname "$stage")"
  cp -a "$src" "$stage"
  echo "$stage"
}

write_meson_cross() {
  local meson_lto=false
  [[ "$LTO_ENABLE" == "1" ]] && meson_lto=true

  cat > "$BUILDROOT/mingw-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '$WINDRES'
pkg-config = '$PKG_CONFIG'
cuda = '$NVCC'

[built-in options]
c_args = $(meson_quote_array "$CFLAGS -I$PREFIX/include")
cpp_args = $(meson_quote_array "$CXXFLAGS -I$PREFIX/include")
c_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
cpp_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
optimization = '2'
b_lto = $meson_lto

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

build_autotools() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"

  pushd "$stage" >/dev/null
  if [[ ! -x ./configure ]]; then
    if [[ -x ./autogen.sh ]]; then
      ./autogen.sh
    elif [[ -f ./bootstrap ]]; then
      ./bootstrap
    elif [[ -f configure.ac || -f configure.in ]]; then
      autoreconf -fiv
    fi
  fi

  ./configure \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    "$@"

  make -j"$JOBS"
  make install
  popd >/dev/null
}

build_cmake() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  local bld="$BUILDROOT/$name"
  local ipo=OFF
  [[ "$LTO_ENABLE" == "1" ]] && ipo=ON

  rm -rf "$bld"
  cmake -S "$stage" -B "$bld" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_RC_COMPILER="$WINDRES" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="$CFLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$ipo" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    "$@"

  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
}

build_meson() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  local bld="$BUILDROOT/$name"

  rm -rf "$bld"
  meson setup "$bld" "$stage" \
    --cross-file "$BUILDROOT/mingw-cross.txt" \
    --prefix "$PREFIX" \
    --buildtype release \
    --default-library=static \
    -Doptimization=2 \
    "$@"

  meson compile -C "$bld" -j "$JOBS"
  meson install -C "$bld"
}

validate_ffmpeg_configuration() {
  local config_mak="$1"
  local config_h="$2"

  if [[ "$LTO_ENABLE" == "1" ]]; then
    grep -Eq -- '-flto(=auto)?' "$config_mak" || {
      echo "异常：config.mak 中未发现 -flto，LTO 可能未生效"
      grep -n 'flto\|LTO' "$config_mak" || true
      exit 1
    }
  fi

  grep -q '^CONFIG_HEVC_NVENC_ENCODER=yes$' "$config_mak" || { echo "异常：hevc_nvenc 编码器未启用"; exit 1; }
  grep -q '^CONFIG_AV1_NVENC_ENCODER=yes$' "$config_mak" || { echo "异常：av1_nvenc 编码器未启用"; exit 1; }
  grep -q '^CONFIG_AAC_ENCODER=yes$' "$config_mak" || { echo "异常：AAC (内置原生) 编码器未启用"; exit 1; }

  local allowed='CONFIG_(HEVC_NVENC|AV1_NVENC|AAC)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
  local unexpected
  unexpected="$(grep -E '^CONFIG_.*_ENCODER=yes$' "$config_mak" | grep -Ev "$allowed" || true)"
  if [[ -n "$unexpected" ]]; then
    echo "异常：发现目标外编码器仍被启用："
    printf '%s\n' "$unexpected"
    exit 1
  fi

  if grep -q '^CONFIG_LIBFDK_AAC=yes$' "$config_mak" || grep -q '^CONFIG_LIBFDK_AAC_ENCODER=yes$' "$config_mak"; then
    echo "异常：不应被启用的 fdk-aac 编码器检测到已开启"
    exit 1
  fi

  if grep -q '^CONFIG_LIBSVTAV1=yes$' "$config_mak" || grep -q '^CONFIG_LIBSVTAV1_ENCODER=yes$' "$config_mak"; then
    echo "异常：SVT-AV1 仍被启用"
    exit 1
  fi

  if grep -q '^CONFIG_LIBNPP=yes$' "$config_mak"; then
    echo "异常：libnpp 不应启用"
    exit 1
  fi

  # 检查所有启用的滤镜
  local filter_line
  while read -r filter_line; do
    if [[ "$filter_line" =~ ^CONFIG_([A-Za-z0-9_]+)_FILTER=yes$ ]]; then
      local filter_name="${BASH_REMATCH[1]}"
      local filter_lower
      filter_lower="$(printf '%s' "$filter_name" | tr '[:upper:]' '[:lower:]')"
      
      local found=0
      local allowed_f
      for allowed_f in "${ALLOWED_FILTERS[@]}"; do
        if [[ "$allowed_f" == "$filter_lower" ]]; then
          found=1
          break
        fi
      done
      
      if [[ "$found" -eq 0 ]]; then
        echo "异常：启用了未在白名单中的滤镜: $filter_lower (CONFIG_${filter_name}_FILTER)"
        exit 1
      fi
    fi
  done < "$config_mak"

  if [[ "$CUDA_ENABLE" == "1" ]]; then
    grep -q '^CONFIG_CUDA_NVCC=yes$' "$config_mak" || { echo "异常：cuda-nvcc 未启用"; exit 1; }
    local cuda_f
    for cuda_f in scale_cuda overlay_cuda pad_cuda colorspace_cuda yadif_cuda bwdif_cuda bilateral_cuda chromakey_cuda thumbnail_cuda hwupload_cuda hwdownload hwmap; do
      local macro="CONFIG_$(printf '%s' "$cuda_f" | tr '[:lower:]' '[:upper:]')_FILTER"
      grep -q "^${macro}=yes$" "$config_mak" || {
        echo "异常：CUDA 优先滤镜未启用: $cuda_f"
        exit 1
      }
    done
  fi

  grep -q '#define FFMPEG_LICENSE "nonfree and unredistributable"' "$config_h" || {
    echo "异常：许可证状态不是 nonfree and unredistributable"
    grep 'FFMPEG_LICENSE' "$config_h" || true
    exit 1
  }

  # 验证字幕相关组件均已禁用
  local disabled_components=(
    CONFIG_LIBASS CONFIG_LIBFREETYPE CONFIG_LIBFONTCONFIG CONFIG_LIBFRIBIDI CONFIG_LIBHARFBUZZ
    CONFIG_SUBTITLES_FILTER CONFIG_ASS_FILTER CONFIG_DRAWTEXT_FILTER
    CONFIG_ASS_DECODER CONFIG_SRT_DECODER CONFIG_SUBRIP_DECODER CONFIG_WEBVTT_DECODER
    CONFIG_MOVTEXT_DECODER CONFIG_DVBSUB_DECODER CONFIG_DVDSUB_DECODER CONFIG_PGSSUB_DECODER
    CONFIG_ASS_ENCODER CONFIG_SRT_ENCODER CONFIG_SUBRIP_ENCODER CONFIG_WEBVTT_ENCODER
    CONFIG_MOVTEXT_ENCODER CONFIG_DVBSUB_ENCODER CONFIG_DVDSUB_ENCODER
  )
  local comp
  for comp in "${disabled_components[@]}"; do
    if grep -q "^${comp}=yes$" "$config_mak"; then
      echo "异常：不应启用的字幕相关组件被启用: $comp"
      exit 1
    fi
  done
}

run_stage() {
  local stage="$1"
  CURRENT_STAGE="$stage"
  echo "===> $stage"

  case "$stage" in
    nv-codec-headers)
      local nv_stage
      nv_stage="$(stage_src "nv-codec-headers")"
      rm -f "$nv_stage/ffnvcodec.pc"
      make -C "$nv_stage" PREFIX="$PREFIX"
      make -C "$nv_stage" PREFIX="$PREFIX" install
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "pkg-config 无法识别 ffnvcodec"
        exit 1
      }
      ;;

    zimg)
      build_autotools zimg
      ;;

    dav1d)
      build_meson dav1d \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_examples=false \
        -Denable_asm=true
      ;;

    vapoursynth)
      local vs_stage
      vs_stage="$(stage_src "vapoursynth")"
      mkdir -p "$PREFIX/include"
      cp -f "$vs_stage/include/VapourSynth.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSHelper.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSHelper4.h" "$PREFIX/include/"

      mkdir -p "$PREFIX/include/vapoursynth"
      cp -f "$vs_stage/include/VapourSynth.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSHelper.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSHelper4.h" "$PREFIX/include/vapoursynth/"

      # 动态生成 .pc 规避 FFmpeg 检测
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/vapoursynth.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: vapoursynth
Description: VapourSynth scripting library
Version: 77
Libs:
Cflags: -I\${includedir}
EOF
      cp -f "$PREFIX/lib/pkgconfig/vapoursynth.pc" "$PREFIX/lib/pkgconfig/VapourSynth.pc"
      ;;

    ffmpeg)
      # 重置 configure 脚本以避免重复 patch 产生冲突
      git -C "$ROOT/ffmpeg-source" checkout configure || true
      # 用 nvcc -fatbin 嵌入 CUDA 滤镜模块（支持多架构 sm/compute 显卡）
      sed -i 's/nvccflags="$nvccflags -ptx"/nvccflags="$nvccflags -fatbin"/g' "$ROOT/ffmpeg-source/configure"

      local ff_bld="$BUILDROOT/ffmpeg"
      rm -rf "$ff_bld"
      mkdir -p "$ff_bld"
      pushd "$ff_bld" >/dev/null
      unset MAKEFILES MAKEFLAGS MFLAGS GNUMAKEFLAGS

      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "缺少 ffnvcodec，请先编译 nv-codec-headers 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists dav1d || {
        echo "缺少 dav1d，请先编译 dav1d 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vapoursynth || {
        echo "缺少 vapoursynth，请先编译 vapoursynth 阶段"
        exit 1
      }

      local extra_cflags="-I$PREFIX/include"
      local extra_ldflags="-L$PREFIX/lib -static -static-libgcc -static-libstdc++ $LDFLAGS"
      local extra_libs="-lstdc++ -lwinpthread -lgcc"
      local cuda_flags=()
      local filter_flags=(--disable-filters)
      local f

      require_config_item --list-encoders hevc_nvenc
      require_config_item --list-encoders av1_nvenc
      require_config_item --list-encoders aac

      if [[ "$CUDA_ENABLE" == "1" ]]; then
        print_cuda_summary
        extra_cflags+=" -I$CUDA_HOME/include"
        cuda_flags=(
          --enable-cuda-nvcc
          --enable-cuda
          --disable-cuda-llvm
          --nvcc="$NVCC"
          --nvccflags="$(make_nvccflags)"
        )
      fi

      local lto_flags=()
      if [[ "$LTO_ENABLE" == "1" ]]; then
        lto_flags=(--enable-lto=auto)
      fi

      SKIPPED_ITEMS=()
      local configure_cmd=(
        "$ROOT/ffmpeg-source/configure"
        --prefix="$PREFIX"
        --bindir="$PREFIX/bin"
        --arch=x86_64
        --target-os=mingw32
        --cross-prefix="$TARGET-"
        --enable-cross-compile
        --cc="$CC"
        --cxx="$CXX"
        --ld="$CXX"
        --ar="$AR"
        --nm="$NM"
        --ranlib="$RANLIB"
        --pkg-config="$PKG_CONFIG"
        --pkg-config-flags=--static
        --optflags="$CFLAGS"
        --extra-cflags="$extra_cflags"
        --extra-cxxflags="$CXXFLAGS"
        --extra-ldflags="$extra_ldflags"
        --extra-libs="$extra_libs"
        --disable-autodetect
        --enable-gpl
        --enable-nonfree
        --enable-static
        --disable-shared
        --disable-debug
        --disable-doc
        --disable-ffplay
        --disable-ffprobe
        --enable-ffmpeg
        --enable-ffnvcodec
        --disable-libass
        --disable-libfreetype
        --disable-libfontconfig
        --disable-libfribidi
        --disable-libharfbuzz
        "${lto_flags[@]}"
        "${cuda_flags[@]}"
        "${filter_flags[@]}"
        --enable-nvenc
        --enable-nvdec
        --disable-cuvid
        --enable-libzimg
        --enable-libdav1d
        --enable-vapoursynth
      )

      add_if_exists() {
        local list_cmd="$1"
        local name="$2"
        local enable_flag="$3"
        if have_config_item "$list_cmd" "$name"; then
          configure_cmd+=("$enable_flag=$name")
        else
          SKIPPED_ITEMS+=("$name ($list_cmd)")
          echo "WARNING: $name is not supported by FFmpeg ($list_cmd), skipping."
        fi
      }

      # 编码器白名单
      configure_cmd+=(--disable-encoders)
      add_if_exists --list-encoders hevc_nvenc --enable-encoder
      add_if_exists --list-encoders av1_nvenc --enable-encoder
      add_if_exists --list-encoders aac --enable-encoder

      # 解码器白名单
      configure_cmd+=(--disable-decoders)
      local video_decoders=(
        h264 hevc av1 vp9 vp8 mpeg2video mpeg4 msmpeg4v3 vc1 wmv3 prores dnxhd cfhd mjpeg jpeg2000 png webp bmp tiff gif rawvideo libdav1d
      )
      local audio_decoders=(
        aac mp3 ac3 eac3 truehd dca flac opus vorbis wavpack alac pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le
      )
      local old_decoders=(
        indeo2 indeo3 indeo4 indeo5 cinepak rv10 rv20 h261 h263 h263i flv svq1 svq3 binkvideo cineform
      )

      local dec
      for dec in "${video_decoders[@]}" "${audio_decoders[@]}" "${old_decoders[@]}"; do
        if [[ " ${old_decoders[*]} " =~ " ${dec} " ]]; then
          SKIPPED_ITEMS+=("$dec (explicitly excluded/obsolete)")
          continue
        fi
        add_if_exists --list-decoders "$dec" --enable-decoder
      done

      # 硬件加速器白名单
      configure_cmd+=(--disable-hwaccels)
      local hwaccels=(
        h264_nvdec hevc_nvdec av1_nvdec vp8_nvdec vp9_nvdec mpeg2_nvdec vc1_nvdec mjpeg_nvdec
      )
      local hw
      for hw in "${hwaccels[@]}"; do
        add_if_exists --list-hwaccels "$hw" --enable-hwaccel
      done

      # 解复用器 (Demuxers) 白名单
      configure_cmd+=(--disable-demuxers)
      local demuxers=(
        matroska mov mpegts h264 hevc av1 rawvideo image2 concat aac mp3 flac ogg wav vapoursynth
      )
      local dem
      for dem in "${demuxers[@]}"; do
        add_if_exists --list-demuxers "$dem" --enable-demuxer
      done

      # 复用器 (Muxers) 白名单
      configure_cmd+=(--disable-muxers)
      local muxers=(
        matroska mp4 mpegts null rawvideo image2 adts flac ogg wav mov ipod
      )
      local mux
      for mux in "${muxers[@]}"; do
        add_if_exists --list-muxers "$mux" --enable-muxer
      done

      # 解析器 (Parsers) 白名单
      configure_cmd+=(--disable-parsers)
      local parsers=(
        h264 hevc av1 aac mp3 opus vorbis
      )
      local parser
      for parser in "${parsers[@]}"; do
        add_if_exists --list-parsers "$parser" --enable-parser
      done

      # 比特流过滤器 (BSF) 白名单
      configure_cmd+=(--disable-bsfs)
      local bsfs=(
        h264_mp4toannexb hevc_mp4toannexb av1_metadata h264_metadata hevc_metadata aac_adtstoasc extract_extradata
      )
      local bsf
      for bsf in "${bsfs[@]}"; do
        add_if_exists --list-bsfs "$bsf" --enable-bsf
      done

      # 滤镜白名单化：只逐项启用必要滤镜
      for f in "${ALLOWED_FILTERS[@]}"; do
        if [[ "$CUDA_ENABLE" != "1" ]]; then
          if [[ "$f" == *_cuda || "$f" == hwupload_cuda ]]; then
            echo "CUDA_ENABLE=0, skipping filter: $f"
            continue
          fi
        fi
        add_if_exists --list-filters "$f" --enable-filter
      done

      printf '%s\n' "${configure_cmd[@]}" > "$BUILDROOT/ffmpeg-configure.args"
      echo "===== FFmpeg configure 命令 ====="
      printf '%q ' "${configure_cmd[@]}"
      echo
      "${configure_cmd[@]}"

      validate_ffmpeg_configuration ffbuild/config.mak config.h

      echo "===== 已启用的目标编码器 ====="
      grep -E '^CONFIG_(HEVC_NVENC|AV1_NVENC|AAC)_ENCODER=yes$' ffbuild/config.mak || true
      echo "===== CUDA 滤镜状态 ====="
      grep -E '^CONFIG_.*CUDA.*_FILTER=' ffbuild/config.mak || true
      if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo "===== 编译跳过/未支持组件 ====="
        printf ' - %s\n' "${SKIPPED_ITEMS[@]}"
      fi

      test -s Makefile || { echo "异常：构建目录未生成 Makefile"; exit 1; }
      make -f ./Makefile -j"$FFMPEG_JOBS"
      make -f ./Makefile install
      popd >/dev/null

      test -f "$PREFIX/bin/ffmpeg.exe" || { echo "异常：未生成 $PREFIX/bin/ffmpeg.exe"; exit 1; }
      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || true
      
      # 将输出文件复制到 SCRIPT_DIR (即 nvenc 文件夹)
      mkdir -p "$SCRIPT_DIR"
      cp -f "$PREFIX/bin/ffmpeg.exe" "$SCRIPT_DIR/ffmpeg.exe"
      echo "成功将静态编译的 ffmpeg.exe 复制到: $SCRIPT_DIR/ffmpeg.exe"

      # 复制到 D:/ (WSL 下为 /mnt/d/)
      if [[ -d "/mnt/d" ]]; then
        echo "Copying ffmpeg.exe to /mnt/d/ffmpeg.exe..."
        cp -f "$PREFIX/bin/ffmpeg.exe" "/mnt/d/ffmpeg.exe"
      else
        echo "WARNING: /mnt/d/ does not exist. Cannot copy to D:/ffmpeg.exe."
      fi
      ;;

    *)
      echo "未知阶段: $stage"
      exit 1
      ;;
  esac
}

# ----------------- 命令行操作流程逻辑 -----------------

# 全量构建流程: tool -> update -> build
run_all() {
  echo "===> [子命令: all] 开始完整构建流程..."
  run_tool
  run_update
  run_build
}

# 仅安装环境工具链与 CUDA
run_tool() {
  echo "===> [子命令: tool] 开始安装本地构建环境与工具链..."
  sudo apt update
  sudo apt full-upgrade -y
  sudo apt install -y --no-install-recommends \
    build-essential \
    autoconf automake libtool make cmake meson ninja-build \
    pkg-config nasm yasm \
    git curl ca-certificates \
    python3 gettext gperf \
    mingw-w64 mingw-w64-tools \
    binutils-mingw-w64-x86-64 \
    gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
    gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
    mingw-w64-x86-64-dev

  if [[ "$CUDA_ENABLE" == "1" ]]; then
    echo "===> 安装最新版 CUDA Toolkit for WSL..."
    local cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64"
    local cuda_keyring="${cuda_repo}/cuda-keyring_1.1-1_all.deb"
    local tmpdeb
    tmpdeb="$(mktemp --suffix=.deb)"
    curl -fL --retry 3 -o "$tmpdeb" "$cuda_keyring"
    sudo dpkg -i "$tmpdeb"
    rm -f "$tmpdeb"
    sudo apt update
    sudo apt install -y --no-install-recommends cuda-toolkit
    
    # 写入环境变量配置
    if [[ -d /usr/local/cuda ]]; then
      sudo tee /etc/profile.d/cuda.sh >/dev/null <<'EOF'
export CUDA_HOME=/usr/local/cuda
export CUDA_PATH=/usr/local/cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
EOF
      export CUDA_HOME=/usr/local/cuda
      export CUDA_PATH=/usr/local/cuda
      export PATH=/usr/local/cuda/bin:$PATH
      export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    fi
  fi
  echo "构建环境与工具链部署完成。"
}

clone_if_missing() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local url="${URLS[$name]}"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "===> 克隆 $name 仓库: $url"
    git clone "$url" "$repo_dir"
  fi
}

latest_stable_tag() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local regex="${TAG_REGEX[$name]}"

  git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/tags \
    | sed 's/\^{}$//' \
    | sort -u \
    | { grep -E "$regex" || true; } \
    | while read -r tag; do
        printf "%s\t%s\n" "$(normalize_version "$name" "$tag")" "$tag"
      done \
    | sort -V \
    | tail -n 1 \
    | cut -f2
}

sanitize_repo() {
  local repo_dir="$1"
  git -C "$repo_dir" reset --hard
  git -C "$repo_dir" clean -fdx
}

checkout_stable() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local tag="$2"
  local ver
  ver="$(normalize_version "$name" "$tag")"

  if [[ "$name" == "ffmpeg-source" ]]; then
    git -C "$repo_dir" branch -D "build-$ver" 2>/dev/null || true
    git -C "$repo_dir" switch -C "build-$ver" "$tag"
  else
    git -C "$repo_dir" switch --detach "$tag" 2>/dev/null || \
    git -C "$repo_dir" checkout --detach "$tag"
  fi
  git -C "$repo_dir" submodule update --init --recursive || true
}

update_one() {
  local name="$1"
  local repo_dir="$ROOT/$name"

  clone_if_missing "$name"
  echo "===> 正在清理与初始化 $name 源码目录"
  sanitize_repo "$repo_dir"

  # 强制修改 origin URL 为标准 URL 以规避旧的 SSH 认证机制
  local url="${URLS[$name]}"
  git -C "$repo_dir" remote set-url origin "$url" 2>/dev/null || true

  echo "===> 正在从上游拉取 $name 的最新分支与 Tag..."
  git -C "$repo_dir" fetch --tags --force --prune origin

  local tag=""
  if [[ "$name" == "ffmpeg-source" ]]; then
    tag="$FFMPEG_REF"
  else
    tag="$(latest_stable_tag "$name")"
  fi

  if [[ -z "$tag" ]]; then
    tag="master"
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$tag"; then
      tag="main"
    fi
  fi

  echo "===> $name 切换至版本 $tag"
  checkout_stable "$name" "$tag"
}

# 仅克隆或更新所有依赖库源码至最新版
run_update() {
  echo "===> [子命令: update] 开始克隆与更新所需所有最新源码..."
  mkdir -p "$ROOT"
  
  local repos=(
    ffmpeg-source
    nv-codec-headers
    zimg
    dav1d
    vapoursynth
  )
  for r in "${repos[@]}"; do
    update_one "$r"
  done
  echo "所有源码目录已成功更新至最新稳定版或指定分支。"
}

# 执行依赖库和 FFmpeg 静态交叉编译构建
run_build() {
  echo "===> [子命令: build] 开始编译与链接依赖阶段..."
  
  # 检测基础环境工具
  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  need_cmd python3
  need_cmd git
  need_cmd cmake
  need_cmd meson
  need_cmd ninja
  need_cmd make
  need_cmd autoreconf
  need_cmd pkg-config
  
  # 配置编译器
  CC="$(canonical_tool "${CC:-${TARGET}-gcc-posix}")"
  CXX="$(canonical_tool "${CXX:-${TARGET}-g++-posix}")"
  if [[ "$LTO_ENABLE" == "1" ]]; then
    AR="$(canonical_first_tool "${TARGET}-gcc-ar-posix" "${TARGET}-gcc-ar")"
    RANLIB="$(canonical_first_tool "${TARGET}-gcc-ranlib-posix" "${TARGET}-gcc-ranlib")"
    NM="$(canonical_first_tool "${TARGET}-gcc-nm-posix" "${TARGET}-gcc-nm")"
  else
    AR="$(canonical_tool "${AR:-${TARGET}-ar}")"
    RANLIB="$(canonical_tool "${RANLIB:-${TARGET}-ranlib}")"
    NM="$(canonical_tool "${NM:-${TARGET}-nm}")"
  fi
  STRIP="$(canonical_tool "${STRIP:-${TARGET}-strip}")"
  WINDRES="$(canonical_tool "${WINDRES:-${TARGET}-windres}")"
  PKG_CONFIG="$(canonical_tool "${PKG_CONFIG:-pkg-config}")"

  export CC CXX AR NM RANLIB STRIP WINDRES PKG_CONFIG CUDA_HOME CUDA_ENABLE
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

  setup_cuda
  make_common_flags
  check_cpu_flags

  # 初始化构建目录
  mkdir -p "$BUILDROOT"
  write_meson_cross

  # 如果是完整构建，则清空旧的前缀目录以防交叉感染
  if [[ "$FULL_BUILD" -eq 1 ]]; then
    echo "进行完整构建，正在清空前缀输出目录..."
    rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"
  fi

  # 校验源码目录是否存在
  local repo_check
  for repo_check in "${STAGES[@]}"; do
    if [[ -n "${BUILD_ONLY_STAGE:-}" ]]; then
      if ! is_in_array "$repo_check" "${BUILD_ONLY_STAGE[@]}"; then
        continue
      fi
    fi
    if [[ "$repo_check" == "ffmpeg" ]]; then
      need_repo "ffmpeg-source"
    else
      need_repo "$repo_check"
    fi
  done

  # 阶段执行机制
  local run_flag=0
  local stage
  for stage in "${STAGES[@]}"; do
    if [[ "$FULL_BUILD" -eq 1 ]]; then
      run_flag=1
    elif [[ -n "${BUILD_ONLY_STAGE:-}" ]]; then
      # 仅编译 --only 指定的库列表
      if is_in_array "$stage" "${BUILD_ONLY_STAGE[@]}"; then
        run_stage "$stage"
      fi
      continue
    elif [[ "$stage" == "$START_STAGE" ]]; then
      run_flag=1
    fi

    if [[ "$run_flag" -eq 1 ]]; then
      run_stage "$stage"
    fi
  done
}

# 清理编译缓存和旧的编译产物
run_clean() {
  echo "===> [子命令: clean] 正在清理编译临时目录与前缀输出..."
  rm -rf "$BUILDROOT"
  rm -rf "$PREFIX"
  rm -f "$SCRIPT_DIR/ffmpeg.exe"
  echo "清理完毕。"
}

# 异常中止钩子
on_error() {
  local exit_code=$?
  FAILED_STAGE="${CURRENT_STAGE:-unknown}"
  echo
  echo "============================================================"
  echo "构建失败"
  echo "失败阶段: $FAILED_STAGE"
  echo "退出码: $exit_code"
  if [[ "$FULL_BUILD" -eq 1 && "$FAILED_STAGE" != "unknown" && "$FAILED_STAGE" != "ffmpeg" ]]; then
    echo "修复错误后，您可以通过以下方式从该失败阶段继续构建："
    echo "  ./ffmpeg.sh build $FAILED_STAGE"
  fi
  echo "============================================================"
  exit "$exit_code"
}
trap on_error ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "错误: 缺少必备命令 $1，请先检查您的构建环境"
    exit 1
  }
}

need_repo() {
  local name="$1"
  [[ -d "$ROOT/$name" ]] || {
    echo "缺少源码目录: $ROOT/$name"
    echo "请先运行 ./ffmpeg.sh update"
    exit 1
  }
}

canonical_tool() {
  local val="$1"
  if [[ -z "$val" ]]; then
    return 1
  fi
  if [[ "$val" == */* ]]; then
    [[ -x "$val" ]] || {
      echo "错误: 工具无法执行: $val"
      exit 1
    }
    printf '%s\n' "$val"
  else
    command -v "$val" >/dev/null 2>&1 || {
      echo "错误: 找不到工具 $val"
      exit 1
    }
    command -v "$val"
  fi
}

canonical_first_tool() {
  local t
  for t in "$@"; do
    if command -v "$t" >/dev/null 2>&1; then
      command -v "$t"
      return 0
    fi
  done
  echo "错误: 找不到工具: $*" >&2
  exit 1
}

have_config_item() {
  local list_cmd="$1"
  local name="$2"
  "$ROOT/ffmpeg-source/configure" "$list_cmd" | tr '[:space:]' '\n' | grep -Fx "$name" >/dev/null
}

require_config_item() {
  local list_cmd="$1"
  local name="$2"
  have_config_item "$list_cmd" "$name" || {
    echo "错误: FFmpeg configure $list_cmd 中不存在 required 组件: $name"
    exit 1
  }
}

# ----------------- CLI 参数解析与分发 -----------------

print_help() {
  cat <<EOF
NVENC 极简硬件加速版静态交叉编译集成脚本 (全功能整合版)

用法:
  ./ffmpeg.sh <command> [options]

命令:
  all             顺序执行完整构建流程: tool -> update -> build (默认)
  tool            仅安装本地构建环境与工具链 (包括 MinGW 和 CUDA)
  update          仅从官方源或镜像克隆/更新所有依赖库源码
  build [stage]   执行依赖库和 FFmpeg 静态交叉编译构建。可选 [stage] 参数指定起始阶段
  build --only [stage1] [stage2] ...  仅编译指定库（支持多个，不继续构建后续依赖）
  clean           清理编译缓存和旧的编译产物，并删除生成的 ffmpeg.exe

常见示例:
  ./ffmpeg.sh all
  ./ffmpeg.sh tool
  ./ffmpeg.sh update
  ./ffmpeg.sh build
  ./ffmpeg.sh build --ffmpeg
  ./ffmpeg.sh build --only zimg dav1d

支持的编译阶段 [stage]:
  nv-codec-headers (或 nvcodec), zimg, dav1d, ffmpeg
EOF
}

# 默认运行状态控制变量
CURRENT_STAGE=""
FULL_BUILD=1
START_STAGE=""
BUILD_ONLY_STAGE=()

if [[ "$#" -eq 0 ]]; then
  run_all
  exit 0
fi

CMD="$1"
shift

case "$CMD" in
  all)
    run_all
    ;;
  tool)
    run_tool
    ;;
  update)
    run_update
    ;;
  clean)
    run_clean
    ;;
  help|-h|--help)
    print_help
    ;;
  build)
    # 处理 build 命令参数
    if [[ "$#" -eq 0 ]]; then
      run_build
      exit 0
    fi
    
    # 检查是否为 --only 模式
    if [[ "$1" == "--only" ]]; then
      shift
      if [[ "$#" -eq 0 ]]; then
        echo "错误: --only 模式必须至少指定一个编译阶段"
        print_help
        exit 1
      fi
      
      # 允许接受多个或以逗号/空格分隔的阶段参数
      for s_arg in "$@"; do
        # 兼容逗号分隔
        IFS=',' read -r -a split_args <<< "$s_arg"
        for single_s in "${split_args[@]}"; do
          [[ -z "$single_s" ]] && continue
          norm_s="$(normalize_stage "$single_s")" || {
            echo "错误: 未知的编译阶段名称: $single_s"
            exit 1
          }
          BUILD_ONLY_STAGE+=("$norm_s")
        done
      done
      
      FULL_BUILD=0
      run_build
      
      # 打印友好完成语
      echo
      echo "============================================================"
      # 将数组元素拼接为逗号分隔的字符串
      printf "成功编译了: "
      first_p=1
      for p_stage in "${BUILD_ONLY_STAGE[@]}"; do
        if [[ "$first_p" -eq 0 ]]; then
          printf ", "
        fi
        printf "%s" "$p_stage"
        first_p=0
      done
      printf "\n"
      echo "============================================================"
      exit 0
    fi

    # 处理指定起始阶段 of build
    norm_start="$(normalize_stage "$1")" || {
      echo "错误: 未知的起始编译阶段: $1"
      print_help
      exit 1
    }
    START_STAGE="$norm_start"
    FULL_BUILD=0
    run_build
    
    echo
    echo "============================================================"
    echo "构建完成"
    echo "最终输出: $SCRIPT_DIR/ffmpeg.exe"
    echo "============================================================"
    ;;
  *)
    echo "错误: 未知命令: $CMD"
    print_help
    exit 1
    ;;
esac
