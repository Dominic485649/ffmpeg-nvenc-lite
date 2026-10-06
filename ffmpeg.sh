#!/usr/bin/env bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8
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
HOST_TOOLS="${HOST_TOOLS:-$BUILDROOT/host-tools}"
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
  [jxrlib]="https://github.com/scrubbbbs/jxrlib-kif.git"
  [vapoursynth]="https://github.com/vapoursynth/vapoursynth.git"
  [libshaderc]="https://github.com/google/shaderc.git"
  [vulkan-headers]="https://github.com/KhronosGroup/Vulkan-Headers.git"
  [libplacebo]="https://github.com/haasn/libplacebo.git"
)

declare -A TAG_REGEX=(
  [ffmpeg-source]='master'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [opus]='^v?[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [libsoxr]='^v?[0-9]+(\.[0-9]+)*$'
  [jxrlib]='main|master'
  [vapoursynth]='^R[0-9]+(\.[0-9]+)*$'
  [libshaderc]='^v[0-9]+\.[0-9]+$'
  [vulkan-headers]='^v[0-9]+(\.[0-9]+)*$'
  [libplacebo]='^v[0-9]+(\.[0-9]+)*$'
)

COMMON_STAGES=(opus libsoxr jxrlib libshaderc vulkan-headers libplacebo)
if [[ "$BACKEND" == "nvenc" ]]; then
  STAGES=(nv-codec-headers vapoursynth "${COMMON_STAGES[@]}" ffmpeg)
else
  STAGES=(libvpl "${COMMON_STAGES[@]}" ffmpeg)
fi

COMMON_FILTERS=(
  dovi_apply dovi_compose hlg2pq hdr10plus
  buffer buffersink abuffer abuffersink format aformat null anull
  fps trim atrim setpts asetpts settb asettb setparams setsar
  crop hflip vflip transpose rotate scale aresample
  hwupload hwdownload hwmap libplacebo
)
NVENC_FILTERS=(scale_cuda overlay_cuda pad_cuda colorspace_cuda yadif_cuda bwdif_cuda bilateral_cuda chromakey_cuda thumbnail_cuda transpose_cuda hwupload_cuda fruc_vulkan)
QSV_FILTERS=(scale_qsv vpp_qsv deinterlace_qsv overlay_qsv hstack_qsv vstack_qsv xstack_qsv)

CURRENT_STAGE=""
SKIPPED_ITEMS=()
BUILD_STARTED_AT=""
HARDWARE_STATUS="not-run"

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

External Opus:
  -c:a libopus; native opus decoder remains enabled
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
  local name="$1" repo_dir regex tag branch
  repo_dir="$(source_dir "$name")"
  regex="${TAG_REGEX[$name]}"
  tag="$(git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/tags \
    | sed 's/\^{}$//' \
    | sort -u \
    | { grep -E "$regex" || true; } \
    | while read -r tag; do printf "%s	%s
" "$(normalize_version "$name" "$tag")" "$tag"; done \
    | sort -V \
    | tail -n 1 \
    | cut -f2)"
  if [[ -n "$tag" ]]; then
    printf '%s
' "$tag"
    return 0
  fi
  for branch in stable master main; do
    if [[ "$regex" == *"$branch"* ]] \
      && git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      printf '%s
' "$branch"
      return 0
    fi
  done
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
    [[ -n "$ref" ]] || { echo "No stable release tag matched for $name" >&2; exit 1; }
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
  if [[ "$CFG_ENABLE" == "1" ]]; then
    opt+=" -mguard=cf"
    ld+=" -Wl,/guard:cf"
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
  if [[ "$name" == "libvpl" ]]; then
    local vpl_defs="$stage/libvpl/src/windows/mfx_dispatcher_defs.h"
    python3 - "$vpl_defs" <<'PYVPLMINGW'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "#if _MSC_VER < 1400"
new = "#if defined(_MSC_VER) && _MSC_VER < 1400"
old_count = s.count(old)
new_count = s.count(new)
if old_count == 1 and new_count == 0:
    p.write_text(s.replace(old, new, 1))
elif old_count == 0 and new_count == 1:
    pass
else:
    raise SystemExit(f"{p}: unexpected oneVPL MinGW wcscpy_s guard state: old={old_count}, new={new_count}")
PYVPLMINGW
  fi
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

build_opus() {
  local stage
  stage="$(stage_src opus)"
  pushd "$stage" >/dev/null
  if [[ ! -x ./configure ]]; then
    if [[ -x ./autogen.sh ]]; then
      sed -i '/dnn\/download_model\.sh/d' ./autogen.sh
      ./autogen.sh
    else
      autoreconf -fiv
    fi
  fi
  CPPFLAGS="-I$PREFIX/include" \
  LDFLAGS="$LDFLAGS -L$PREFIX/lib" \
  ./configure \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-extra-programs \
    --disable-deep-plc \
    --disable-dred \
    --disable-osce
  make -j"$JOBS"
  make install
  popd >/dev/null
  [[ -f "$PREFIX/lib/pkgconfig/opus.pc" && -f "$PREFIX/include/opus/opus.h" && -f "$PREFIX/lib/libopus.a" ]] || {
    echo "libopus static install is incomplete"
    exit 1
  }
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    "$PKG_CONFIG" --exists opus || { echo "pkg-config cannot find target libopus"; exit 1; }
  [[ "$("$PKG_CONFIG" --variable=prefix opus)" == "$PREFIX" ]] || {
    echo "pkg-config resolved libopus outside the Lite PREFIX"
    exit 1
  }
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

build_host_glslc_from_source() {
  [[ "$BACKEND" == "nvenc" ]] || return 0
  local stage="$1" bld="$BUILDROOT/libshaderc-host" host_glslc="$HOST_TOOLS/bin/glslc"
  rm -rf "$bld"
  env -u CC -u CXX -u AR -u RANLIB -u STRIP -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$stage" -B "$bld" -G Ninja \
      -DCMAKE_C_COMPILER=/usr/bin/cc \
      -DCMAKE_CXX_COMPILER=/usr/bin/c++ \
      -DCMAKE_BUILD_TYPE=Release \
      -DSHADERC_SKIP_TESTS=ON \
      -DSHADERC_SKIP_EXAMPLES=ON \
      -DSHADERC_ENABLE_EXECUTABLES=ON \
      -DSHADERC_ENABLE_INSTALL=OFF \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$bld" --target glslc_exe --parallel "$JOBS"
  mkdir -p "$HOST_TOOLS/bin"
  cp -f "$bld/glslc/glslc" "$host_glslc"
  chmod +x "$host_glslc"
}

build_shaderc_from_source() {
  local stage bld
  stage="$(stage_src libshaderc)"
  if [[ ! -d "$stage/third_party/glslang" || ! -d "$stage/third_party/spirv-tools/external/spirv-headers" ]]; then
    if [[ "$BACKEND" == "nvenc" ]]; then
      pushd "$stage" >/dev/null
      for i in 1 2 3 4 5; do
        python3 utils/git-sync-deps && break
        rm -rf third_party/spirv-headers third_party/spirv-tools/external/spirv-headers third_party/googletest
        echo "shaderc deps sync failed, retry $i/5..."
        sleep 10
        [[ "$i" != "5" ]] || exit 1
      done
      popd >/dev/null
    else
      seed_shaderc_from_common || {
        echo "libshaderc third_party deps are missing and $COMMON_PREFIX has no static shaderc."
        echo "Run ./ffmpeg.sh update or build full once, then retry."
        exit 1
      }
      return 0
    fi
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
  build_host_glslc_from_source "$stage"
}

write_jxrlib_cmake() {
  local stage="$1"
  cat > "$stage/CMakeLists.txt" <<'JXR_CMAKE'
cmake_minimum_required(VERSION 3.13)
project(jxrlib C)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(JXR_INC common/include image/sys jxrgluelib jxrtestlib)
set(JXR_SYS
  image/sys/adapthuff.c image/sys/image.c image/sys/strcodec.c
  image/sys/strPredQuant.c image/sys/strTransform.c image/sys/perfTimerANSI.c)
set(JXR_DEC
  image/decode/decode.c image/decode/postprocess.c image/decode/segdec.c
  image/decode/strdec.c image/decode/strdec_x86.c image/decode/strInvTransform.c
  image/decode/strPredQuantDec.c image/decode/JXRTranscode.c)
set(JXR_ENC
  image/encode/encode.c image/encode/segenc.c image/encode/strenc.c
  image/encode/strenc_x86.c image/encode/strFwdTransform.c image/encode/strPredQuantEnc.c)
set(JXR_GLUE
  jxrgluelib/JXRGlue.c jxrgluelib/JXRMeta.c
  jxrgluelib/JXRGluePFC.c jxrgluelib/JXRGlueJxr.c)
set(JXR_TEST
  jxrtestlib/JXRTest.c jxrtestlib/JXRTestBmp.c jxrtestlib/JXRTestHdr.c
  jxrtestlib/JXRTestPnm.c jxrtestlib/JXRTestTif.c jxrtestlib/JXRTestYUV.c)
add_library(jpegxr STATIC ${JXR_SYS} ${JXR_DEC} ${JXR_ENC})
target_include_directories(jpegxr PRIVATE ${JXR_INC})
target_compile_definitions(jpegxr PRIVATE __ANSI__ DISABLE_PERF_MEASUREMENT)
add_library(jxrglue STATIC ${JXR_GLUE} ${JXR_TEST})
target_include_directories(jxrglue PRIVATE ${JXR_INC})
target_compile_definitions(jxrglue PRIVATE __ANSI__ DISABLE_PERF_MEASUREMENT)
target_link_libraries(jxrglue PRIVATE jpegxr)
install(TARGETS jpegxr jxrglue ARCHIVE DESTINATION lib)
install(FILES
  jxrgluelib/JXRGlue.h jxrgluelib/JXRMeta.h jxrtestlib/JXRTest.h
  image/sys/windowsmediaphoto.h DESTINATION include/jxrlib)
install(DIRECTORY common/include/ DESTINATION include/jxrlib FILES_MATCHING PATTERN "*.h")
JXR_CMAKE
}

build_jxrlib() {
  local stage bld
  stage="$(stage_src jxrlib)"
  python3 - "$stage/image/sys/strcodec.c" <<'PYJXRLIST'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_bytes()
old = b"    FailIf(pWS->state.buf.cbBuf < pWS->state.buf.cbCur + cb, WMP_errBufferOverflow);\n"
new = (b"    /* WriteWS_List allocates the next PACKETLENGTH buffer on demand in\n"
       b"       the loop below, so rejecting a write against the already\n"
       b"       allocated total dropped every packet after the first and\n"
       b"       silently truncated any image larger than one packet. */\n")
start = s.index(b"ERR WriteWS_List(")
end = s.index(b"\n}\n", start)
body = s[start:end]
old_count = body.count(old)
new_count = body.count(new)
if old_count == 1 and new_count == 0:
    s = s[:start] + body.replace(old, new, 1) + s[end:]
elif old_count == 0 and new_count == 1:
    pass
else:
    raise SystemExit(f"{p}: unexpected WriteWS_List capacity-check state: old={old_count}, new={new_count}")
p.write_bytes(s)
PYJXRLIST
  rm -f "$stage/common/include/guiddef.h"
  write_jxrlib_cmake "$stage"
  bld="$BUILDROOT/jxrlib"
  rm -rf "$bld"
  cmake -S "$stage" -B "$bld" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/libjxr.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/jxrlib

Name: libjxr
Description: JPEG XR reference codec library
Version: 1.1
Libs: -L\${libdir} -ljxrglue -ljpegxr
Libs.private: -lm
Cflags: -I\${includedir}
EOF
  PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libjxr || {
    echo "libjxr pkg-config validation failed" >&2
    exit 1
  }
}

patch_ffmpeg_jxr() {
  local ff_stage="$1"
  python3 - "$ff_stage" <<'PYJXR'
from pathlib import Path
import sys
root = Path(sys.argv[1])

def replace_once(rel, old, new):
    path = root / rel
    text = path.read_text()
    old = old.replace(r"\n", "\n")
    new = new.replace(r"\n", "\n")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{rel}: JXR patch anchor count={count}, expected 1")
    path.write_text(text.replace(old, new, 1))

replace_once("configure",
    "  --enable-libjxl          enable JPEG XL de/encoding via libjxl [no]\\n",
    "  --enable-libjxl          enable JPEG XL de/encoding via libjxl [no]\\n"
    "  --enable-libjxr          enable JPEG XR de/encoding via jxrlib [no]\\n")
replace_once("configure", "    libjxl\\n", "    libjxl\\n    libjxr\\n")
replace_once("configure",
    'libjxl_encoder_deps="libjxl libjxl_threads"\\n',
    'libjxl_encoder_deps="libjxl libjxl_threads"\\n'
    'libjxr_decoder_deps="libjxr"\\n'
    'libjxr_encoder_deps="libjxr"\\n')
replace_once("configure",
    'enabled libjxl            && require_pkg_config libjxl "libjxl >= 0.7.0" jxl/decode.h JxlDecoderVersion &&\\n'
    '                             require_pkg_config libjxl_threads "libjxl_threads >= 0.7.0" jxl/thread_parallel_runner.h JxlThreadParallelRunner\\n',
    'enabled libjxl            && require_pkg_config libjxl "libjxl >= 0.7.0" jxl/decode.h JxlDecoderVersion &&\\n'
    '                             require_pkg_config libjxl_threads "libjxl_threads >= 0.7.0" jxl/thread_parallel_runner.h JxlThreadParallelRunner\\n'
    'enabled libjxr            && require_pkg_config libjxr libjxr JXRGlue.h PKCreateCodecFactory\\n')
replace_once("libavcodec/codec_id.h",
    "    AV_CODEC_ID_ASTC,\\n\\n    /* various PCM \"codecs\" */\\n    AV_CODEC_ID_FIRST_AUDIO = 0x10000,     ///< A dummy id pointing at the start of audio codecs",
    "    AV_CODEC_ID_ASTC,\\n    AV_CODEC_ID_JPEGXR = 0x7F00,\\n\\n"
    "    /* various PCM \"codecs\" */\\n    AV_CODEC_ID_FIRST_AUDIO = 0x10000,     ///< A dummy id pointing at the start of audio codecs")
replace_once("libavcodec/codec_desc.c",
    '    /* various PCM "codecs" */\\n',
    '''    {
        .id        = AV_CODEC_ID_JPEGXR,
        .type      = AVMEDIA_TYPE_VIDEO,
        .name      = "jpegxr",
        .long_name = NULL_IF_CONFIG_SMALL("JPEG XR"),
        .props     = AV_CODEC_PROP_INTRA_ONLY | AV_CODEC_PROP_LOSSY |
                     AV_CODEC_PROP_LOSSLESS,
        .mime_types= MT("image/jxr", "image/vnd.ms-photo"),
    },

    /* various PCM "codecs" */
''')
replace_once("libavcodec/allcodecs.c",
    "extern const FFCodec ff_libjxl_encoder;\\n",
    "extern const FFCodec ff_libjxl_encoder;\\n"
    "extern const FFCodec ff_libjxr_decoder;\\n"
    "extern const FFCodec ff_libjxr_encoder;\\n")
replace_once("libavcodec/Makefile",
    "OBJS-$(CONFIG_LIBJXL_ENCODER)             += libjxlenc.o libjxl.o\\n",
    "OBJS-$(CONFIG_LIBJXL_ENCODER)             += libjxlenc.o libjxl.o\\n"
    "OBJS-$(CONFIG_LIBJXR_DECODER)             += libjxrdec.o\\n"
    "OBJS-$(CONFIG_LIBJXR_ENCODER)             += libjxrenc.o\\n")
replace_once("libavformat/img2.c",
    "    TAG(JPEGXS,          jxs      )",
    "    TAG(JPEGXR,          jxr      ) " + chr(92) + "\n"
    "    TAG(JPEGXR,          wdp      ) " + chr(92) + "\n"
    "    TAG(JPEGXR,          hdp      ) " + chr(92) + "\n"
    "    TAG(JPEGXS,          jxs      )")
replace_once("libavformat/img2enc.c",
    '    .p.extensions   = "bmp,dpx,exr,jls,jpeg,jpg,jxs,jxl,ljpg,pam,pbm,pcx,pfm,pgm,pgmyuv,phm,"\\n',
    '    .p.extensions   = "bmp,dpx,exr,jls,jpeg,jpg,jxs,jxl,jxr,ljpg,pam,pbm,pcx,pfm,pgm,pgmyuv,phm,"\\n')

(root / "libavcodec/libjxrenc.c").write_text(r'''/*
 * JPEG XR encoding support via jxrlib.
 * Generated in the staged FFmpeg tree by ffmpeg.sh.
 */
#include <limits.h>
#include "libavutil/pixdesc.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include <JXRGlue.h>

extern ERR CreateWS_List(struct WMPStream **ppWS);

static int libjxr_pixfmt_to_guid(enum AVPixelFormat fmt,
                                 PKPixelFormatGUID *guid, int *has_alpha)
{
    *has_alpha = 0;
    switch (fmt) {
    case AV_PIX_FMT_GRAY8:    *guid = GUID_PKPixelFormat8bppGray; return 0;
    case AV_PIX_FMT_GRAY16LE: *guid = GUID_PKPixelFormat16bppGray; return 0;
    case AV_PIX_FMT_RGB24:    *guid = GUID_PKPixelFormat24bppRGB; return 0;
    case AV_PIX_FMT_BGR24:    *guid = GUID_PKPixelFormat24bppBGR; return 0;
    case AV_PIX_FMT_RGBA:     *guid = GUID_PKPixelFormat32bppRGBA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_BGRA:     *guid = GUID_PKPixelFormat32bppBGRA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGB48LE:  *guid = GUID_PKPixelFormat48bppRGB; return 0;
    case AV_PIX_FMT_RGBA64LE: *guid = GUID_PKPixelFormat64bppRGBA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGBAF16LE: *guid = GUID_PKPixelFormat64bppRGBAHalf; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGBF16LE:  *guid = GUID_PKPixelFormat48bppRGBHalf; return 0;
    case AV_PIX_FMT_RGBAF32LE: *guid = GUID_PKPixelFormat128bppRGBAFloat; *has_alpha = 1; return 0;
    case AV_PIX_FMT_GRAYF16LE: *guid = GUID_PKPixelFormat16bppGrayHalf; return 0;
    case AV_PIX_FMT_GRAYF32LE: *guid = GUID_PKPixelFormat32bppGrayFloat; return 0;
    default: return AVERROR(EINVAL);
    }
}

static int libjxr_encode_frame(AVCodecContext *avctx, AVPacket *pkt,
                               const AVFrame *frame, int *got_packet)
{
    PKCodecFactory *factory = NULL;
    PKImageEncode *encoder = NULL;
    struct WMPStream *stream = NULL;
    PKPixelFormatGUID guid;
    CWMIStrCodecParam params = { 0 };
    size_t output_size = 0;
    int has_alpha = 0, ret;
    ERR jerr = WMP_errSuccess;

    if (frame->linesize[0] < 0)
        return AVERROR(EINVAL);
    ret = libjxr_pixfmt_to_guid(avctx->pix_fmt, &guid, &has_alpha);
    if (ret < 0) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported JPEG XR pixel format: %s\\n",
               av_get_pix_fmt_name(avctx->pix_fmt));
        return ret;
    }

    params.bVerbose = FALSE;
    params.cfColorFormat = YUV_444;
    params.bdBitDepth = BD_LONG;
    params.bfBitstreamFormat = FREQUENCY;
    params.bProgressiveMode = TRUE;
    params.olOverlap = OL_ONE;
    params.sbSubband = SB_ALL;
    params.uAlphaMode = has_alpha ? 2 : 0;
    params.uiDefaultQPIndex = 1;
    params.uiDefaultQPIndexAlpha = 1;

    if ((jerr = CreateWS_List(&stream)) != WMP_errSuccess ||
        (jerr = PKCreateCodecFactory(&factory, WMP_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = factory->CreateCodec(&IID_PKImageWmpEncode, (void **)&encoder)) != WMP_errSuccess ||
        (jerr = encoder->Initialize(encoder, stream, &params, sizeof(params))) != WMP_errSuccess ||
        (jerr = encoder->SetPixelFormat(encoder, guid)) != WMP_errSuccess ||
        (jerr = encoder->SetSize(encoder, avctx->width, avctx->height)) != WMP_errSuccess ||
        (jerr = encoder->SetResolution(encoder, 96.0f, 96.0f)) != WMP_errSuccess ||
        (jerr = encoder->WritePixels(encoder, avctx->height, frame->data[0],
                                     frame->linesize[0])) != WMP_errSuccess) {
        ret = AVERROR_EXTERNAL;
        goto fail;
    }

    if (encoder->WMP.nOffImage < 0 || encoder->WMP.nCbImage <= 0 ||
        encoder->WMP.nOffImage > INT_MAX - encoder->WMP.nCbImage) {
        av_log(avctx, AV_LOG_ERROR, "Invalid JPEG XR image extent\\n");
        ret = AVERROR_INVALIDDATA;
        goto cleanup;
    }
    output_size = (size_t)encoder->WMP.nOffImage + (size_t)encoder->WMP.nCbImage;

    if (has_alpha && params.uAlphaMode == 2) {
        size_t alpha_end;
        if (encoder->WMP.nOffAlpha < 0 || encoder->WMP.nCbAlpha <= 0 ||
            encoder->WMP.nOffAlpha > INT_MAX - encoder->WMP.nCbAlpha) {
            av_log(avctx, AV_LOG_ERROR, "Invalid JPEG XR alpha extent\\n");
            ret = AVERROR_INVALIDDATA;
            goto cleanup;
        }
        alpha_end = (size_t)encoder->WMP.nOffAlpha + (size_t)encoder->WMP.nCbAlpha;
        if (alpha_end > output_size)
            output_size = alpha_end;
    }

    if (!output_size || output_size > INT_MAX ||
        (jerr = stream->SetPos(stream, 0)) != WMP_errSuccess) {
        ret = AVERROR_EXTERNAL;
        goto fail;
    }

    if ((ret = ff_alloc_packet(avctx, pkt, (int)output_size)) < 0)
        goto cleanup;
    if ((jerr = stream->Read(stream, pkt->data, output_size)) != WMP_errSuccess) {
        av_packet_unref(pkt);
        ret = AVERROR_EXTERNAL;
        goto fail;
    }
    *got_packet = 1;
    ret = 0;
    goto cleanup;

fail:
    av_log(avctx, AV_LOG_ERROR, "jxrlib JPEG XR encode failed (error=%d)\\n", (int)jerr);
cleanup:
    if (encoder) {
        if (encoder->pStream)
            stream = NULL;
        encoder->Release(&encoder);
    }
    if (stream)
        stream->Close(&stream);
    if (factory)
        factory->Release(&factory);
    return ret;
}

const FFCodec ff_libjxr_encoder = {
    .p.name = "libjxr",
    CODEC_LONG_NAME("JPEG XR via jxrlib"),
    .p.type = AVMEDIA_TYPE_VIDEO,
    .p.id = AV_CODEC_ID_JPEGXR,
    .p.capabilities = AV_CODEC_CAP_DR1 | AV_CODEC_CAP_ENCODER_REORDERED_OPAQUE,
    FF_CODEC_ENCODE_CB(libjxr_encode_frame),
    CODEC_PIXFMTS(AV_PIX_FMT_GRAY8, AV_PIX_FMT_GRAY16LE,
                  AV_PIX_FMT_RGB24, AV_PIX_FMT_BGR24,
                  AV_PIX_FMT_RGBA, AV_PIX_FMT_BGRA,
                  AV_PIX_FMT_RGB48LE, AV_PIX_FMT_RGBA64LE,
                  AV_PIX_FMT_RGBAF16LE, AV_PIX_FMT_RGBF16LE,
                  AV_PIX_FMT_RGBAF32LE, AV_PIX_FMT_GRAYF16LE,
                  AV_PIX_FMT_GRAYF32LE),
    .p.wrapper_name = "libjxr",
};
''')

(root / "libavcodec/libjxrdec.c").write_text(r'''/*
 * JPEG XR decoding support via jxrlib.
 * Generated in the staged FFmpeg tree by ffmpeg.sh.
 */
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include <JXRGlue.h>

static enum AVPixelFormat libjxr_guid_to_pixfmt(const PKPixelFormatGUID *guid,
                                                 int *bits)
{
    *bits = 8;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat8bppGray)) return AV_PIX_FMT_GRAY8;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat16bppGray)) { *bits = 16; return AV_PIX_FMT_GRAY16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat24bppRGB)) return AV_PIX_FMT_RGB24;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat24bppBGR)) return AV_PIX_FMT_BGR24;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppRGBA)) return AV_PIX_FMT_RGBA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppBGRA)) return AV_PIX_FMT_BGRA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat48bppRGB)) { *bits = 16; return AV_PIX_FMT_RGB48LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat64bppRGBA)) { *bits = 16; return AV_PIX_FMT_RGBA64LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat64bppRGBAHalf)) { *bits = 16; return AV_PIX_FMT_RGBAF16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat48bppRGBHalf)) { *bits = 16; return AV_PIX_FMT_RGBF16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat128bppRGBAFloat)) { *bits = 32; return AV_PIX_FMT_RGBAF32LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppPRGBA)) return AV_PIX_FMT_RGBA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppBGR)) return AV_PIX_FMT_BGR0;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppGrayFloat)) { *bits = 32; return AV_PIX_FMT_GRAYF32LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat16bppGrayHalf)) { *bits = 16; return AV_PIX_FMT_GRAYF16LE; }
    return AV_PIX_FMT_NONE;
}

static int libjxr_decode_frame(AVCodecContext *avctx, AVFrame *frame,
                               int *got_frame, AVPacket *pkt)
{
    PKFactory *factory = NULL;
    PKCodecFactory *codec_factory = NULL;
    PKImageDecode *decoder = NULL;
    struct WMPStream *stream = NULL;
    PKPixelFormatGUID guid;
    PKRect rect = { 0, 0, 0, 0 };
    enum AVPixelFormat pix_fmt;
    I32 width = 0, height = 0;
    int bits = 0, ret = AVERROR_INVALIDDATA;
    ERR jerr = WMP_errSuccess;

    if (pkt->size <= 0)
        return AVERROR_INVALIDDATA;
    if ((jerr = PKCreateFactory(&factory, PK_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = factory->CreateStreamFromMemory(&stream, pkt->data, pkt->size)) != WMP_errSuccess ||
        (jerr = PKCreateCodecFactory(&codec_factory, WMP_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = codec_factory->CreateCodec(&IID_PKImageWmpDecode, (void **)&decoder)) != WMP_errSuccess ||
        (jerr = decoder->Initialize(decoder, stream)) != WMP_errSuccess ||
        (jerr = decoder->GetSize(decoder, &width, &height)) != WMP_errSuccess ||
        width <= 0 || height <= 0 ||
        (jerr = decoder->GetPixelFormat(decoder, &guid)) != WMP_errSuccess)
        goto fail;

    pix_fmt = libjxr_guid_to_pixfmt(&guid, &bits);
    if (pix_fmt == AV_PIX_FMT_NONE) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported JPEG XR pixel format GUID\\n");
        ret = AVERROR(ENOSYS);
        goto cleanup;
    }
    if ((ret = ff_set_dimensions(avctx, width, height)) < 0)
        goto cleanup;
    avctx->pix_fmt = pix_fmt;
    avctx->bits_per_raw_sample = bits;
    if ((ret = ff_get_buffer(avctx, frame, 0)) < 0)
        goto cleanup;

    rect.Width = width;
    rect.Height = height;
    if ((jerr = decoder->Copy(decoder, &rect, frame->data[0],
                              frame->linesize[0])) != WMP_errSuccess)
        goto fail;
    *got_frame = 1;
    ret = pkt->size;
    goto cleanup;

fail:
    av_log(avctx, AV_LOG_ERROR, "jxrlib JPEG XR decode failed (error=%d)\\n", (int)jerr);
cleanup:
    if (decoder)
        decoder->Release(&decoder);
    if (stream)
        stream->Close(&stream);
    if (codec_factory)
        codec_factory->Release(&codec_factory);
    if (factory)
        factory->Release(&factory);
    return ret;
}

const FFCodec ff_libjxr_decoder = {
    .p.name = "libjxr",
    CODEC_LONG_NAME("JPEG XR via jxrlib"),
    .p.type = AVMEDIA_TYPE_VIDEO,
    .p.id = AV_CODEC_ID_JPEGXR,
    .p.capabilities = AV_CODEC_CAP_DR1,
    FF_CODEC_DECODE_CB(libjxr_decode_frame),
    .p.wrapper_name = "libjxr",
};
''')
PYJXR
}

verify_jxr_binary() {
  local exe="$1" test_dir="${2:-$BUILDROOT/jxr-validation}"
  local encoders decoders
  encoders="$("$exe" -hide_banner -encoders 2>/dev/null | tr -d '\r')"
  decoders="$("$exe" -hide_banner -decoders 2>/dev/null | tr -d '\r')"
  grep -q '[[:space:]]libjxr[[:space:]]' <<<"$encoders" || { echo "libjxr encoder missing" >&2; exit 1; }
  grep -q '[[:space:]]libjxr[[:space:]]' <<<"$decoders" || { echo "libjxr decoder missing" >&2; exit 1; }
  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  python3 - "$test_dir/input.rgb" <<'PYRGB'
from pathlib import Path
import sys
w = h = 16
buf = bytearray()
for y in range(h):
    for x in range(w):
        buf += bytes(((x * 17) & 255, (y * 17) & 255, ((x ^ y) * 17) & 255))
Path(sys.argv[1]).write_bytes(buf)
PYRGB
  "$exe" -hide_banner -loglevel error \
    -f rawvideo -pixel_format rgb24 -video_size 16x16 -i "$test_dir/input.rgb" \
    -frames:v 1 -c:v libjxr "$test_dir/test.jxr"
  "$exe" -hide_banner -loglevel error \
    -i "$test_dir/test.jxr" -frames:v 1 -pix_fmt rgb24 -f rawvideo "$test_dir/output.rgb"
  cmp -s "$test_dir/input.rgb" "$test_dir/output.rgb" || {
    echo "JPEG XR lossless RGB24 round-trip mismatch" >&2
    exit 1
  }
  echo "JPEG XR libjxr lossless RGB24 encode/decode: OK"
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

patch_ffmpeg_nvenc_hdr_static() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"

  if grep -q 'nvenc_alloc_hdr_static_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC static HDR10 (MDCV/CLL) patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg NVENC static HDR10 (MDCV/CLL) =="
  python3 - "$nvenc_c" <<'PYNVENCSTATIC'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

helper = r"""/* Static HDR10 metadata for AV1. NVENC's AV1 encoder ignores
 * NV_ENC_CONFIG_AV1.outputMasteringDisplay / outputMaxCll - hevc_nvenc writes
 * MDCV/CLL, av1_nvenc does not - so push them through the AV1 OBU payload
 * array, which nvenc.c already feeds from ctx->sei_data. */
static int nvenc_alloc_hdr_static_payload(const AVFrame *frame, int metadata_type,
                                          uint8_t **data, size_t *size)
{
    const AVFrameSideData *sd_mdcv =
        av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    const AVFrameSideData *sd_cll =
        av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);

    *data = NULL;
    *size = 0;

    if (metadata_type == AV1_METADATA_TYPE_HDR_MDCV && sd_mdcv) {
        const AVMasteringDisplayMetadata *mdm = (const AVMasteringDisplayMetadata *)sd_mdcv->data;
        const int chroma_den = 1 << 16, max_luma_den = 1 << 8, min_luma_den = 1 << 14;
        uint8_t *buf, *q;
        int i;

        if (!mdm->has_primaries || !mdm->has_luminance)
            return 0;

        buf = q = av_malloc(24);
        if (!buf)
            return AVERROR(ENOMEM);

        for (i = 0; i < 3; i++) {
            bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][0].num, chroma_den, mdm->display_primaries[i][0].den));
            bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][1].num, chroma_den, mdm->display_primaries[i][1].den));
        }
        bytestream_put_be16(&q, av_rescale(mdm->white_point[0].num, chroma_den, mdm->white_point[0].den));
        bytestream_put_be16(&q, av_rescale(mdm->white_point[1].num, chroma_den, mdm->white_point[1].den));
        bytestream_put_be32(&q, av_rescale(mdm->max_luminance.num, max_luma_den, mdm->max_luminance.den));
        bytestream_put_be32(&q, av_rescale(mdm->min_luminance.num, min_luma_den, mdm->min_luminance.den));

        *data = buf;
        *size = 24;
        return 1;
    }

    if (metadata_type == AV1_METADATA_TYPE_HDR_CLL && sd_cll) {
        const AVContentLightMetadata *cll = (const AVContentLightMetadata *)sd_cll->data;
        uint8_t *buf, *q;

        buf = q = av_malloc(4);
        if (!buf)
            return AVERROR(ENOMEM);

        bytestream_put_be16(&q, cll->MaxCLL);
        bytestream_put_be16(&q, cll->MaxFALL);

        *data = buf;
        *size = 4;
        return 1;
    }

    return 0;
}

"""

anchor = 'static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)'
if s.count(anchor) != 1:
    raise SystemExit(f"{p}: prepare_sei_data_array anchor not unique")
s = s.replace(anchor, helper + anchor, 1)

call_old = '    if (!ctx->udu_sei)\n        return sei_count;\n'
call_new = r"""    if (avctx->codec->id == AV_CODEC_ID_AV1) {
        static const int hdr_static_types[] = {
            AV1_METADATA_TYPE_HDR_MDCV, AV1_METADATA_TYPE_HDR_CLL,
        };
        size_t t;

        for (t = 0; t < FF_ARRAY_ELEMS(hdr_static_types); t++) {
            uint8_t *payload_data = NULL;
            size_t payload_size = 0;
            void *tmp;

            res = nvenc_alloc_hdr_static_payload(frame, hdr_static_types[t],
                                                 &payload_data, &payload_size);
            if (res < 0)
                goto error;
            if (res == 0)
                continue;

            tmp = av_fast_realloc(ctx->sei_data, &ctx->sei_data_size,
                                  (sei_count + 1) * sizeof(*ctx->sei_data));
            if (!tmp) {
                av_free(payload_data);
                res = AVERROR(ENOMEM);
                goto error;
            }

            ctx->sei_data = tmp;
            ctx->sei_data[sei_count].payloadSize = (uint32_t)payload_size;
            ctx->sei_data[sei_count].payload = payload_data;
            ctx->sei_data[sei_count].payloadType = hdr_static_types[t];
            sei_count++;
        }
    }

""" + call_old
if s.count(call_old) != 1:
    raise SystemExit(f"{p}: udu_sei anchor not unique")
s = s.replace(call_old, call_new, 1)

p.write_text(s)
PYNVENCSTATIC
}


patch_ffmpeg_nvenc_dovi_p8_p10() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"
  local nvenc_h="$ff_stage/libavcodec/nvenc.h"

  if grep -q 'nvenc_alloc_dovi_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC AV1 Dolby Vision HEVC P8 / AV1 P10 passthrough patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg NVENC HEVC P8 / AV1 P10 Dolby Vision RPU injection =="
  python3 - "$nvenc_h" "$nvenc_c" <<'PYDOVINVENC'
from pathlib import Path
import sys

header, source = map(Path, sys.argv[1:])

def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected one patch anchor, found {text.count(old)}: {old[:72]!r}")
    path.write_text(text.replace(old, new, 1))

replace_once(
    header,
    '#include "avcodec.h"\n',
    '#include "avcodec.h"\n#include "dovi_rpu.h"\n',
)
replace_once(
    header,
    '    NV_ENC_SEI_PAYLOAD *sei_data;\n    int sei_data_size;\n',
    '    NV_ENC_SEI_PAYLOAD *sei_data;\n    int sei_data_size;\n    DOVIContext dovi;\n',
)
replace_once(
    source,
    '    int i, res;\n\n    if (ctx->a53_cc && av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC)) {\n',
    r'''    int i, res;

#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
    if (avctx->codec->id == AV_CODEC_ID_AV1 ||
        avctx->codec->id == AV_CODEC_ID_HEVC) {
        uint8_t *dovi_data = NULL;
        int dovi_size = 0;

        res = nvenc_alloc_dovi_payload(avctx, ctx, frame, &dovi_data, &dovi_size);
        if (res < 0)
            goto error;
        if (dovi_data) {
            void *tmp;
            if (dovi_size <= 0) {
                av_free(dovi_data);
                res = AVERROR_INVALIDDATA;
                goto error;
            }
            tmp = av_fast_realloc(ctx->sei_data, &ctx->sei_data_size,
                                  (sei_count + 1) * sizeof(*ctx->sei_data));
            if (!tmp) {
                av_free(dovi_data);
                res = AVERROR(ENOMEM);
                goto error;
            }
            ctx->sei_data = tmp;
            ctx->sei_data[sei_count].payloadSize = (uint32_t)dovi_size;
            if (avctx->codec->id == AV_CODEC_ID_AV1)
                ctx->sei_data[sei_count].payloadType = AV1_METADATA_TYPE_ITUT_T35;
            else
                ctx->sei_data[sei_count].payloadType = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
            ctx->sei_data[sei_count].payload = dovi_data;
            sei_count++;
        }
    }
#endif

    if (!ctx->extra_sei)
        return sei_count;

    if (ctx->a53_cc && av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC)) {
''',
)
replace_once(
    source,
    'static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)\n',
    r'''#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
static int nvenc_alloc_dovi_payload(AVCodecContext *avctx, NvencContext *ctx,
                                        const AVFrame *frame, uint8_t **data,
                                        int *size)
{
    const AVFrameSideData *sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);

    *data = NULL;
    *size = 0;
    if (!sd)
        return 0;
    if (!ctx->dovi.cfg.dv_profile) {
        av_log(avctx, AV_LOG_ERROR,
               "Dolby Vision metadata is present, but a valid Dolby Vision codec configuration "
               "could not be derived. Preserve 10-bit 4:2:0 and the source color tags.\n");
        return AVERROR_INVALIDDATA;
    }

    return ff_dovi_rpu_generate(&ctx->dovi,
                                (const AVDOVIMetadata *)sd->data,
                                FF_DOVI_WRAP_T35, data, size);
}
#endif

static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
''',
)
replace_once(
    source,
    '        if (ctx->extra_sei) {\n            res = prepare_sei_data_array(avctx, frame);\n',
    r'''        if (ctx->extra_sei
#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
            || ((avctx->codec->id == AV_CODEC_ID_AV1 ||
                 avctx->codec->id == AV_CODEC_ID_HEVC) &&
                av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA))
#endif
        ) {
            res = prepare_sei_data_array(avctx, frame);
''',
)
replace_once(
    source,
    '    NvencContext *ctx = avctx->priv_data;\n    int ret;\n\n    if (IS_HWACCEL(avctx->pix_fmt)) {\n',
    r'''    NvencContext *ctx = avctx->priv_data;
    int ret;

#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
    if (avctx->codec->id == AV_CODEC_ID_AV1 ||
        avctx->codec->id == AV_CODEC_ID_HEVC) {
        const enum AVPixelFormat pix_fmt = avctx->pix_fmt;

        ctx->dovi.logctx = avctx;
        ctx->dovi.enable = FF_DOVI_AUTOMATIC;
        if (ctx->data_pix_fmt == AV_PIX_FMT_P010)
            avctx->pix_fmt = AV_PIX_FMT_YUV420P10;
        ret = ff_dovi_configure(&ctx->dovi, avctx);
        avctx->pix_fmt = pix_fmt;
        if (ret < 0)
            return ret;
    }
#endif

    if (IS_HWACCEL(avctx->pix_fmt)) {
''',
)
replace_once(
    source,
    '    int i, res;\n\n    /* the encoder has to be flushed before it can be closed */\n',
    '    int i, res;\n\n#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER\n    ff_dovi_ctx_unref(&ctx->dovi);\n#endif\n\n    /* the encoder has to be flushed before it can be closed */\n',
)
PYDOVINVENC
}


patch_ffmpeg_nvenc_hdr10plus() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"

  if grep -q 'nvenc_alloc_hdr10_plus_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC HDR10+ passthrough patch already applied"
    return 0
  fi
  if grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$nvenc_c"; then
    echo "FFmpeg NVENC already contains HDR10+ side-data handling; skip local patch"
    return 0
  fi

  echo "== Patch FFmpeg NVENC HDR10+ passthrough =="
  git -C "$ff_stage" apply --recount --whitespace=nowarn <<'PATCH_NVENC_HDR10PLUS'
diff --git a/libavcodec/nvenc.c b/libavcodec/nvenc.c
index 5ea094e095..0b138e1ccd 100644
--- a/libavcodec/nvenc.c
+++ b/libavcodec/nvenc.c
@@ -31,6 +31,7 @@
 #include "libavutil/hwcontext_cuda.h"
 #include "libavutil/hwcontext.h"
 #include "libavutil/cuda_check.h"
+#include "libavutil/hdr_dynamic_metadata.h"
 #include "libavutil/imgutils.h"
 #include "libavutil/mem.h"
 #include "libavutil/pixdesc.h"
@@ -40,9 +41,11 @@
 #include "libavutil/stereo3d.h"
 #include "libavutil/tdrdi.h"
 #include "atsc_a53.h"
+#include "bytestream.h"
 #include "codec_desc.h"
 #include "encode.h"
 #include "internal.h"
+#include "itut35.h"
 
 #define CHECK_CU(x) FF_CUDA_CHECK_DL(avctx, dl_fn->cuda_dl, x)
 
@@ -2723,6 +2726,47 @@ static int output_ready(AVCodecContext *avctx, int flush)
     return (nb_ready > 0) && (nb_ready + nb_pending >= ctx->async_depth);
 }
 
+static int nvenc_alloc_hdr10_plus_payload(const AVFrame *frame, uint8_t **data, size_t *size)
+{
+    const AVFrameSideData *side_data =
+        av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
+    const AVDynamicHDRPlus *hdr_plus;
+    uint8_t *payload;
+    size_t payload_size;
+    int ret;
+
+    if (!side_data) {
+        *data = NULL;
+        *size = 0;
+        return 0;
+    }
+
+    hdr_plus = (const AVDynamicHDRPlus *)side_data->data;
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, NULL, &payload_size);
+    if (ret < 0)
+        return ret;
+
+    *size = payload_size + 6;
+    *data = av_malloc(*size);
+    if (!*data)
+        return AVERROR(ENOMEM);
+
+    payload = *data;
+    bytestream_put_byte(&payload, ITU_T_T35_COUNTRY_CODE_US);
+    bytestream_put_be16(&payload, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
+    bytestream_put_be16(&payload, 0x0001);
+    bytestream_put_byte(&payload, 0x04);
+
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, &payload, &payload_size);
+    if (ret < 0) {
+        av_freep(data);
+        *size = 0;
+        return ret;
+    }
+
+    return 1;
+}
+
 static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
 {
     NvencContext *ctx = avctx->priv_data;
@@ -2797,6 +2841,43 @@ static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
         }
     }
 
+    if (avctx->codec->id == AV_CODEC_ID_HEVC
+#if CONFIG_AV1_NVENC_ENCODER
+        || avctx->codec->id == AV_CODEC_ID_AV1
+#endif
+    ) {
+        uint8_t *hdr_plus_data = NULL;
+        size_t hdr_plus_size = 0;
+
+        res = nvenc_alloc_hdr10_plus_payload(frame, &hdr_plus_data, &hdr_plus_size);
+        if (res < 0) {
+            av_log(ctx, AV_LOG_ERROR, "Error serializing HDR10+ metadata\n");
+            goto error;
+        }
+
+        if (res > 0) {
+            void *tmp = av_fast_realloc(ctx->sei_data,
+                                        &ctx->sei_data_size,
+                                        (sei_count + 1) * sizeof(*ctx->sei_data));
+            if (!tmp) {
+                av_free(hdr_plus_data);
+                res = AVERROR(ENOMEM);
+                goto error;
+            }
+
+            ctx->sei_data = tmp;
+            ctx->sei_data[sei_count].payloadSize = (uint32_t)hdr_plus_size;
+            ctx->sei_data[sei_count].payload = hdr_plus_data;
+#if CONFIG_AV1_NVENC_ENCODER
+            if (avctx->codec->id == AV_CODEC_ID_AV1)
+                ctx->sei_data[sei_count].payloadType = AV1_METADATA_TYPE_ITUT_T35;
+            else
+#endif
+                ctx->sei_data[sei_count].payloadType = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
+            sei_count++;
+        }
+    }
+
     if (!ctx->udu_sei)
         return sei_count;
PATCH_NVENC_HDR10PLUS
}

validate_config() {
  local config_mak="$1" config_h="$2" unexpected allowed filter_line filter_name filter_lower f found feature
  local allowed_filters=("${COMMON_FILTERS[@]}")
  if [[ "$BACKEND" == "nvenc" ]]; then
    allowed_filters+=("${NVENC_FILTERS[@]}")
  else
    allowed_filters+=("${QSV_FILTERS[@]}")
  fi
  [[ "$LTO_ENABLE" != "1" ]] || grep -Eq -- '-flto(=thin|=auto)?' "$config_mak" || { echo "LTO not found in config.mak"; exit 1; }
  grep -q '^CONFIG_AAC_ENCODER=yes$' "$config_mak" || { echo "native AAC encoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBOPUS=yes$' "$config_mak" || { echo "libopus disabled"; exit 1; }
  grep -q '^CONFIG_LIBOPUS_ENCODER=yes$' "$config_mak" || { echo "libopus encoder disabled"; exit 1; }
  grep -q '^CONFIG_OPUS_DECODER=yes$' "$config_mak" || { echo "native Opus decoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBSOXR=yes$' "$config_mak" || { echo "libsoxr disabled"; exit 1; }
  grep -q '^CONFIG_LIBJXR=yes$' "$config_mak" || { echo "libjxr disabled"; exit 1; }
  grep -q '^CONFIG_LIBJXR_ENCODER=yes$' "$config_mak" || { echo "libjxr encoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBJXR_DECODER=yes$' "$config_mak" || { echo "libjxr decoder disabled"; exit 1; }
  grep -q '^CONFIG_ARESAMPLE_FILTER=yes$' "$config_mak" || { echo "aresample filter disabled"; exit 1; }
  grep -q '^CONFIG_LIBPLACEBO_FILTER=yes$' "$config_mak" || { echo "libplacebo filter disabled"; exit 1; }
  grep -q '^CONFIG_VULKAN=yes$' "$config_mak" || { echo "Vulkan disabled"; exit 1; }
  for feature in CONFIG_HEVC_DECODER CONFIG_AV1_DECODER CONFIG_DOVI_RPUDEC CONFIG_DOVI_RPUENC CONFIG_DOVI_RPU_BSF CONFIG_DOVI_SPLIT_BSF CONFIG_MOV_DEMUXER CONFIG_MOV_MUXER CONFIG_MATROSKA_DEMUXER CONFIG_MATROSKA_MUXER CONFIG_MPEGTS_DEMUXER CONFIG_MPEGTS_MUXER; do
    grep -q "^$feature=yes$" "$config_mak" || { echo "Dolby Vision feature disabled: $feature"; exit 1; }
  done
  [[ -s "$PREFIX/lib/libshaderc_combined.a" && -d "$PREFIX/include/shaderc" ]] || { echo "libshaderc static library or headers missing"; exit 1; }
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists shaderc || { echo "shaderc.pc is not usable"; exit 1; }

  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '^CONFIG_AV1_NVENC_ENCODER=yes$' "$config_mak" || { echo "av1_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_NVENC_ENCODER=yes$' "$config_mak" || { echo "hevc_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_CUDA_NVCC=yes$' "$config_mak" || { echo "cuda-nvcc disabled"; exit 1; }
    allowed='CONFIG_(HEVC_NVENC|AV1_NVENC|AAC|LIBOPUS|LIBJXR|RAWVIDEO)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
    grep -q 'nonfree' "$config_h" || { echo "NVENC build is expected to be nonfree"; exit 1; }
  else
    grep -q '^CONFIG_AV1_QSV_ENCODER=yes$' "$config_mak" || { echo "av1_qsv disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_QSV_ENCODER=yes$' "$config_mak" || { echo "hevc_qsv disabled"; exit 1; }
    grep -q '^CONFIG_LIBVPL=yes$' "$config_mak" || { echo "libvpl disabled"; exit 1; }
    allowed='CONFIG_(HEVC_QSV|AV1_QSV|AAC|LIBOPUS|LIBJXR|RAWVIDEO)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
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
  local exe="$1" output filters hwaccels decoders bsfs muxers placebo_help name
  local names=()
  output="$("$exe" -hide_banner -encoders 2>/dev/null | tr -d '\r')"
  mapfile -t names < <(awk '$1 ~ /^[VAS][A-Z.]{5}$/ && $2 != "=" { print $2 }' <<< "$output")
  for name in "${names[@]}"; do
    case "$BACKEND:$name" in
      nvenc:aac|nvenc:hevc_nvenc|nvenc:av1_nvenc|nvenc:libopus|nvenc:libjxr|nvenc:rawvideo|qsv:aac|qsv:hevc_qsv|qsv:av1_qsv|qsv:libopus|qsv:libjxr|qsv:rawvideo) ;;
      *) echo "unexpected runtime encoder: $name"; exit 1 ;;
    esac
  done
  grep -q '[[:space:]]libopus[[:space:]]' <<< "$output" || { echo "libopus missing"; exit 1; }
  grep -q '[[:space:]]opus[[:space:]]' <<< "$("$exe" -hide_banner -decoders 2>/dev/null)" || { echo "native opus decoder missing"; exit 1; }
  grep -q '[[:space:]]libjxr[[:space:]]' <<< "$output" || { echo "libjxr encoder missing"; exit 1; }
  grep -q '[[:space:]]libjxr[[:space:]]' <<< "$("$exe" -hide_banner -decoders 2>/dev/null)" || { echo "libjxr decoder missing"; exit 1; }
  grep -q 'nmr' <<< "$("$exe" -hide_banner -h encoder=aac 2>&1)" || { echo "NMR AAC coder missing"; exit 1; }
  placebo_help="$("$exe" -hide_banner -h filter=libplacebo 2>&1)"
  grep -q 'libplacebo' <<< "$placebo_help" || { echo "libplacebo filter help failed"; exit 1; }
  grep -q 'apply_dolbyvision' <<< "$placebo_help" || { echo "libplacebo Dolby Vision metadata application missing"; exit 1; }
  decoders="$("$exe" -hide_banner -decoders 2>/dev/null | tr -d '\r')"
  for name in hevc av1; do
    grep -Eq "[[:space:]]$name([[:space:]]|$)" <<< "$decoders" || { echo "Dolby Vision base codec decoder missing: $name"; exit 1; }
  done
  bsfs="$("$exe" -hide_banner -bsfs 2>/dev/null | tr -d '\r')"
  for name in dovi_rpu dovi_split; do
    grep -Eq "(^|[[:space:]])$name([[:space:]]|$)" <<< "$bsfs" || { echo "Dolby Vision bitstream filter missing: $name"; exit 1; }
  done
  muxers="$("$exe" -hide_banner -muxers 2>/dev/null | tr -d '\r')"
  for name in mov matroska; do
    grep -Eq "[[:space:]]$name([[:space:]]|$)" <<< "$muxers" || { echo "Dolby Vision container muxer missing: $name"; exit 1; }
  done
  filters="$("$exe" -hide_banner -filters 2>/dev/null | tr -d '\r')"
  hwaccels="$("$exe" -hide_banner -hwaccels 2>/dev/null | tr -d '\r')"
  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '[[:space:]]av1_nvenc[[:space:]]' <<< "$output" || { echo "av1_nvenc missing"; exit 1; }
    grep -Eq 'b_ref_mode|hierarchical.*[Bb]|[Bb].*hierarchical' <<< "$("$exe" -hide_banner -h encoder=av1_nvenc 2>&1)" || {
      echo "av1_nvenc hierarchical B-reference option missing"
      exit 1
    }
    grep -q '[[:space:]]scale_cuda[[:space:]]' <<< "$filters" || { echo "scale_cuda missing"; exit 1; }
    grep -qx 'cuda' <<< "$hwaccels" || { echo "CUDA hwaccel missing"; exit 1; }
  else
    grep -q '[[:space:]]av1_qsv[[:space:]]' <<< "$output" || { echo "av1_qsv missing"; exit 1; }
    grep -q '[[:space:]]scale_qsv[[:space:]]' <<< "$filters" || { echo "scale_qsv missing"; exit 1; }
    grep -Eq '^(d3d11va|dxva2)$' <<< "$hwaccels" || { echo "QSV Windows hwaccel missing"; exit 1; }
  fi
}

verify_opus_roundtrip() {
  local exe="$1" test_dir="$BUILDROOT/opus-validation"
  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  dd if=/dev/zero of="$test_dir/input.s16" bs=192000 count=1 status=none
  "$exe" -hide_banner -loglevel error \
    -f s16le -ar 48000 -ac 2 -i "$test_dir/input.s16" \
    -c:a libopus -b:a 96k -ar 48000 -ac 2 -f ogg "$test_dir/test.ogg"
  "$exe" -hide_banner -loglevel error \
    -i "$test_dir/test.ogg" -map 0:a:0 -c:a libopus -b:a 96k -ar 48000 -ac 2 -f ogg "$test_dir/decoded.ogg"
  [[ -s "$test_dir/test.ogg" && -s "$test_dir/decoded.ogg" ]] || {
    echo "libopus encode/decode output is empty"
    exit 1
  }
  echo "Opus 48 kHz stereo encode/decode: OK"
}

verify_nvenc_hierarchical() {
  local exe="$1" test_dir="$BUILDROOT/nvenc-validation"
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    HARDWARE_STATUS="skipped"
    echo "Skipped NVENC hierarchical B-reference runtime test: no NVIDIA GPU"
    return 0
  fi
  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  dd if=/dev/zero of="$test_dir/input.yuv" bs=393216 count=8 status=none
  "$exe" -hide_banner -loglevel error \
    -f rawvideo -pix_fmt yuv420p -s:v 512x512 -r 1 -i "$test_dir/input.yuv" \
    -frames:v 8 -c:v av1_nvenc -g 8 -bf 3 -b_ref_mode hierarchical -f null -
  HARDWARE_STATUS="passed"
  echo "NVENC AV1 hierarchical B-reference runtime invocation: OK"
}

write_build_manifest() {
  local manifest_tool="$ROOT/build-manifests/write_manifest.py"
  local args=(
    python3 "$manifest_tool"
    --root "$ROOT"
    --build-name "nvenc-lite"
    --prefix "$PREFIX"
    --artifact-dir "$SCRIPT_DIR"
    --configure-file "$BUILDROOT/ffmpeg-configure.args"
    --config-mak "$BUILDROOT/ffmpeg/ffbuild/config.mak"
    --started "$BUILD_STARTED_AT"
    --target-platform "Windows x86_64 via $TARGET"
    --cpu-minimum "$CPU_FLAGS"
    --source-repo "ffmpeg-source=$ROOT/ffmpeg-source"
  )
  local stage source
  for stage in "${STAGES[@]}"; do
    [[ "$stage" == "ffmpeg" ]] && continue
    source="$(source_dir "$stage")"
    args+=(--source-repo "$stage=$source")
  done
  args+=(
    --validate "target-prefix opus.pc, opus headers, and static libopus checked"
    --validate "FFmpeg configure enabled libopus, libopus encoder, and native opus decoder"
    --validate "final encoder whitelist contains AAC, libopus, and only expected video encoders"
    --validate "48 kHz stereo Ogg Opus encode and final-ffmpeg decode/re-encode roundtrip succeeded"
    --validate "native NMR AAC option remains present"
    --validate "NVENC HDR10+ dynamic metadata passthrough source path compiled"
    --validate "Dolby Vision HEVC Profile 8 and AV1 Profile 10 per-frame RPU injection paths compiled"
    --skip "NVENC Dolby Vision P8/P10 injection was not round-trip tested on compatible hardware with Dolby Vision samples"
    --validate "JPEG XR jxrlib encoder/decoder configured and lossless RGB24 round-trip passed"
  )
  if [[ "$HARDWARE_STATUS" == "passed" ]]; then
    args+=(--validate "AV1 NVENC hierarchical B-reference option present and runtime invocation succeeded; bitstream B-frame production not independently confirmed")
  else
    args+=(--skip "AV1 NVENC hierarchical B-reference runtime encode skipped because no NVIDIA GPU was available")
  fi
  "${args[@]}" >/dev/null
  echo "Build source manifest written for nvenc-lite"
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
      local api_header="$PREFIX/include/ffnvcodec/nvEncodeAPI.h"
      local api_major api_minor
      api_major="$(sed -n 's/^#define NVENCAPI_MAJOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      api_minor="$(sed -n 's/^#define NVENCAPI_MINOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      ((api_major > 13 || (api_major == 13 && api_minor >= 1))) || {
        echo "NVENC API $api_major.$api_minor is below required 13.1"
        exit 1
      }
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

    opus)
      build_opus
      ;;

    libvpl)
      build_cmake libvpl -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DINSTALL_EXAMPLES=OFF -DENABLE_WARNINGS=OFF
      ;;

    libsoxr)
      build_cmake libsoxr -Wno-dev --no-warn-unused-cli -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.10
      write_soxr_pc
      ;;

    jxrlib)
      build_jxrlib
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
        -Ddovi=enabled \
        -Dlibdovi=disabled \
        -Dxxhash=disabled
      meson compile -C "$b" -j "$JOBS"
      meson install -C "$b"
      grep -q '^#define PL_HAVE_DOVI 1$' "$PREFIX/include/libplacebo/config.h" || {
        echo "libplacebo Dolby Vision support is disabled"
        exit 1
      }
      grep -q '^pl_has_vk_proc_addr=1' "$PREFIX/lib/pkgconfig/libplacebo.pc" || { echo "libplacebo did not link Vulkan proc addr"; exit 1; }
      ;;

    ffmpeg)
      [[ "$BACKEND" == "nvenc" ]] && setup_cuda
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists soxr libjxr libplacebo shaderc vulkan || { echo "required pkg-config files missing"; exit 1; }
      [[ "$BACKEND" == "qsv" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vpl || { [[ "$BACKEND" == "nvenc" ]] || exit 1; }
      [[ "$BACKEND" == "nvenc" ]] && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || { [[ "$BACKEND" == "qsv" ]] || exit 1; }

      local ff_stage ff_bld extra_cflags extra_ldflags extra_libs ffmpeg_nvccflags
      ff_stage="$(stage_src ffmpeg-source)"
      "$ROOT/shared-patches/apply-ffmpeg-patches.sh" "$ff_stage" lite
      patch_ffmpeg_jxr "$ff_stage"
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage"
      patch_ffmpeg_nvenc_hdr10plus "$ff_stage"
      patch_ffmpeg_nvenc_dovi_p8_p10 "$ff_stage"
      grep -q 'nvenc_alloc_dovi_payload' "$ff_stage/libavcodec/nvenc.c" || {
        echo "FFmpeg NVENC Dolby Vision HEVC P8 / AV1 P10 source patch is missing"
        exit 1
      }
      patch_ffmpeg_nvenc_hdr_static "$ff_stage"
      grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$ff_stage/libavcodec/nvenc.c" || {
        echo "FFmpeg NVENC HDR10+ passthrough is missing"
        exit 1
      }
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
        --enable-libopus
        --enable-libsoxr
        --enable-libjxr
        --enable-vulkan
        --enable-vulkan-static
        --enable-libplacebo
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
          --glslc="$HOST_TOOLS/bin/glslc"
          --enable-vapoursynth
        )
      else
        configure_cmd+=(--enable-libvpl --enable-d3d11va --enable-dxva2)
      fi

      configure_cmd+=(--disable-encoders)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for e in hevc_nvenc av1_nvenc aac libopus libjxr rawvideo; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      else
        for e in hevc_qsv av1_qsv aac libopus libjxr rawvideo; do add_if_exists "$ff_stage" --list-encoders "$e" --enable-encoder; done
      fi

      configure_cmd+=(--disable-decoders)
      for d in h264 hevc av1 vp9 vp8 mpeg2video mpeg4 msmpeg4v3 vc1 wmv3 mjpeg prores rawvideo libjxr aac aac_latm mp3 ac3 eac3 truehd dca flac opus vorbis wavpack alac pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le; do
        add_if_exists "$ff_stage" --list-decoders "$d" --enable-decoder
      done

      configure_cmd+=(--disable-hwaccels)
      if [[ "$BACKEND" == "nvenc" ]]; then
        for h in h264_nvdec hevc_nvdec av1_nvdec vp9_nvdec vp8_nvdec mjpeg_nvdec mpeg2_nvdec mpeg4_nvdec vc1_nvdec wmv3_nvdec; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      else
        for h in h264_d3d11va hevc_d3d11va av1_d3d11va vp9_d3d11va h264_dxva2 hevc_dxva2 av1_dxva2 vp9_dxva2 vc1_dxva2 mpeg2_dxva2; do add_if_exists "$ff_stage" --list-hwaccels "$h" --enable-hwaccel; done
      fi

      configure_cmd+=(--disable-demuxers)
      for d in matroska mov mpegts h264 hevc av1 rawvideo pcm_s16le image2 concat aac mp3 flac ogg wav vapoursynth; do add_if_exists "$ff_stage" --list-demuxers "$d" --enable-demuxer; done
      configure_cmd+=(--disable-muxers)
      for m in matroska mp4 mov ipod mpegts null rawvideo image2 adts wav flac ogg; do add_if_exists "$ff_stage" --list-muxers "$m" --enable-muxer; done
      configure_cmd+=(--disable-parsers)
      for p in h264 hevc av1 aac ac3 dca mlp opus vorbis mjpeg vp9 vp8 mpeg4video vc1; do add_if_exists "$ff_stage" --list-parsers "$p" --enable-parser; done
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
      verify_opus_roundtrip "$SCRIPT_DIR/ffmpeg.exe"
      verify_jxr_binary "$SCRIPT_DIR/ffmpeg.exe" "$BUILDROOT/jxr-validation"
      verify_nvenc_hierarchical "$SCRIPT_DIR/ffmpeg.exe"
      ;;

    *) echo "unknown stage: $stage"; exit 1 ;;
  esac
}

run_build() {
  BUILD_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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
  write_build_manifest
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
