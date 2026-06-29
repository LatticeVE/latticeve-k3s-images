#!/bin/bash
# Builds a Firecracker-compatible guest kernel (vmlinux) from upstream kernel
# source, using the kernel config fragments Firecracker publishes for known-good
# microVM boots (virtio-mmio, ext4, vsock built in; no modules).
#
# Run on an x86_64 or aarch64 Linux host with build-essential/bc/flex/bison/
# libelf-dev/libssl-dev installed.
#
#   KERNEL_VERSION=6.1.128 ARCH=x86_64 ./build.sh
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-6.1.128}"
ARCH="${ARCH:-x86_64}"
KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
# Firecracker ships guest configs per kernel branch (e.g. microvm-kernel-ci-x86_64-6.1.config).
CONFIG_BRANCH="${CONFIG_BRANCH:-$(echo "$KERNEL_VERSION" | cut -d. -f1,2)}"

case "$ARCH" in
  x86_64) FC_ARCH="x86_64"; KARCH="x86" ;;
  aarch64) FC_ARCH="aarch64"; KARCH="arm64" ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac

WORK="${WORK:-$(pwd)}"
cd "$WORK"

SRC_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
if [ ! -f "$SRC_TARBALL" ]; then
    echo "downloading linux $KERNEL_VERSION source"
    wget -qO "$SRC_TARBALL" \
        "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${SRC_TARBALL}"
fi

rm -rf "linux-${KERNEL_VERSION}"
tar -xJf "$SRC_TARBALL"
cd "linux-${KERNEL_VERSION}"

CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-ci-${FC_ARCH}-${CONFIG_BRANCH}.config"
echo "fetching firecracker guest config: $CONFIG_URL"
if ! wget -qO .config "$CONFIG_URL"; then
    echo "no exact config for branch $CONFIG_BRANCH, falling back to closest available list" >&2
    wget -qO- "https://api.github.com/repos/firecracker-microvm/firecracker/contents/resources/guest_configs" \
        | grep -o "microvm-kernel-ci-${FC_ARCH}-[0-9.]*\.config" | sort -V | tail -1 > /tmp/fallback_name
    FALLBACK="$(cat /tmp/fallback_name)"
    [ -n "$FALLBACK" ] || { echo "no firecracker guest config found for $FC_ARCH" >&2; exit 1; }
    wget -qO .config "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/$FALLBACK"
fi

make ARCH="$KARCH" olddefconfig
make ARCH="$KARCH" -j"$(nproc)" vmlinux

OUT="../vmlinux-${KERNEL_VERSION}-${FC_ARCH}"
cp vmlinux "$OUT"
cd ..
echo "=== built ==="; ls -la "$OUT"
echo "kernel_version=$KERNEL_VERSION" > "${OUT}.meta"
echo "arch=$FC_ARCH" >> "${OUT}.meta"
