#!/usr/bin/env bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8
set -Eeuo pipefail

# Code paths must not be derived from an overridable workspace ROOT.
LITE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITE_RECIPE_SCRIPT="$LITE_SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
source "$LITE_SCRIPT_DIR/../lib/workspace.sh"
BACKEND="${BACKEND:-nvenc}"
case "$BACKEND" in
  nvenc|qsv) ;;
  *) echo "Set BACKEND=nvenc|qsv" >&2; exit 1 ;;
esac
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/$BACKEND}"
PREFIX="${PREFIX:-$ROOT/bin_$BACKEND}"
BUILDROOT="${BUILDROOT:-$ROOT/build_$BACKEND}"
HOST_TOOLS="${HOST_TOOLS:-$BUILDROOT/host-tools}"
HOST_GLSLC="${HOST_GLSLC:-$HOST_TOOLS/bin/glslc}"
COMMON_PREFIX="${COMMON_PREFIX:-$ROOT/bin}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
LLVM_MINGW_ROOT="${LLVM_MINGW_ROOT:-/usr/local/llvm-mingw}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"
FFMPEG_REF="${FFMPEG_REF:-master}"
LTO_ENABLE="${LTO_ENABLE:-1}"
CFG_ENABLE="${CFG_ENABLE:-1}"
LTO_FLAGS="${LTO_FLAGS:--flto=thin}"
CPU_FLAGS="${CPU_FLAGS:--march=x86-64-v3 -mtune=generic}"
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O3 -pipe -DNDEBUG -funwind-tables -fexceptions}"

CUDA_ENABLE="${CUDA_ENABLE:-1}"
CUDA_HOME="${CUDA_HOME:-}"
NVCC="${NVCC:-}"
NVCC_GENCODE_FLAGS="${NVCC_GENCODE_FLAGS:--gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120}"
NVCC_OPTFLAGS="${NVCC_OPTFLAGS:--O3 --extra-device-vectorization}"
NVCC_PTXAS_FLAGS="${NVCC_PTXAS_FLAGS:--O3}"
NVCC_FAST_MATH="${NVCC_FAST_MATH:-1}"
NVCC_THREADS="${NVCC_THREADS:-0}"

declare -A URLS=(
  [ffmpeg-source]="https://github.com/FFmpeg/FFmpeg.git"
  [nv-codec-headers]="https://github.com/FFmpeg/nv-codec-headers.git"
  [opus]="https://github.com/xiph/opus.git"
  [libvpl]="https://github.com/intel/libvpl.git"
  [libsoxr]="https://github.com/chirlu/soxr.git"
  [libshaderc]="https://github.com/google/shaderc.git"
  [vulkan-headers]="https://github.com/KhronosGroup/Vulkan-Headers.git"
  [libplacebo]="https://github.com/haasn/libplacebo.git"
  [lcms2]="https://github.com/mm2/Little-CMS.git"
)

declare -A TAG_REGEX=(
  [ffmpeg-source]='master'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [opus]='^v?[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [libsoxr]='^v?[0-9]+(\.[0-9]+)*$'
  [libshaderc]='^v[0-9]+\.[0-9]+$'
  [vulkan-headers]='^v[0-9]+(\.[0-9]+)*$'
  [libplacebo]='^v[0-9]+(\.[0-9]+)*$'
  [lcms2]='^lcms[0-9]+(\.[0-9]+)*$'
)

COMMON_STAGES=(opus libsoxr libshaderc vulkan-headers lcms2 libplacebo)
if [[ "$BACKEND" == "nvenc" ]]; then
  STAGES=(nv-codec-headers "${COMMON_STAGES[@]}" ffmpeg)
else
  STAGES=(libvpl "${COMMON_STAGES[@]}" ffmpeg)
fi

COMMON_FILTERS=(
  # 最新上游 ffmpeg 前端会强制选择 alphamerge，保留严格白名单并纳入该依赖。
  buffer buffersink abuffer abuffersink format aformat alphamerge null anull
  fps trim atrim setpts asetpts settb asettb setparams setsar
  crop hflip vflip transpose rotate scale aresample
  hwupload hwdownload hwmap libplacebo iccdetect iccgen
)
NVENC_FILTERS=(scale_cuda overlay_cuda pad_cuda colorspace_cuda yadif_cuda bwdif_cuda bilateral_cuda chromakey_cuda thumbnail_cuda transpose_cuda hwupload_cuda)
QSV_FILTERS=(scale_qsv vpp_qsv deinterlace_qsv overlay_qsv hstack_qsv vstack_qsv xstack_qsv)

CURRENT_STAGE=""
SKIPPED_ITEMS=()
BUILD_STARTED_AT=""
HARDWARE_STATUS="not-run"

source "$LITE_SCRIPT_DIR/../lib/lite-common.sh"

verify_nvenc_hierarchical() {
  local exe="$1" test_dir
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    HARDWARE_STATUS="skipped"
    echo "Skipped NVENC hierarchical B-reference runtime test: no NVIDIA GPU"
    return 0
  fi
  lite_assert_generated_directory "$BUILDROOT" || return 1
  mkdir -p "$BUILDROOT" || return 1
  test_dir="$(mktemp -d "$BUILDROOT/nvenc-validation.XXXXXX")" || return 1
  dd if=/dev/zero of="$test_dir/input.yuv" bs=393216 count=8 status=none || return 1
  local input_file="$test_dir/input.yuv"
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    input_file="$(wslpath -w "$input_file")"
  fi
  "$exe" -nostdin -hide_banner -loglevel error \
    -f rawvideo -pix_fmt yuv420p -s:v 512x512 -r 1 -i "$input_file" \
    -frames:v 8 -c:v av1_nvenc -g 8 -bf 3 -b_ref_mode hierarchical -f null - || return 1
  HARDWARE_STATUS="passed"
  echo "NVENC AV1 hierarchical B-reference runtime invocation: OK"
}

write_build_manifest() {
  local manifest_tool="$FFBUILD_CODE_ROOT/build-manifests/write_manifest.py"
  local args=(
    python3 -I "$manifest_tool"
    --root "$ROOT"
    --build-name "$BACKEND-lite"
    --prefix "$PREFIX"
    --artifact-dir "$OUTPUT_DIR"
    --configure-file "$BUILDROOT/ffmpeg-configure.args"
    --config-mak "${FFMPEG_BUILD_DIR:-$BUILDROOT/ffmpeg}/ffbuild/config.mak"
    --started "$BUILD_STARTED_AT"
    --target-platform "Windows x86_64 via $TARGET"
    --cpu-minimum "$CPU_FLAGS"
  )
  lite_manifest_args || return 1
  if [[ "$LITE_FFMPEG_BUILT" == 1 ]]; then
  args+=(
    --validate "target-prefix opus.pc, opus headers, and static libopus checked"
    --skip "Non-upstream FFmpeg feature patches are not applied; only build/link compatibility patches are retained"
    --validate "FFmpeg configure enabled libopus, libopus encoder, and native opus decoder"
    --validate "final encoder whitelist contains AAC, libopus, and only expected video encoders"
    --validate "48 kHz stereo Ogg Opus encode and final-ffmpeg decode/re-encode roundtrip succeeded"
    --validate "native NMR AAC option remains present"
    --validate "Native AVS1 decoders included; external AVS2/3 codecs and AVS encoders excluded; Audio Vivid/AV3A unavailable"
    --validate "FFmpeg mainline HEVC decoding includes ITU-T T.35 HDR Vivid frame metadata parsing; HDR Vivid generation/encoding is unavailable"
  )
  if [[ "$HARDWARE_STATUS" == "passed" ]]; then
    args+=(--validate "AV1 NVENC hierarchical B-reference option present and runtime invocation succeeded; bitstream B-frame production not independently confirmed")
  else
    args+=(--skip "AV1 NVENC hierarchical B-reference runtime encode skipped because no NVIDIA GPU was available")
  fi
  else
    args+=(--skip "Cached FFmpeg reused; config, runtime Opus and hardware validations were not rerun")
  fi
  local manifest
  manifest="$("${args[@]}")" || return 1
  lite_finish_manifest "$manifest" || return 1
  echo "Build source manifest written for $BACKEND-lite"
}

run_stage_recipe() {
  local stage="$1"
  unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
  CURRENT_STAGE="$stage"
  echo "===> $stage"
  case "$stage" in
    nv-codec-headers)
      local s
      s="$(stage_src nv-codec-headers)" || return 1
      make -j"$JOBS" -C "$s" PREFIX="$PREFIX" || return 1
      make -j"$JOBS" -C "$s" PREFIX="$PREFIX" install || return 1
      local api_header="$PREFIX/include/ffnvcodec/nvEncodeAPI.h"
      local api_major api_minor
      api_major="$(sed -n 's/^#define NVENCAPI_MAJOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      api_minor="$(sed -n 's/^#define NVENCAPI_MINOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      ((api_major > 13 || (api_major == 13 && api_minor >= 1))) || {
        echo "NVENC API $api_major.$api_minor is below required 13.1"
        exit 1
      }
      ;;

    libvpl)
      build_cmake libvpl -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DINSTALL_EXAMPLES=OFF -DENABLE_WARNINGS=OFF || return 1
      ;;

    ffmpeg)
      # Host/CUDA and direct-dependency identities were resolved by run_stage.
      "$PKG_CONFIG" --static --exists soxr libplacebo shaderc vulkan lcms2 || { echo "required pkg-config files missing"; return 1; }
      [[ "$BACKEND" == "qsv" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vpl || { [[ "$BACKEND" == "nvenc" ]] || exit 1; }
      [[ "$BACKEND" == "nvenc" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || { [[ "$BACKEND" == "qsv" ]] || exit 1; }

      local ff_stage ff_bld extra_cflags extra_ldflags extra_libs ffmpeg_nvccflags dep_prefix
      dep_prefix="$(lite_dependency_prefix)" || return 1
      ff_stage="$(stage_src ffmpeg-source)" || return 1
      "$FFBUILD_CODE_ROOT/shared-patches/apply-ffmpeg-patches.sh" "$ff_stage" lite || return 1
      python3 -I "$FFBUILD_CODE_ROOT/scripts/lib/feature_policy.py" ffmpeg-source "$ff_stage" || return 1
      python3 -I "$FFBUILD_CODE_ROOT/scripts/lib/feature_policy.py" ffmpeg-restricted-cli "$ff_stage" || return 1
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage" || return 1
      ff_bld="$(lite_build_directory ffmpeg)" || return 1
      mkdir -p "$ff_bld" || return 1
      pushd "$ff_bld" >/dev/null || return 1
      unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES

      extra_cflags="-I$PREFIX/include"
      extra_ldflags="-L$PREFIX/lib $LDFLAGS"
      if [[ "$dep_prefix" != "$PREFIX" ]]; then
        extra_cflags="-I$dep_prefix/include $extra_cflags"
        extra_ldflags="-L$dep_prefix/lib $extra_ldflags"
      fi
      extra_libs="-lvulkan-1 -lshlwapi -lpthread"
      configure_cmd=(
        "$ff_stage/configure"
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
        --ranlib="$RANLIB"
        --pkg-config="$PKG_CONFIG"
        --pkg-config-flags=--static
        --optflags="$CFLAGS"
        --extra-cflags="$extra_cflags"
        --extra-cxxflags="$CXXFLAGS"
        --extra-ldflags="$extra_ldflags"
        --extra-libs="$extra_libs"
        --disable-autodetect
        --disable-shared
        --enable-static
        --disable-debug
        --disable-doc
        --disable-programs
        --enable-ffmpeg
        --disable-ffprobe
        --disable-ffplay
        --disable-network
        --enable-w32threads
        --disable-pthreads
        --enable-libopus
        --enable-libsoxr
        --enable-vulkan
        --enable-vulkan-static
        --enable-libplacebo
        --enable-lcms2
        --disable-opencl
        --enable-lto=thin
      )

      if [[ "$BACKEND" == "nvenc" ]]; then
        extra_cflags+=" -I$CUDA_HOME/include -I$CUDA_HOME/targets/x86_64-linux/include"
        ffmpeg_nvccflags="$(make_nvccflags | sed 's/-gencode arch=[^ ]*,code=[^ ]*//g' | xargs) -gencode arch=compute_75,code=compute_75"
        configure_cmd+=(
          --extra-cflags="$extra_cflags"
          --enable-nonfree
          --enable-ffnvcodec
          --enable-nvenc
          --enable-nvdec
          --enable-cuda
          --enable-cuda-nvcc
          --disable-cuda-llvm
          --nvcc="$NVCC"
          --nvccflags="$ffmpeg_nvccflags"
          --glslc="$HOST_GLSLC"
        )
      else
        configure_cmd+=(--enable-libvpl --enable-d3d11va --enable-d3d12va --disable-dxva2)
      fi

      configure_cmd+=(--disable-encoders)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for e in hevc_nvenc av1_nvenc aac libopus rawvideo; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      else
        for e in hevc_qsv av1_qsv aac libopus rawvideo; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      fi

      configure_cmd+=(--disable-decoders)
      for d in avs cavs h264 hevc av1 vp9 vp8 mpeg2video mpeg4 msmpeg4v3 vc1 wmv3 mjpeg prores rawvideo aac aac_latm mp3 ac3 eac3 truehd dca flac opus vorbis wavpack alac pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le; do
        add_if_exists "$ff_stage" --list-decoders "$d" --enable-decoder
      done

      configure_cmd+=(--disable-hwaccels)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for h in h264_nvdec hevc_nvdec av1_nvdec vp9_nvdec vp8_nvdec mjpeg_nvdec mpeg2_nvdec mpeg4_nvdec vc1_nvdec wmv3_nvdec; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      else
        for h in h264_d3d11va hevc_d3d11va av1_d3d11va vp9_d3d11va vc1_d3d11va mpeg2_d3d11va h264_d3d12va hevc_d3d12va av1_d3d12va vp9_d3d12va vc1_d3d12va mpeg2_d3d12va; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      fi

      configure_cmd+=(--disable-demuxers)
      for d in matroska mov mpegts h264 hevc av1 rawvideo pcm_s16le image2 concat aac mp3 flac ogg wav; do add_if_exists "$ff_stage" --list-demuxers "$d" --enable-demuxer; done
      configure_cmd+=(--disable-muxers)
      for m in matroska mp4 mov ipod mpegts null rawvideo image2 adts wav flac ogg; do add_if_exists "$ff_stage" --list-muxers "$m" --enable-muxer; done
      configure_cmd+=(--disable-parsers)
      for p in cavsvideo h264 hevc av1 aac ac3 dca mlp opus vorbis mjpeg vp9 vp8 mpeg4video vc1; do add_if_exists "$ff_stage" --list-parsers "$p" --enable-parser; done
      configure_cmd+=(--disable-bsfs)
      for b in h264_mp4toannexb hevc_mp4toannexb av1_metadata h264_metadata hevc_metadata aac_adtstoasc extract_extradata dovi_rpu dovi_split; do add_if_exists "$ff_stage" --list-bsfs "$b" --enable-bsf; done
      configure_cmd+=(--disable-protocols)
      for p in file pipe; do add_if_exists "$ff_stage" --list-protocols "$p" --enable-protocol; done
      configure_cmd+=(--disable-devices)
      configure_cmd+=(--disable-filters)
      for f in "${COMMON_FILTERS[@]}"; do add_if_exists "$ff_stage" --list-filters "$f" --enable-filter; done
      if [[ "$BACKEND" == "nvenc" ]]; then
        for f in "${NVENC_FILTERS[@]}"; do add_if_exists "$ff_stage" --list-filters "$f" --enable-filter; done
      else
        for f in "${QSV_FILTERS[@]}"; do add_if_exists "$ff_stage" --list-filters "$f" --enable-filter; done
      fi

      local policy_flags_text
      policy_flags_text="$(python3 -I "$FFBUILD_CODE_ROOT/scripts/lib/feature_policy.py" ffmpeg-flags "$ff_stage")" || return 1
      local -a policy_flags=()
      mapfile -t policy_flags <<< "$policy_flags_text"
      configure_cmd+=("${policy_flags[@]}")
      printf '%s\n' "${configure_cmd[@]}" > "$BUILDROOT/ffmpeg-configure.args" || return 1
      printf '%q ' "${configure_cmd[@]}"; echo
      "${configure_cmd[@]}" || return 1
      validate_config ffbuild/config.mak config.h "$ff_stage" || return 1
      mkdir -p libswscale/x86 || return 1
      # A changed dependency/configuration selects a fresh sibling build tree;
      # source-only edits retain make's objects and timestamp dependencies.
      make -f ./Makefile -j"$FFMPEG_JOBS" || return 1
      make -f ./Makefile -j"$FFMPEG_JOBS" install || return 1
      lite_assert_installed_copy "$ff_bld/ffmpeg.exe" "$PREFIX/bin/ffmpeg.exe" || return 1
      popd >/dev/null || return 1
      [[ -f "$PREFIX/bin/ffmpeg.exe" ]] || { echo "ffmpeg.exe not produced"; exit 1; }
      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || return 1
      cp -f "$PREFIX/bin/ffmpeg.exe" "$OUTPUT_DIR/ffmpeg.exe" || return 1
      check_single_file_imports "$OUTPUT_DIR/ffmpeg.exe" || return 1
      verify_lite_binary "$OUTPUT_DIR/ffmpeg.exe" || return 1
      verify_opus_roundtrip "$OUTPUT_DIR/ffmpeg.exe" || return 1
      verify_nvenc_hierarchical "$OUTPUT_DIR/ffmpeg.exe" || return 1
      ;;

    *) run_lite_common_recipe "$stage" || return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  lite_main "$@"
fi
