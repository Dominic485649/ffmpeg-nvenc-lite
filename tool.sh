#!/usr/bin/env bash
set -euo pipefail

CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64"
CUDA_KEYRING="${CUDA_REPO}/cuda-keyring_1.1-1_all.deb"
CUDA_TOOLKIT_ENABLE="${CUDA_TOOLKIT_ENABLE:-1}"

echo "== Update apt =="
sudo apt update
sudo apt full-upgrade -y

echo
echo "== Install build toolchain =="
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

if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
  echo
  echo "== Install / update latest CUDA Toolkit for WSL =="
  tmpdeb="$(mktemp --suffix=.deb)"
  curl -fL --retry 3 -o "$tmpdeb" "$CUDA_KEYRING"
  sudo dpkg -i "$tmpdeb"
  rm -f "$tmpdeb"

  sudo apt update

  echo
  echo "== CUDA package candidate =="
  apt-cache policy cuda-toolkit || true

  echo
  echo "== Upgrade latest nvcc / CUDA Toolkit =="
  sudo apt install -y --no-install-recommends cuda-toolkit

  echo
  echo "== Configure CUDA environment =="
  if [ -d /usr/local/cuda ]; then
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
else
  echo
  echo "== Skip CUDA Toolkit =="
  echo "CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE"
fi

echo
echo "== Check versions =="
echo "[MinGW GCC]"
x86_64-w64-mingw32-gcc-posix --version | head -n 1

echo
echo "[MinGW G++]"
x86_64-w64-mingw32-g++-posix --version | head -n 1

echo
echo "[CMake]"
cmake --version | head -n 1

echo
echo "[Meson]"
meson --version

echo
echo "[NVCC]"
if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
  nvcc --version || true
else
  echo "skipped (CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE)"
fi

echo
echo "[NVIDIA-SMI]"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi
elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
  /usr/lib/wsl/lib/nvidia-smi
else
  echo "nvidia-smi not found"
fi

echo
echo "== CUDA disk usage =="
if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
  du -sh /usr/local/cuda* 2>/dev/null || true
else
  echo "skipped (CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE)"
fi

echo
echo "Done."