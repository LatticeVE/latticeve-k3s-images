#!/bin/bash
# Builds the LatticeVE k3s-on-Firecracker root filesystem (ext4) that the
# kube bootstrap boots as a microVM. The guest reads its role/token/server/etc.
# from Firecracker MMDS at boot (see k3s-bootstrap, the OpenRC service alongside).
#
# Reproducible: downloads a pinned Alpine minirootfs + k3s binary (reusing local
# copies if already present). Run on an x86_64 Linux host with root (needs
# chroot + mke2fs). Produces ./k3s-rootfs-<arch>.ext4.
#
#   ALPINE_VERSION=3.21.7 K3S_VERSION=v1.31.5+k3s1 ./build.sh
set -euo pipefail

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.21}"
ALPINE_VERSION="${ALPINE_VERSION:-3.21.7}"
K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"
ARCH="${ARCH:-x86_64}"
ROOTFS_SIZE="${ROOTFS_SIZE:-3G}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(pwd)}"
cd "$WORK"
R="rootfs"
OUT="k3s-rootfs-${ARCH}.ext4"

# --- fetch inputs (reuse local copies if present) ---------------------------
if [ ! -f mini.tar.gz ]; then
    echo "downloading alpine minirootfs $ALPINE_VERSION"
    wget -qO mini.tar.gz \
        "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/$ARCH/alpine-minirootfs-$ALPINE_VERSION-$ARCH.tar.gz"
fi
if [ ! -f k3s ]; then
    echo "downloading k3s $K3S_VERSION"
    wget -qO k3s "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s"
    chmod +x k3s
fi

# --- assemble rootfs --------------------------------------------------------
rm -rf "$R"; mkdir -p "$R"
tar -xzf mini.tar.gz -C "$R"
install -m0755 k3s "$R/usr/local/bin/k3s"
mkdir -p "$R/etc/init.d" "$R/etc/network"

echo "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main" > "$R/etc/apk/repositories"
echo "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community" >> "$R/etc/apk/repositories"
cp /etc/resolv.conf "$R/etc/resolv.conf"

cat > "$R/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

# The k3s bootstrap OpenRC service (kept as a repo file, not inlined).
install -m0755 "$SCRIPT_DIR/k3s-bootstrap" "$R/etc/init.d/k3s-bootstrap"

# cgroups v2 unified (k3s requires a sane cgroup mount) + drop ttyN gettys
# (Firecracker only has ttyS0) so the console doesn't flood.
echo 'rc_cgroup_mode="unified"' >> "$R/etc/rc.conf"
sed -i '/^tty[1-6]/d' "$R/etc/inittab"

chroot "$R" /bin/sh -c '
  set -e
  apk add --no-cache openrc iproute2 >/dev/null 2>&1
  # A bare minirootfs leaves sysinit/boot runlevels empty -> no cgroup/sysfs mount
  # -> k3s fatals "unhandled cgroup mode". Populate them explicitly.
  for s in devfs dmesg sysfs cgroups hwdrivers; do rc-update add $s sysinit; done
  for s in procfs bootmisc modules hostname sysctl seedrng localmount; do rc-update add $s boot; done
  rc-update add networking boot
  rc-update add k3s-bootstrap default
  passwd -d root
' 2>&1 | tail -3

rm -f "$R/etc/resolv.conf"
rm -f "$OUT"
mke2fs -q -t ext4 -d "$R" "$OUT" "$ROOTFS_SIZE"
echo "=== built ==="; ls -la "$OUT"
echo "=== default runlevel ==="; ls "$R/etc/runlevels/default"
echo "k3s_version=$K3S_VERSION" > "${OUT}.meta"
echo "alpine_version=$ALPINE_VERSION" >> "${OUT}.meta"
echo "arch=$ARCH" >> "${OUT}.meta"
