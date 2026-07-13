#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="${BACKEND:-$(basename "$SCRIPT_DIR")}" # nvenc or qsv
case "$BACKEND" in
  nvenc|qsv) ;;
  *) echo "Run from ~/ffmpeg/nvenc or ~/ffmpeg/qsv, or set BACKEND=nvenc|qsv"; exit 1 ;;
esac

ROOT="${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PREFIX="${PREFIX:-$ROOT/bin_$BACKEND}"
BUILDROOT="${BUILDROOT:-$ROOT/build_$BACKEND}"
COMMON_PREFIX="${COMMON_PREFIX:-$ROOT/bin}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
LLVM_MINGW_ROOT="${LLVM_MINGW_ROOT:-/usr/local/llvm-mingw}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"
FFMPEG_REF="${FFMPEG_REF:-master}"
LTO_ENABLE="${LTO_ENABLE:-1}"
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
  [libvpl]="https://github.com/intel/libvpl.git"
  [libsoxr]="https://github.com/chirlu/soxr.git"
  [vapoursynth]="https://github.com/vapoursynth/vapoursynth.git"
  [libshaderc]="https://github.com/google/shaderc.git"
  [vulkan-headers]="https://github.com/KhronosGroup/Vulkan-Headers.git"
  [libplacebo]="https://github.com/haasn/libplacebo.git"
)

declare -A TAG_REGEX=(
  [ffmpeg-source]='master'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [libsoxr]='^v?[0-9]+(\.[0-9]+)*$'
  [vapoursynth]='^R[0-9]+(\.[0-9]+)*$'
  [libshaderc]='^v[0-9]+\.[0-9]+$'
  [vulkan-headers]='^v[0-9]+(\.[0-9]+)*$'
  [libplacebo]='^v[0-9]+(\.[0-9]+)*$'
)

COMMON_STAGES=(libsoxr libshaderc vulkan-headers libplacebo)
if [[ "$BACKEND" == "nvenc" ]]; then
  STAGES=(nv-codec-headers vapoursynth "${COMMON_STAGES[@]}" ffmpeg)
else
  STAGES=(libvpl "${COMMON_STAGES[@]}" ffmpeg)
fi

COMMON_FILTERS=(
  buffer buffersink abuffer abuffersink format aformat null anull
  fps trim atrim setpts asetpts settb asettb setparams setsar
  crop hflip vflip transpose rotate scale aresample
  hwupload hwdownload hwmap libplacebo
)
NVENC_FILTERS=(scale_cuda overlay_cuda pad_cuda colorspace_cuda yadif_cuda bwdif_cuda bilateral_cuda chromakey_cuda thumbnail_cuda transpose_cuda hwupload_cuda)
QSV_FILTERS=(scale_qsv vpp_qsv deinterlace_qsv overlay_qsv hstack_qsv vstack_qsv xstack_qsv)

CURRENT_STAGE=""
SKIPPED_ITEMS=()

usage() {
  cat <<EOF
Usage:
  ./ffmpeg.sh                    update sources, then build
  ./ffmpeg.sh all                update sources, then build
  ./ffmpeg.sh build              build $BACKEND lite ffmpeg.exe from local sources
  ./ffmpeg.sh build ffmpeg       rebuild from ffmpeg stage
  ./ffmpeg.sh update             update only the source repos used by this backend
  ./ffmpeg.sh clean              remove $PREFIX and $BUILDROOT

Output:
  $SCRIPT_DIR/ffmpeg.exe

Native AAC NMR:
  -c:a aac -profile:a aac_low -aac_coder nmr -aac_nmr_speed 0
EOF
}

on_error() {
  local code=$?
  echo
  echo "============================================================"
  echo "Build failed: ${CURRENT_STAGE:-unknown} (exit=$code)"
  [[ -n "${CURRENT_STAGE:-}" ]] && echo "Resume with: ./ffmpeg.sh build $CURRENT_STAGE"
  echo "============================================================"
  exit "$code"
}
trap on_error ERR

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }; }

git_retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if (( attempt % 2 == 1 )); then
      "$@" && return 0
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy "$@" && return 0
    fi
    echo "git command failed ($attempt/4), retrying..." >&2
    sleep "$((attempt * 5))"
  done
  return 1
}

canonical_tool() {
  local v="$1"
  if [[ "$v" == */* ]]; then
    [[ -x "$v" ]] || { echo "tool not executable: $v"; exit 1; }
    printf '%s\n' "$v"
  else
    command -v "$v" >/dev/null 2>&1 || { echo "tool not found: $v"; exit 1; }
    command -v "$v"
  fi
}

first_tool() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 && { command -v "$t"; return 0; }
  done
  echo "tool not found: $*" >&2
  exit 1
}

verify_managed_toolchain() {
  local marker="$LLVM_MINGW_ROOT/.asset_url" expected
  [[ -f "$marker" ]] || { echo "managed llvm-mingw missing; run ../full/ffmpeg.sh tool"; exit 1; }
  expected="$(python3 - <<'PY'
import json, re, time, urllib.request
for attempt in range(4):
    try:
        with urllib.request.urlopen('https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest', timeout=60) as r:
            data = json.load(r)
        break
    except Exception:
        if attempt == 3:
            raise
        time.sleep(5 * (attempt + 1))
rx = re.compile(r'^llvm-mingw-.*-ucrt-ubuntu-22\.04-x86_64\.tar\.xz$')
for asset in data.get('assets', []):
    if rx.match(asset['name']):
        print(asset['browser_download_url'])
        break
else:
    raise SystemExit('latest llvm-mingw Linux asset not found')
PY
)"
  [[ "$(cat "$marker")" == "$expected" ]] || { echo "llvm-mingw is stale; run ../full/ffmpeg.sh tool"; exit 1; }
  [[ -f /usr/local/cmake/.asset_url && -f /usr/local/ninja/.asset_url && -f /usr/local/nasm/.tag ]] || {
    echo "managed CMake/Ninja/NASM markers are missing; run ../full/ffmpeg.sh tool"
    exit 1
  }
}

source_dir() {
  local name="$1"
  case "$name" in
    libsoxr)
      [[ -d "$ROOT/libsoxr/.git" ]] && { printf '%s\n' "$ROOT/libsoxr"; return 0; }
      [[ -d "$ROOT/soxr/.git" ]] && { printf '%s\n' "$ROOT/soxr"; return 0; }
      ;;
    *) [[ -d "$ROOT/$name/.git" ]] && { printf '%s\n' "$ROOT/$name"; return 0; } ;;
  esac
  return 1
}

need_repo() {
  source_dir "$1" >/dev/null || { echo "missing source repo: $1 under $ROOT; run ./ffmpeg.sh update first"; exit 1; }
}

normalize_version() {
  local repo="$1" tag="$2"
  case "$repo" in
    ffmpeg-source|nv-codec-headers) echo "${tag#n}" ;;
    *) echo "${tag#v}" ;;
  esac
}

latest_stable_tag() {
  local name="$1" repo_dir regex
  repo_dir="$(source_dir "$name")"
  regex="${TAG_REGEX[$name]}"
  git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/tags \
    | sed 's/\^{}$//' \
    | sort -u \
    | { grep -E "$regex" || true; } \
    | while read -r tag; do printf "%s\t%s\n" "$(normalize_version "$name" "$tag")" "$tag"; done \
    | sort -V \
    | tail -n 1 \
    | cut -f2
}

clone_if_missing() {
  local name="$1" dir="$ROOT/$name"
  if ! source_dir "$name" >/dev/null; then
    echo "===> clone $name"
    git_retry git clone --filter=blob:none "${URLS[$name]}" "$dir"
  fi
}

update_one() {
  local name="$1" dir ref
  clone_if_missing "$name"
  dir="$(source_dir "$name")"
  git -C "$dir" reset --hard
  git -C "$dir" clean -fdx
  git -C "$dir" remote set-url origin "${URLS[$name]}" 2>/dev/null || true
  git_retry git -C "$dir" fetch --tags --prune --force origin
  if [[ "$name" == "ffmpeg-source" ]]; then
    ref="$FFMPEG_REF"
    git -C "$dir" checkout "$ref" 2>/dev/null || git -C "$dir" switch "$ref"
    git_retry git -C "$dir" pull --ff-only origin "$ref"
  else
    ref="$(latest_stable_tag "$name")"
    [[ -n "$ref" ]] || ref="master"
    git -C "$dir" switch --detach "$ref" 2>/dev/null || git -C "$dir" checkout --detach "$ref"
  fi
  git -C "$dir" submodule update --init --recursive || true
  echo "     -> $name $(git -C "$dir" rev-parse --short HEAD)"
}

run_update() {
  local r repos=(ffmpeg-source "${STAGES[@]}")
  for r in "${repos[@]}"; do
    [[ "$r" == "ffmpeg" ]] && continue
    update_one "$r"
  done
  echo "== Source version manifest =="
  for r in "${repos[@]}"; do
    [[ "$r" == "ffmpeg" ]] && continue
    local dir
    dir="$(source_dir "$r")"
    printf '%-24s ref=%-20s commit=%s\n' "$r" \
      "$(git -C "$dir" describe --tags --always)" \
      "$(git -C "$dir" rev-parse --short=12 HEAD)"
  done
}

meson_quote_array() {
  local flags="$1" arr=() f first=1
  read -r -a arr <<< "$flags"
  printf '['
  for f in "${arr[@]}"; do
    [[ -z "$f" ]] && continue
    f="${f//\\/\\\\}"; f="${f//\'/\\\'}"
    [[ "$first" -eq 0 ]] && printf ', '
    printf "'%s'" "$f"
    first=0
  done
  printf ']'
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

[built-in options]
c_args = $(meson_quote_array "$CFLAGS -I$PREFIX/include")
cpp_args = $(meson_quote_array "$CXXFLAGS -I$PREFIX/include")
c_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
cpp_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
optimization = '3'
b_lto = $meson_lto

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

setup_build_env() {
  export PATH="$LLVM_MINGW_ROOT/bin:/usr/local/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
  need_cmd git; need_cmd cmake; need_cmd meson; need_cmd ninja; need_cmd make; need_cmd pkg-config; need_cmd python3
  verify_managed_toolchain
  CC="$(canonical_tool "${CC:-$TARGET-clang}")"
  CXX="$(canonical_tool "${CXX:-$TARGET-clang++}")"
  AR="$(canonical_tool "${AR:-llvm-ar}")"
  RANLIB="$(canonical_tool "${RANLIB:-llvm-ranlib}")"
  STRIP="$(canonical_tool "${STRIP:-llvm-strip}")"
  WINDRES="$(first_tool "${WINDRES:-$TARGET-windres}" llvm-windres)"
  DLLTOOL="$(first_tool "${DLLTOOL:-$TARGET-dlltool}" llvm-dlltool)"
  PKG_CONFIG="$(canonical_tool "${PKG_CONFIG:-pkg-config}")"

  local opt="$OPT_CFLAGS_BASE $CPU_FLAGS -ffunction-sections -fdata-sections"
  local ld="-static -Wl,--gc-sections -fuse-ld=lld"
  if [[ "$LTO_ENABLE" == "1" ]]; then
    opt+=" $LTO_FLAGS"
    ld+=" $LTO_FLAGS"
  fi
  export CC CXX AR RANLIB STRIP WINDRES DLLTOOL PKG_CONFIG
  export CFLAGS="${CFLAGS:-$opt}"
  export CXXFLAGS="${CXXFLAGS:-$opt}"
  export LDFLAGS="${LDFLAGS:-$ld}"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

  mkdir -p "$BUILDROOT" "$PREFIX"
  write_meson_cross
}

stage_src() {
  local name="$1" src stage
  src="$(source_dir "$name")"
  stage="$BUILDROOT/_src/$name"
  rm -rf "$stage"
  mkdir -p "$(dirname "$stage")"
  cp -a "$src" "$stage"
  echo "$stage"
}

build_cmake() {
  local name="$1" stage bld ipo=OFF
  shift
  stage="$(stage_src "$name")"
  bld="$BUILDROOT/$name"
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

have_config_item() {
  local ff_stage="$1" list_cmd="$2" name="$3"
  "$ff_stage/configure" "$list_cmd" | tr '[:space:]' '\n' | grep -Fx "$name" >/dev/null
}

add_if_exists() {
  local ff_stage="$1" list_cmd="$2" name="$3" flag="$4"
  if have_config_item "$ff_stage" "$list_cmd" "$name"; then
    configure_cmd+=("$flag=$name")
  else
    SKIPPED_ITEMS+=("$name ($list_cmd)")
    echo "WARNING: $name not found in $list_cmd, skipping"
  fi
}

find_cuda_home() {
  if [[ -n "${CUDA_HOME:-}" && -f "$CUDA_HOME/include/cuda.h" ]]; then return 0; fi
  if [[ -d /usr/local/cuda && -f /usr/local/cuda/include/cuda.h ]]; then CUDA_HOME=/usr/local/cuda; return 0; fi
  local latest
  latest="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' 2>/dev/null | sort -V | tail -n 1 || true)"
  [[ -n "$latest" && -f "$latest/include/cuda.h" ]] && { CUDA_HOME="$latest"; return 0; }
  echo "CUDA toolkit not found. Set CUDA_HOME=/usr/local/cuda or install cuda-toolkit."
  exit 1
}

setup_cuda() {
  [[ "$BACKEND" == "nvenc" && "$CUDA_ENABLE" == "1" ]] || return 0
  find_cuda_home
  export CUDA_HOME PATH="$CUDA_HOME/bin:$PATH"
  NVCC="$(canonical_tool "${NVCC:-$CUDA_HOME/bin/nvcc}")"
  "$NVCC" --version >/dev/null
  export NVCC
}

make_nvccflags() {
  local flags="$NVCC_GENCODE_FLAGS $NVCC_OPTFLAGS"
  [[ -n "$NVCC_THREADS" ]] && flags+=" --threads=$NVCC_THREADS"
  [[ -n "$NVCC_PTXAS_FLAGS" ]] && flags+=" -Xptxas=$NVCC_PTXAS_FLAGS"
  [[ "$NVCC_FAST_MATH" == "1" ]] && flags+=" --use_fast_math"
  printf '%s\n' "$flags"
}

write_soxr_pc() {
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/soxr.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: soxr
Description: SoX Resampler library
Version: 0.1.3
Libs: -L\${libdir} -lsoxr
Cflags: -I\${includedir}
EOF
}

write_shaderc_pc() {
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/shaderc.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: shaderc
Description: Shaderc static combined library
Version: 2026.2.1
Libs: -L\${libdir} -lshaderc_combined
Cflags: -I\${includedir}
EOF
}

seed_shaderc_from_common() {
  local spirv_include="$COMMON_PREFIX/include/spirv"
  [[ -d "$spirv_include" ]] || spirv_include="$ROOT/build/_src/libshaderc/third_party/spirv-headers/include/spirv"
  [[ -f "$COMMON_PREFIX/lib/libshaderc_combined.a" && -d "$COMMON_PREFIX/include/shaderc" && -d "$spirv_include" ]] || return 1
  echo "Using existing static shaderc from $COMMON_PREFIX"
  mkdir -p "$PREFIX/lib" "$PREFIX/include"
  cp -f "$COMMON_PREFIX/lib/libshaderc_combined.a" "$PREFIX/lib/"
  cp -a "$COMMON_PREFIX/include/shaderc" "$PREFIX/include/"
  cp -a "$spirv_include" "$PREFIX/include/"
  write_shaderc_pc
}

build_shaderc_from_source() {
  local stage bld
  stage="$(stage_src libshaderc)"
  if [[ ! -d "$stage/third_party/glslang" || ! -d "$stage/third_party/spirv-tools/external/spirv-headers" ]]; then
    seed_shaderc_from_common || {
      echo "libshaderc third_party deps are missing and $COMMON_PREFIX has no static shaderc."
      echo "Run ./ffmpeg.sh update or build full once, then retry."
      exit 1
    }
    return 0
  fi
  bld="$BUILDROOT/libshaderc"
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
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
  [[ -f "$PREFIX/lib/libshaderc_combined.a" ]] || cp -f "$bld/libshaderc/libshaderc_combined.a" "$PREFIX/lib/"
  [[ -d "$stage/third_party/spirv-headers/include/spirv" ]] || { echo "shaderc SPIR-V headers missing"; exit 1; }
  cp -a "$stage/third_party/spirv-headers/include/spirv" "$PREFIX/include/"
  write_shaderc_pc
}

patch_ffmpeg_libplacebo_vulkan_import() {
  local ff_stage="$1" cfg="$PREFIX/include/libplacebo/config.h" api
  sed -i 's/-lstdc++/-lc++/g' "$ff_stage/configure"
  [[ -f "$cfg" ]] || return 0
  api="$(sed -n 's/^#define PL_API_VER[[:space:]]\+\([0-9]\+\).*/\1/p' "$cfg" | head -n1)"
  [[ -n "$api" ]] || return 0
  if (( api >= 365 )); then return 0; fi
  echo "Patch FFmpeg Vulkan queue import for libplacebo API $api"
  perl -0pi -e 's/#ifdef VK_KHR_internally_synchronized_queues\n([[:space:]]*\{ VK_KHR_INTERNALLY_SYNCHRONIZED_QUEUES_EXTENSION_NAME,[[:space:]]*FF_VK_EXT_INTERNAL_QUEUE_SYNC[[:space:]]*\},\n)#endif/#if 0 \&\& defined(VK_KHR_internally_synchronized_queues)\n$1#endif/g' \
    "$ff_stage/libavutil/hwcontext_vulkan.c" \
    "$ff_stage/libavutil/vulkan_loader.h"
}

validate_config() {
  local config_mak="$1" config_h="$2" unexpected allowed filter_line filter_name filter_lower f found
  local allowed_filters=("${COMMON_FILTERS[@]}")
  if [[ "$BACKEND" == "nvenc" ]]; then
    allowed_filters+=("${NVENC_FILTERS[@]}")
  else
    allowed_filters+=("${QSV_FILTERS[@]}")
  fi
  [[ "$LTO_ENABLE" != "1" ]] || grep -Eq -- '-flto(=thin|=auto)?' "$config_mak" || { echo "LTO not found in config.mak"; exit 1; }
  grep -q '^CONFIG_AAC_ENCODER=yes$' "$config_mak" || { echo "native AAC encoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBSOXR=yes$' "$config_mak" || { echo "libsoxr disabled"; exit 1; }
  grep -q '^CONFIG_ARESAMPLE_FILTER=yes$' "$config_mak" || { echo "aresample filter disabled"; exit 1; }
  grep -q '^CONFIG_LIBPLACEBO_FILTER=yes$' "$config_mak" || { echo "libplacebo filter disabled"; exit 1; }
  grep -q '^CONFIG_VULKAN=yes$' "$config_mak" || { echo "Vulkan disabled"; exit 1; }
  grep -q '^CONFIG_LIBSHADERC=yes$' "$config_mak" || { echo "libshaderc disabled"; exit 1; }

  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '^CONFIG_AV1_NVENC_ENCODER=yes$' "$config_mak" || { echo "av1_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_NVENC_ENCODER=yes$' "$config_mak" || { echo "hevc_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_CUDA_NVCC=yes$' "$config_mak" || { echo "cuda-nvcc disabled"; exit 1; }
    allowed='CONFIG_(HEVC_NVENC|AV1_NVENC|AAC)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
    grep -q 'nonfree' "$config_h" || { echo "NVENC build is expected to be nonfree"; exit 1; }
  else
    grep -q '^CONFIG_AV1_QSV_ENCODER=yes$' "$config_mak" || { echo "av1_qsv disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_QSV_ENCODER=yes$' "$config_mak" || { echo "hevc_qsv disabled"; exit 1; }
    grep -q '^CONFIG_LIBVPL=yes$' "$config_mak" || { echo "libvpl disabled"; exit 1; }
    allowed='CONFIG_(HEVC_QSV|AV1_QSV|AAC)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
  fi
  unexpected="$(grep -E '^CONFIG_.*_ENCODER=yes$' "$config_mak" | grep -Ev "$allowed" || true)"
  [[ -z "$unexpected" ]] || { echo "unexpected encoders:"; printf '%s\n' "$unexpected"; exit 1; }
  if grep -q '^CONFIG_WRAPPED_AVFRAME_ENCODER=yes$' "$config_mak"; then
    echo "wrapped_avframe should stay disabled"
    exit 1
  fi

  while read -r filter_line; do
    [[ "$filter_line" =~ ^CONFIG_([A-Za-z0-9_]+)_FILTER=yes$ ]] || continue
    filter_name="${BASH_REMATCH[1]}"
    filter_lower="$(printf '%s' "$filter_name" | tr '[:upper:]' '[:lower:]')"
    found=0
    for f in "${allowed_filters[@]}"; do
      [[ "$f" == "$filter_lower" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || { echo "unexpected filter: $filter_lower"; exit 1; }
  done < "$config_mak"
}

is_system_dll() {
  local u="${1^^}"
  case "$u" in
    API-MS-WIN-*.DLL|EXT-MS-*.DLL|KERNEL32.DLL|NTDLL.DLL|UCRTBASE.DLL|MSVCRT.DLL|VCRUNTIME*.DLL) return 0 ;;
    USER32.DLL|GDI32.DLL|ADVAPI32.DLL|SHELL32.DLL|OLE32.DLL|OLEAUT32.DLL|COMDLG32.DLL|COMCTL32.DLL) return 0 ;;
    WS2_32.DLL|CRYPT32.DLL|BCRYPT.DLL|VERSION.DLL|SHLWAPI.DLL|SECUR32.DLL|IPHLPAPI.DLL|NCRYPT.DLL) return 0 ;;
    SETUPAPI.DLL|CFGMGR32.DLL|IMM32.DLL|WINMM.DLL|NORMALIZ.DLL|D3D*.DLL|DXGI.DLL|VULKAN-1.DLL) return 0 ;;
    NVCUDA.DLL|NVENCODEAPI64.DLL) return 0 ;;
  esac
  return 1
}

check_single_file_imports() {
  local exe="$1" dump imports bad dll
  dump="$(first_tool llvm-objdump "$TARGET-objdump" objdump)"
  imports="$($dump -p "$exe" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p' | sort -fu)"
  bad=""
  while IFS= read -r dll; do
    [[ -z "$dll" ]] && continue
    is_system_dll "$dll" || bad+="$dll"$'\n'
  done <<< "$imports"
  if [[ -n "$bad" ]]; then
    echo "non-system DLL imports found:"
    printf '%s' "$bad"
    exit 1
  fi
  echo "DLL imports are system-only."
}

verify_lite_binary() {
  local exe="$1" output filters hwaccels name
  local names=()
  output="$("$exe" -hide_banner -encoders 2>/dev/null | tr -d '\r')"
  mapfile -t names < <(awk '$1 ~ /^[VAS][A-Z.]{5}$/ && $2 != "=" { print $2 }' <<< "$output")
  for name in "${names[@]}"; do
    case "$BACKEND:$name" in
      nvenc:aac|nvenc:hevc_nvenc|nvenc:av1_nvenc|qsv:aac|qsv:hevc_qsv|qsv:av1_qsv) ;;
      *) echo "unexpected runtime encoder: $name"; exit 1 ;;
    esac
  done
  grep -q 'nmr' <<< "$("$exe" -hide_banner -h encoder=aac 2>&1)" || { echo "NMR AAC coder missing"; exit 1; }
  grep -q 'libplacebo' <<< "$("$exe" -hide_banner -h filter=libplacebo 2>&1)" || { echo "libplacebo filter help failed"; exit 1; }
  filters="$("$exe" -hide_banner -filters 2>/dev/null | tr -d '\r')"
  hwaccels="$("$exe" -hide_banner -hwaccels 2>/dev/null | tr -d '\r')"
  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '[[:space:]]av1_nvenc[[:space:]]' <<< "$output" || { echo "av1_nvenc missing"; exit 1; }
    grep -q '[[:space:]]scale_cuda[[:space:]]' <<< "$filters" || { echo "scale_cuda missing"; exit 1; }
    grep -qx 'cuda' <<< "$hwaccels" || { echo "CUDA hwaccel missing"; exit 1; }
  else
    grep -q '[[:space:]]av1_qsv[[:space:]]' <<< "$output" || { echo "av1_qsv missing"; exit 1; }
    grep -q '[[:space:]]scale_qsv[[:space:]]' <<< "$filters" || { echo "scale_qsv missing"; exit 1; }
    grep -Eq '^(d3d11va|dxva2)$' <<< "$hwaccels" || { echo "QSV Windows hwaccel missing"; exit 1; }
  fi
}

run_stage() {
  local stage="$1"
  CURRENT_STAGE="$stage"
  echo "===> $stage"
  case "$stage" in
    nv-codec-headers)
      local s
      s="$(stage_src nv-codec-headers)"
      make -C "$s" PREFIX="$PREFIX"
      make -C "$s" PREFIX="$PREFIX" install
      ;;

    vapoursynth)
      local s
      s="$(stage_src vapoursynth)"
      mkdir -p "$PREFIX/include" "$PREFIX/include/vapoursynth" "$PREFIX/lib/pkgconfig"
      cp -f "$s/include/"VapourSynth*.h "$s/include/"VSScript*.h "$s/include/"VSHelper*.h "$PREFIX/include/"
      cp -f "$s/include/"VapourSynth*.h "$s/include/"VSScript*.h "$s/include/"VSHelper*.h "$PREFIX/include/vapoursynth/"
      cat > "$PREFIX/lib/pkgconfig/vapoursynth.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: vapoursynth
Description: VapourSynth input headers
Version: 77
Libs:
Cflags: -I\${includedir}
EOF
      cp -f "$PREFIX/lib/pkgconfig/vapoursynth.pc" "$PREFIX/lib/pkgconfig/VapourSynth.pc"
      ;;

    libvpl)
      build_cmake libvpl -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DINSTALL_EXAMPLES=OFF -DENABLE_WARNINGS=OFF
      ;;

    libsoxr)
      build_cmake libsoxr -Wno-dev --no-warn-unused-cli -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.10
      write_soxr_pc
      ;;

    libshaderc)
      build_shaderc_from_source
      ;;

    vulkan-headers)
      local s
      s="$(stage_src vulkan-headers)"
      local vk_version
      vk_version="$(git -C "$s" describe --tags --always 2>/dev/null | sed 's/^v//' | sed 's/-.*//')"
      mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/lib/pkgconfig"
      cp -rf "$s/include/"* "$PREFIX/include/"
      cat > "$PREFIX/lib/vulkan-1.def" <<EOF
LIBRARY vulkan-1.dll
EXPORTS
vkGetInstanceProcAddr
EOF
      "$DLLTOOL" -d "$PREFIX/lib/vulkan-1.def" -l "$PREFIX/lib/libvulkan-1.dll.a" -D vulkan-1.dll
      cp -f "$PREFIX/lib/libvulkan-1.dll.a" "$PREFIX/lib/libvulkan.dll.a"
      cp -f "$PREFIX/lib/libvulkan-1.dll.a" "$PREFIX/lib/libvulkan-1.a"
      cp -f "$PREFIX/lib/libvulkan.dll.a" "$PREFIX/lib/libvulkan.a"
      cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Vulkan-Loader
Description: Windows Vulkan loader import library
Version: $vk_version
Libs: -L\${libdir} -lvulkan-1
Cflags: -I\${includedir}
EOF
      ;;

    libplacebo)
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists shaderc vulkan || { echo "shaderc/vulkan pkg-config missing"; exit 1; }
      local s b
      s="$(stage_src libplacebo)"
      b="$BUILDROOT/libplacebo"
      rm -rf "$b"
      meson setup "$b" "$s" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Ddemos=false \
        -Dtests=false \
        -Dvulkan=enabled \
        -Dshaderc=enabled \
        -Dopengl=disabled \
        -Dlcms=disabled \
        -Ddovi=disabled \
        -Dlibdovi=disabled \
        -Dxxhash=disabled
      meson compile -C "$b" -j "$JOBS"
      meson install -C "$b"
      grep -q '^pl_has_vk_proc_addr=1' "$PREFIX/lib/pkgconfig/libplacebo.pc" || { echo "libplacebo did not link Vulkan proc addr"; exit 1; }
      ;;

    ffmpeg)
      [[ "$BACKEND" == "nvenc" ]] && setup_cuda
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists soxr libplacebo shaderc vulkan || { echo "required pkg-config files missing"; exit 1; }
      [[ "$BACKEND" == "qsv" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vpl || { [[ "$BACKEND" == "nvenc" ]] || exit 1; }
      [[ "$BACKEND" == "nvenc" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || { [[ "$BACKEND" == "qsv" ]] || exit 1; }

      local ff_stage ff_bld extra_cflags extra_ldflags extra_libs ffmpeg_nvccflags
      ff_stage="$(stage_src ffmpeg-source)"
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage"
      ff_bld="$BUILDROOT/ffmpeg"
      rm -rf "$ff_bld"
      mkdir -p "$ff_bld"
      pushd "$ff_bld" >/dev/null
      unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES

      extra_cflags="-I$PREFIX/include"
      extra_ldflags="-L$PREFIX/lib $LDFLAGS"
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
        --enable-libsoxr
        --enable-vulkan
        --enable-vulkan-static
        --enable-libplacebo
        --enable-libshaderc
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
          --enable-vapoursynth
        )
      else
        configure_cmd+=(--enable-libvpl --enable-d3d11va --enable-dxva2)
      fi

      configure_cmd+=(--disable-encoders)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for e in hevc_nvenc av1_nvenc aac; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      else
        for e in hevc_qsv av1_qsv aac; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      fi

      configure_cmd+=(--disable-decoders)
      for d in h264 hevc av1 vp9 vp8 mpeg2video mpeg4 msmpeg4v3 vc1 wmv3 mjpeg prores rawvideo aac aac_latm mp3 ac3 eac3 truehd dca flac opus vorbis wavpack alac pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le; do
        add_if_exists "$ff_stage" --list-decoders "$d" --enable-decoder
      done

      configure_cmd+=(--disable-hwaccels)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for h in h264_nvdec hevc_nvdec av1_nvdec vp9_nvdec vp8_nvdec mjpeg_nvdec mpeg2_nvdec mpeg4_nvdec vc1_nvdec wmv3_nvdec; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      else
        for h in h264_d3d11va hevc_d3d11va av1_d3d11va vp9_d3d11va h264_dxva2 hevc_dxva2 av1_dxva2 vp9_dxva2 vc1_dxva2 mpeg2_dxva2; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      fi

      configure_cmd+=(--disable-demuxers)
      for d in matroska mov mpegts h264 hevc av1 rawvideo image2 concat aac mp3 flac ogg wav vapoursynth; do add_if_exists "$ff_stage" --list-demuxers "$d" --enable-demuxer; done
      configure_cmd+=(--disable-muxers)
      for m in matroska mp4 mov ipod mpegts null rawvideo adts wav flac ogg; do add_if_exists "$ff_stage" --list-muxers "$m" --enable-muxer; done
      configure_cmd+=(--disable-parsers)
      for p in h264 hevc av1 aac ac3 dca mlp opus vorbis mjpeg vp9 vp8 mpeg4video vc1; do add_if_exists "$ff_stage" --list-parsers "$p" --enable-parser; done
      configure_cmd+=(--disable-bsfs)
      for b in h264_mp4toannexb hevc_mp4toannexb av1_metadata h264_metadata hevc_metadata aac_adtstoasc extract_extradata; do add_if_exists "$ff_stage" --list-bsfs "$b" --enable-bsf; done
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

      printf '%s\n' "${configure_cmd[@]}" > "$BUILDROOT/ffmpeg-configure.args"
      printf '%q ' "${configure_cmd[@]}"; echo
      "${configure_cmd[@]}"
      validate_config ffbuild/config.mak config.h
      mkdir -p libswscale/x86
      make -f ./Makefile -j"$FFMPEG_JOBS"
      make -f ./Makefile install
      popd >/dev/null
      [[ -f "$PREFIX/bin/ffmpeg.exe" ]] || { echo "ffmpeg.exe not produced"; exit 1; }
      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || true
      cp -f "$PREFIX/bin/ffmpeg.exe" "$SCRIPT_DIR/ffmpeg.exe"
      check_single_file_imports "$SCRIPT_DIR/ffmpeg.exe"
      verify_lite_binary "$SCRIPT_DIR/ffmpeg.exe"
      ;;

    *) echo "unknown stage: $stage"; exit 1 ;;
  esac
}

run_build() {
  setup_build_env
  need_repo ffmpeg-source
  local s start="${1:-}" start_seen=0
  if [[ -n "$start" ]]; then
    local found=0
    for s in "${STAGES[@]}"; do [[ "$s" == "$start" ]] && found=1; done
    [[ "$found" == "1" ]] || { echo "unknown stage: $start"; exit 1; }
  fi
  if [[ -z "$start" ]]; then
    rm -rf "$PREFIX"
  fi
  mkdir -p "$PREFIX"
  for s in "${STAGES[@]}"; do
    if [[ -n "$start" && "$start_seen" == "0" ]]; then
      [[ "$s" == "$start" ]] && start_seen=1 || continue
    fi
    [[ "$s" == "ffmpeg" ]] || need_repo "$s"
    run_stage "$s"
  done
  echo "Built: $SCRIPT_DIR/ffmpeg.exe"
  if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
    echo "Skipped unsupported items:"
    printf ' - %s\n' "${SKIPPED_ITEMS[@]}"
  fi
}

cmd="${1:-all}"
shift || true
case "$cmd" in
  all) run_update; run_build ;;
  build) run_build "${1:-}" ;;
  update) run_update ;;
  clean) rm -rf "$PREFIX" "$BUILDROOT" "$SCRIPT_DIR/ffmpeg.exe" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
