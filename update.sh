#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$HOME/ffmpeg}"

# 只保留当前目标实际需要的源码：FFmpeg、NVIDIA headers、fdk-aac、字幕/字体/缩放相关库。
# SVT-AV1 已按目标删除；AV1 只使用 av1_nvenc。
declare -A URLS=(
  [ffmpeg-source]="https://git.ffmpeg.org/ffmpeg.git"
  [nv-codec-headers]="https://github.com/FFmpeg/nv-codec-headers.git"
  [fdk-aac]="https://github.com/mstorsjo/fdk-aac.git"
  [zimg]="https://github.com/sekrit-twc/zimg.git"
  [freetype]="https://github.com/freetype/freetype.git"
  [harfbuzz]="https://github.com/harfbuzz/harfbuzz.git"
  [fribidi]="https://github.com/fribidi/fribidi.git"
  [libass]="https://github.com/libass/libass.git"
  [fontconfig]="https://gitlab.freedesktop.org/fontconfig/fontconfig.git"
  [expat]="https://github.com/libexpat/libexpat.git"
)

declare -A TAG_REGEX=(
  [ffmpeg-source]='^n[0-9]+(\.[0-9]+)*$'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [fdk-aac]='^v?[0-9]+(\.[0-9]+)*$'
  [zimg]='^release-[0-9]+(\.[0-9]+)*$'
  [freetype]='^(VER-[0-9]+(-[0-9]+)+|freetype-[0-9]+(\.[0-9]+)*)$'
  [harfbuzz]='^v?[0-9]+(\.[0-9]+)*$'
  [fribidi]='^v?[0-9]+(\.[0-9]+)*$'
  [libass]='^v?[0-9]+(\.[0-9]+)*$'
  [fontconfig]='^(upstream/)?[0-9]+(\.[0-9]+)*$'
  [expat]='^R_[0-9]+(_[0-9]+)+$'
)

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
    fontconfig)
      echo "${tag#upstream/}"
      ;;
    freetype)
      if [[ "$tag" == VER-* ]]; then
        echo "${tag#VER-}" | tr '-' '.'
      elif [[ "$tag" == freetype-* ]]; then
        echo "${tag#freetype-}"
      else
        echo "$tag"
      fi
      ;;
    expat)
      if [[ "$tag" == R_* ]]; then
        echo "${tag#R_}" | tr '_' '.'
      else
        echo "${tag#v}"
      fi
      ;;
    *)
      echo "${tag#v}"
      ;;
  esac
}

clone_if_missing() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local url="${URLS[$name]}"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "===> clone $name"
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
    git -C "$repo_dir" switch -C "build-$ver" "$tag"
  else
    git -C "$repo_dir" switch --detach "$tag" 2>/dev/null || \
    git -C "$repo_dir" checkout --detach "$tag"
  fi

  git -C "$repo_dir" submodule update --init --recursive || true
  echo "     -> $name => $tag"
}

update_one() {
  local name="$1"
  local repo_dir="$ROOT/$name"

  clone_if_missing "$name"

  echo "===> sanitize $name"
  sanitize_repo "$repo_dir"

  echo "===> fetch $name"
  git -C "$repo_dir" fetch --tags --prune origin

  local tag
  tag="$(latest_stable_tag "$name")"
  if [[ -z "$tag" ]]; then
    echo "ERROR: no stable tag matched for $name"
    exit 1
  fi

  checkout_stable "$name" "$tag"
}

usage() {
  cat <<EOF
用法:
  ./update.sh           # 更新完整 FFmpeg 构建所需源码，已不包含 SVT-AV1
  ./update.sh --fdkaac  # 只更新 fdkaac.sh 所需源码
EOF
}

main() {
  mkdir -p "$ROOT"

  local repos=(
    ffmpeg-source
    nv-codec-headers
    fdk-aac
    zimg
    freetype
    harfbuzz
    fribidi
    libass
    fontconfig
    expat
  )

  if [[ "$#" -gt 1 ]]; then
    usage
    exit 1
  fi

  if [[ "$#" -eq 1 ]]; then
    case "$1" in
      --fdkaac|fdkaac|--fdk-aac|fdk-aac)
        repos=(ffmpeg-source fdk-aac)
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  fi

  for r in "${repos[@]}"; do
    update_one "$r"
  done

  echo
  echo "All selected source trees are now on latest stable tags."
}

main "$@"
