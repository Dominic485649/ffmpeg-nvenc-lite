#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$HOME/ffmpeg}"
PREFIX="${PREFIX:-$ROOT/bin}"
BUILDROOT="${BUILDROOT:-$ROOT/build}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"

# 目标：交叉编译 Windows ffmpeg.exe。默认启用 O2 + LTO。
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O2 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions -finline-small-functions -findirect-inlining}"
SECTION_GC_ENABLE="${SECTION_GC_ENABLE:-1}"
LTO_ENABLE="${LTO_ENABLE:-1}"
LTO_FLAGS="${LTO_FLAGS:--flto=auto}"
CPU_FLAGS="${CPU_FLAGS:--march=x86-64-v3 -mtune=generic}"

# CUDA 滤镜和 NVENC 默认启用。优先使用 NVIDIA 官方 redistrib 的本地 CUDA 13.3，避免依赖 sudo 更新系统 /usr/local/cuda。
CUDA_ENABLE="${CUDA_ENABLE:-1}"
CUDA_REDIST_ROOT="${CUDA_REDIST_ROOT:-$ROOT/toolchains/cuda-redist-13.3.0/install/linux}"
CUDA_HOME="${CUDA_HOME:-}"
NVCC="${NVCC:-}"
# FFmpeg 已补丁为用 nvcc -fatbin 嵌入 CUDA 滤镜模块，cuModuleLoadData 支持 fatbin。
# 这样可以真实使用用户要求的 20–50 系多架构 SASS/PTX 目标，而不再触发 nvcc -ptx 的多 gencode 冲突。
NVCC_GENCODE_FLAGS="${NVCC_GENCODE_FLAGS:--gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120}"
NVCC_OPTFLAGS="${NVCC_OPTFLAGS:--O3 --extra-device-vectorization}"
NVCC_THREADS="${NVCC_THREADS:-0}"
NVCC_PTXAS_FLAGS="${NVCC_PTXAS_FLAGS:--O3}"
NVCC_FAST_MATH="${NVCC_FAST_MATH:-1}"

AAC_AT_ENABLE="${AAC_AT_ENABLE:-1}"


COMMON_OPT_FLAGS=""
COMMON_LDFLAGS=""
CURRENT_STAGE=""
FAILED_STAGE=""
FULL_BUILD=1
START_STAGE=""

STAGES=(
  "nv-codec-headers"
  "fdk-aac"
  "AudioToolboxWrapper"
  "zimg"
  "dav1d"
  "ffmpeg"
)

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
  bm3d_cuda
)

normalize_stage() {
  local s="${1#--}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    nv|nvcodec|nv-codec|nv-codec-headers|ffnvcodec) echo "nv-codec-headers" ;;
    fdkaac|fdk-aac|fdk) echo "fdk-aac" ;;
    audiotoolboxwrapper|atw|audiotoolbox) echo "AudioToolboxWrapper" ;;
    zimg) echo "zimg" ;;
    dav1d) echo "dav1d" ;;
    ffmpeg) echo "ffmpeg" ;;
    svt|svt-av1|svtav1|svt-av1-hdr|svtav1hdr)
      echo "SVT-AV1 已按目标从构建脚本删除，不再支持该阶段" >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<EOF
用法:
  ./build.sh                  # 全量交叉编译 Windows ffmpeg.exe，默认 O2 + LTO
  ./build.sh --ffmpeg         # 只重新配置并编译 FFmpeg
  CUDA_ENABLE=0 ./build.sh    # 禁用 CUDA 滤镜/NVCC，仅保留 NVENC/NVDEC 头文件能力
  AAC_AT_ENABLE=0 ./build.sh  # 禁用 aac_at 音频编码器

支持的阶段:
  --nv-codec-headers --fdkaac --audiotoolboxwrapper --zimg --vmaf --ffmpeg

核心默认值:
  OPT_CFLAGS_BASE="$OPT_CFLAGS_BASE"
  LTO_ENABLE=$LTO_ENABLE
  CPU_FLAGS="$CPU_FLAGS"
  CUDA_REDIST_ROOT="$CUDA_REDIST_ROOT"
  NVCC_GENCODE_FLAGS="$NVCC_GENCODE_FLAGS"
  NVCC_OPTFLAGS="$NVCC_OPTFLAGS"
  NVCC_FAST_MATH=$NVCC_FAST_MATH
EOF
}

for arg in "$@"; do
  case "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --no-lto|no-lto)
      LTO_ENABLE=0
      ;;
    *)
      if [[ -n "$START_STAGE" ]]; then
        echo "阶段参数只能指定一个，收到重复参数: $arg"
        usage
        exit 1
      fi
      START_STAGE="$(normalize_stage "$arg")" || {
        echo "未知参数: $arg"
        usage
        exit 1
      }
      FULL_BUILD=0
      ;;
  esac
done

on_error() {
  local exit_code=$?
  FAILED_STAGE="${CURRENT_STAGE:-unknown}"
  echo
  echo "============================================================"
  echo "构建失败"
  echo "失败阶段: $FAILED_STAGE"
  echo "退出码: $exit_code"
  if [[ "$FULL_BUILD" -eq 1 && "$FAILED_STAGE" != "unknown" ]]; then
    local hint="$FAILED_STAGE"
    [[ "$hint" == "fdk-aac" ]] && hint="fdkaac"
    echo "修复后可从该阶段继续："
    echo "  ./build.sh --$hint"
  fi
  echo "============================================================"
  exit "$exit_code"
}
trap on_error ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令: $1"
    exit 1
  }
}

need_repo() {
  local name="$1"
  [[ -d "$ROOT/$name" ]] || {
    echo "缺少源码目录: $ROOT/$name"
    echo "请先运行 ./update.sh"
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
      echo "工具不存在或不可执行: $val"
      exit 1
    }
    printf '%s\n' "$val"
  else
    command -v "$val" >/dev/null 2>&1 || {
      echo "找不到工具: $val"
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
  echo "找不到工具: $*" >&2
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
    echo "FFmpeg configure $list_cmd 中不存在: $name"
    exit 1
  }
}

find_cuda_home() {
  if [[ -d "$CUDA_REDIST_ROOT" && -x "$CUDA_REDIST_ROOT/bin/nvcc" ]]; then
    CUDA_HOME="$CUDA_REDIST_ROOT"
    return 0
  fi

  if [[ -n "$CUDA_HOME" ]]; then
    [[ -d "$CUDA_HOME" ]] || {
      echo "CUDA_HOME 不存在: $CUDA_HOME"
      exit 1
    }
    return 0
  fi

  if [[ -d /usr/local/cuda ]]; then
    CUDA_HOME="/usr/local/cuda"
    return 0
  fi

  local latest=""
  latest="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$latest" ]]; then
    CUDA_HOME="$latest"
    return 0
  fi

  echo "未找到 CUDA Toolkit。请先解包 NVIDIA redistrib 到 $CUDA_REDIST_ROOT，或设置 CUDA_HOME=/usr/local/cuda-13.3"
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

  if [[ -z "$NVCC" ]]; then
    NVCC="$CUDA_HOME/bin/nvcc"
  fi
  NVCC="$(canonical_tool "$NVCC")"

  [[ -f "$CUDA_HOME/include/cuda.h" ]] || {
    echo "缺少 CUDA 头文件: $CUDA_HOME/include/cuda.h"
    exit 1
  }

  "$NVCC" --version >/dev/null || {
    echo "nvcc 无法运行: $NVCC"
    exit 1
  }

  export NVCC
}

make_nvccflags() {
  local flags="$NVCC_GENCODE_FLAGS $NVCC_OPTFLAGS"
  if [[ -n "$NVCC_THREADS" ]]; then
    flags+=" --threads=$NVCC_THREADS"
  fi
  if [[ -n "$NVCC_PTXAS_FLAGS" ]]; then
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

  if [[ -n "$CPU_FLAGS" ]]; then
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
    echo "当前编译器不支持 CPU/LTO 参数:"
    echo "  CFLAGS=$CFLAGS"
    echo "可临时退回更保守参数，例如："
    echo '  CPU_FLAGS="-march=x86-64-v2 -mtune=generic" ./build.sh --ffmpeg'
    echo '  LTO_ENABLE=0 ./build.sh --ffmpeg'
    exit 1
  }
  rm -f "$tmp"
}



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

  grep -q '^CONFIG_HEVC_NVENC_ENCODER=yes$' "$config_mak" || { echo "异常：hevc_nvenc 未启用"; exit 1; }
  grep -q '^CONFIG_AV1_NVENC_ENCODER=yes$' "$config_mak" || { echo "异常：av1_nvenc 未启用"; exit 1; }
  grep -q '^CONFIG_LIBFDK_AAC_ENCODER=yes$' "$config_mak" || { echo "异常：libfdk_aac encoder 未启用"; exit 1; }

  local allowed='CONFIG_(HEVC_NVENC|AV1_NVENC|LIBFDK_AAC|AAC_AT|WRAPPED_AVFRAME)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
  local unexpected
  unexpected="$(grep -E '^CONFIG_.*_ENCODER=yes$' "$config_mak" | grep -Ev "$allowed" || true)"
  if [[ -n "$unexpected" ]]; then
    echo "异常：发现目标外编码器仍被启用："
    printf '%s\n' "$unexpected"
    exit 1
  fi

  if grep -q '^CONFIG_LIBSVTAV1=yes$' "$config_mak" || grep -q '^CONFIG_LIBSVTAV1_ENCODER=yes$' "$config_mak"; then
    echo "异常：SVT-AV1 仍被启用"
    grep -E 'CONFIG_LIBSVTAV1' "$config_mak" || true
    exit 1
  fi

  # 验证只能启用白名单中的滤镜，且不应启用任何 NPP 滤镜和 libnpp 依赖
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
      
      # 检查是否在 ALLOWED_FILTERS 白名单中
      local found=0
      local allowed
      for allowed in "${ALLOWED_FILTERS[@]}"; do
        if [[ "$allowed" == "$filter_lower" ]]; then
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

  # 如果 CUDA_ENABLE=1，还需确保 CUDA 优先滤镜确实已启用 (若 ffmpeg configure 没报错的话)
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

    fdk-aac)
      build_autotools fdk-aac
      ;;

    AudioToolboxWrapper)
      if [[ "$AAC_AT_ENABLE" != "1" ]]; then
        echo "AudioToolboxWrapper (aac_at) is disabled via AAC_AT_ENABLE"
      else
        local atw_stage
        atw_stage="$(stage_src "AudioToolboxWrapper")"
        local bld="$BUILDROOT/AudioToolboxWrapper"
        rm -rf "$bld"
        cmake -S "$atw_stage" -B "$bld" -G Ninja \
          -DCMAKE_SYSTEM_NAME=Windows \
          -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
          -DCMAKE_C_COMPILER="$CC" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_C_FLAGS_RELEASE="$CFLAGS" \
          -DCMAKE_INSTALL_PREFIX="$PREFIX" \
          -DCMAKE_PREFIX_PATH="$PREFIX" \
          -DBUILD_SHARED_LIBS=OFF
        cmake --build "$bld" --parallel "$JOBS"
        
        mkdir -p "$PREFIX/lib" "$PREFIX/include"
        cp -f "$bld/libAudioToolboxWrapper.a" "$PREFIX/lib/"
        cp -rf "$atw_stage/include/"* "$PREFIX/include/"
      fi
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

    ffmpeg)
      # Reset configure file to start from a clean slate
      git -C "$ROOT/ffmpeg-source" checkout configure || true
      # Patch configure to use -fatbin instead of -ptx for NVCC compilation to support multiple GPU architectures
      sed -i 's/nvccflags="$nvccflags -ptx"/nvccflags="$nvccflags -fatbin"/g' "$ROOT/ffmpeg-source/configure"

      local ff_bld="$BUILDROOT/ffmpeg"
      rm -rf "$ff_bld"
      mkdir -p "$ff_bld"
      pushd "$ff_bld" >/dev/null
      unset MAKEFILES MAKEFLAGS MFLAGS GNUMAKEFLAGS

      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "缺少 ffnvcodec，请先运行: ./build.sh --nv-codec-headers"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists fdk-aac || {
        echo "缺少 fdk-aac，请先运行: ./build.sh --fdk-aac"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists dav1d || {
        echo "缺少 dav1d，请先运行: ./build.sh --dav1d"
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
      require_config_item --list-encoders libfdk_aac

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
        --enable-libfdk-aac
        --enable-libzimg
        --enable-libdav1d
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

      # 编码器白名单 (仅允许指定的音视频编码器，无任何图片编码器)
      configure_cmd+=(--disable-encoders)
      add_if_exists --list-encoders hevc_nvenc --enable-encoder
      add_if_exists --list-encoders av1_nvenc --enable-encoder
      add_if_exists --list-encoders libfdk_aac --enable-encoder
      add_if_exists --list-encoders wrapped_avframe --enable-encoder
      if [[ "$AAC_AT_ENABLE" == "1" ]]; then
        # 修改 configure 脚本使 MinGW 链接 AudioToolboxWrapper
        sed -i 's/enabled audiotoolbox && check_apple_framework AudioToolbox/enabled audiotoolbox \&\& \{ check_apple_framework AudioToolbox || check_lib audiotoolbox "AudioToolbox\/AudioToolbox.h" AudioFormatGetProperty -lAudioToolboxWrapper; \}/g' "$ROOT/ffmpeg-source/configure"
        sed -i 's/check_type AudioToolbox\/AudioToolbox.h AudioObjectPropertyAddress/check_type AudioToolbox\/AudioToolbox.h AudioObjectPropertyAddress || true/g' "$ROOT/ffmpeg-source/configure"
        add_if_exists --list-encoders aac_at --enable-encoder
        configure_cmd+=(--enable-audiotoolbox)
      fi

      # 解码器白名单
      configure_cmd+=(--disable-decoders)
      local video_decoders=(
        h264 hevc av1 vp9 vp8 mpeg2video mpeg4 msmpeg4v3 vc1 wmv3 prores dnxhd cfhd mjpeg jpeg2000 png webp bmp tiff gif rawvideo wrapped_avframe libdav1d
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
        matroska mov mpegts h264 hevc av1 rawvideo image2 concat aac mp3 flac ogg wav
      )
      local dem
      for dem in "${demuxers[@]}"; do
        add_if_exists --list-demuxers "$dem" --enable-demuxer
      done

      # 复用器 (Muxers) 白名单
      configure_cmd+=(--disable-muxers)
      local muxers=(
        matroska mp4 mpegts null rawvideo image2 adts flac ogg wav
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
        # 如果禁用 CUDA，跳过 *_cuda 滤镜和 hwupload_cuda
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
      grep -E '^CONFIG_(HEVC_NVENC|AV1_NVENC|LIBFDK_AAC|AAC_AT)_ENCODER=yes$' ffbuild/config.mak || true
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
      cp -f "$PREFIX/bin/ffmpeg.exe" "$ROOT/ffmpeg.exe"

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

export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"

need_cmd python3
need_cmd git
need_cmd cmake
need_cmd meson
need_cmd ninja
need_cmd make
need_cmd autoreconf
need_cmd pkg-config
need_cmd grep
need_cmd tr

setup_cuda
make_common_flags

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

check_cpu_flags

mkdir -p "$BUILDROOT"
write_meson_cross

if [[ "$FULL_BUILD" -eq 1 ]]; then
  rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"
fi

for repo in nv-codec-headers fdk-aac zimg ffmpeg-source AudioToolboxWrapper dav1d; do
  need_repo "$repo"
done

echo "优化参数 CFLAGS=$CFLAGS"
echo "优化参数 CXXFLAGS=$CXXFLAGS"
echo "优化参数 LDFLAGS=$LDFLAGS"
echo "LTO_ENABLE=$LTO_ENABLE"
echo "JOBS=$JOBS"
echo "FFMPEG_JOBS=$FFMPEG_JOBS"

RUN=0
for stage in "${STAGES[@]}"; do
  if [[ "$FULL_BUILD" -eq 1 ]]; then
    RUN=1
  elif [[ "$stage" == "$START_STAGE" ]]; then
    RUN=1
  fi

  if [[ "$RUN" -eq 1 ]]; then
    run_stage "$stage"
  fi
done

CURRENT_STAGE=""
echo
echo "============================================================"
echo "构建完成"
echo "最终输出: $ROOT/ffmpeg.exe"
echo "FFmpeg configure 参数记录: $BUILDROOT/ffmpeg-configure.args"
echo "============================================================"
