#!/bin/bash
# Builds the LatticeVE k3s-on-Firecracker root filesystem (ext4) that the
# kube bootstrap boots as a microVM. The guest reads its role/token/server/etc.
# from Firecracker MMDS at boot (see k3s-bootstrap, the OpenRC service alongside).
#
# Reproducible: downloads a pinned Alpine minirootfs + k3s binary (reusing local
# copies if already present). Run on a host of the matching arch with root
# (needs chroot + mke2fs). Produces ./k3s-rootfs-<amd64|arm64>.ext4.
#
#   ALPINE_VERSION=3.21.7 K3S_VERSION=v1.31.5+k3s1 ./build.sh
set -euo pipefail

ALPINE_VERSION="${ALPINE_VERSION:-3.21.7}"
# Alpine's release directory is keyed by branch (e.g. v3.21), not by the exact
# minirootfs patch version, so default it from ALPINE_VERSION's major.minor
# rather than hardcoding a branch that can drift out of sync with the version.
ALPINE_BRANCH="${ALPINE_BRANCH:-v$(echo "$ALPINE_VERSION" | cut -d. -f1,2)}"
K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"
# ARCH follows uname/Alpine convention (x86_64, aarch64) since that's what
# Alpine's download URLs and the chroot/mke2fs host both need. Output files
# are named with the Docker/Go convention (amd64, arm64) instead, since
# that's what LatticeVE and k3s's own release assets use.
ARCH="${ARCH:-x86_64}"
# ROOTFS_SIZE is computed dynamically from the assembled rootfs content (see
# below, right before mke2fs) unless explicitly overridden here.
ROOTFS_SIZE="${ROOTFS_SIZE:-}"

case "$ARCH" in
  x86_64)  GOARCH="amd64" ;;
  aarch64) GOARCH="arm64" ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(pwd)}"
cd "$WORK"
R="rootfs"
# BUILD_ID is the release build identifier (e.g. "r5", the CI run number),
# appended to the version so the artifact name carries "k3s version + build id".
# Empty for local builds.
BUILD_ID="${BUILD_ID:-}"
# Name the artifact "<k3s-version>[-<build-id>]-<arch>.ext4" (e.g.
# v1.36.2+k3s1-r5-amd64.ext4) — no "k3s-" prefix — so LatticeVE's discovery
# feed reads the full "version + build id" straight off the artifact name.
OUT="${K3S_VERSION}${BUILD_ID:+-$BUILD_ID}-${GOARCH}.ext4"

# --- fetch inputs (reuse local copies if present) ---------------------------
if [ ! -f mini.tar.gz ]; then
    echo "downloading alpine minirootfs $ALPINE_VERSION"
    wget -qO mini.tar.gz \
        "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/$ARCH/alpine-minirootfs-$ALPINE_VERSION-$ARCH.tar.gz"
fi
# k3s names its release asset per-arch: "k3s" for amd64, "k3s-arm64" for arm64.
case "$GOARCH" in
  amd64) K3S_ASSET="k3s" ;;
  arm64) K3S_ASSET="k3s-arm64" ;;
esac
if [ ! -f k3s ]; then
    echo "downloading k3s $K3S_VERSION ($K3S_ASSET)"
    wget -qO k3s "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET"
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

# OpenRC services (kept as repo files, not inlined): k3s-bootstrap resolves the
# per-node MMDS config; k3s is the supervised service that runs the resolved
# command and respawns on crash.
install -m0755 "$SCRIPT_DIR/k3s-bootstrap" "$R/etc/init.d/k3s-bootstrap"
install -m0755 "$SCRIPT_DIR/k3s.init" "$R/etc/init.d/k3s"
install -m0755 "$SCRIPT_DIR/latticeve-k3s-upgrade" "$R/usr/local/bin/latticeve-k3s-upgrade"
install -m0755 "$SCRIPT_DIR/latticeve-k3s-upgrade-watch" "$R/usr/local/bin/latticeve-k3s-upgrade-watch"
install -m0755 "$SCRIPT_DIR/latticeve-k3s-upgrade-watch.init" "$R/etc/init.d/latticeve-k3s-upgrade-watch"

# cgroups v2 unified (k3s requires a sane cgroup mount) + drop ttyN gettys
# (Firecracker only has ttyS0) so the console doesn't flood.
echo 'rc_cgroup_mode="unified"' >> "$R/etc/rc.conf"
sed -i '/^tty[1-6]/d' "$R/etc/inittab"

# Raise the open-file limit for the k3s service (and all its children:
# containerd, kubelet, CNI plugins). Alpine's default 1024 is exhausted by a
# handful of pods. 65535 is the standard k3s node recommendation.
mkdir -p "$R/etc/conf.d"
echo 'rc_ulimit="-n 65535"' > "$R/etc/conf.d/k3s"

# inotify tunables — each pod/container registers watchers; the kernel defaults
# (max_user_watches=8192, max_user_instances=128) are exhausted quickly.
# Applied at boot by the sysctl OpenRC service (already in the boot runlevel).
mkdir -p "$R/etc/sysctl.d"
cat > "$R/etc/sysctl.d/99-k3s.conf" <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

chroot "$R" /bin/sh -c '
  set -e
  # ca-certificates provides the trust bundle + update-ca-certificates so the
  # k3s-bootstrap service can verify TLS on the kubeconfig callback against the
  # controller serving cert (no apostrophes here: this whole block is a single-
  # quoted sh -c argument, so one would close the quote). dropbear is a tiny SSH
  # server, started by k3s-bootstrap only when the cluster supplies SSH keys.
  apk add --no-cache openrc iproute2 e2fsprogs ca-certificates dropbear >/dev/null 2>&1
  # A bare minirootfs leaves sysinit/boot runlevels empty -> no cgroup/sysfs mount
  # -> k3s fatals "unhandled cgroup mode". Populate the minimum services
  # Firecracker needs, and remove module/hw probing services that only produce
  # noise with our external kernel and no /lib/modules tree.
  rc-update del hwdrivers sysinit 2>/dev/null || true
  rc-update del modules boot 2>/dev/null || true
  rc-update del modules sysinit 2>/dev/null || true
  rc-update add devfs sysinit
  rc-update add sysfs sysinit
  rc-update add cgroups sysinit
  for s in procfs bootmisc hostname sysctl seedrng localmount; do rc-update add $s boot; done
  rc-update add networking boot
  rc-update add local default
  rc-update add k3s-bootstrap default
  rc-update add k3s default
  rc-update add latticeve-k3s-upgrade-watch default
  # Passwordless root by default. A cluster can set a root password (root_pw_hash)
  # and/or SSH keys (ssh_keys) via MMDS, applied at boot by k3s-bootstrap.
  passwd -d root
' 2>&1 | tail -3

rm -f "$R/etc/resolv.conf"
rm -f "$OUT"

# Size the image to what's actually in $R rather than a guessed constant: take
# the real content size, add 20% headroom for ext4 metadata/journal/reserved
# blocks plus a fixed 8M floor so small content doesn't get a razor-thin margin.
if [ -z "$ROOTFS_SIZE" ]; then
    content_kb=$(du -sk "$R" | cut -f1)
    rootfs_size_kb=$(( content_kb * 12 / 10 + 8192 ))
    ROOTFS_SIZE="${rootfs_size_kb}K"
    echo "computed ROOTFS_SIZE=$ROOTFS_SIZE (content ${content_kb}K + 20% + 8M headroom)"
fi

# Disable orphan_file + metadata_csum_seed: e2fsprogs 1.47 enables them by
# default, but they can block online resize of the mounted root on the
# Firecracker guest kernel — and the root is grown via resize2fs at first boot
# (see k3s-bootstrap). Building without them keeps that online resize clean.
mke2fs -q -t ext4 -O ^orphan_file,^metadata_csum_seed -d "$R" "$OUT" "$ROOTFS_SIZE"
echo "=== built ==="; ls -la "$OUT"
echo "=== default runlevel ==="; ls "$R/etc/runlevels/default"
echo "k3s_version=$K3S_VERSION" > "${OUT}.meta"
echo "alpine_version=$ALPINE_VERSION" >> "${OUT}.meta"
echo "arch=$GOARCH" >> "${OUT}.meta"
echo "build_id=$BUILD_ID" >> "${OUT}.meta"
