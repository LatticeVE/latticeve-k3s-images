# latticeve-k3s-images

Builds the two artifacts LatticeVE's k3s-on-Firecracker provisioning needs:

- `rootfs/` — a reproducible Alpine + k3s ext4 rootfs (`build.sh`). Boots via
  the `k3s-bootstrap` OpenRC service, which reads its role/token/server/etc.
  from Firecracker MMDS at boot.
- `kernel/` — a Firecracker-compatible guest kernel (`vmlinux`), built from
  upstream kernel source using Firecracker's published guest config fragments
  (virtio-mmio, ext4, vsock built in; no modules; no initrd needed).

## Building locally

```bash
cd rootfs && K3S_VERSION=v1.31.5+k3s1 ALPINE_VERSION=3.24.1 sudo -E ./build.sh
cd kernel && KERNEL_VERSION=6.1.174 ./build.sh
```

## CI

`.github/workflows/build.yml` is a `workflow_dispatch` job: pick a k3s version,
Alpine version, and kernel version, and it builds both artifacts for **both
x86_64 and aarch64** and publishes them as a GitHub Release (rootfs `.ext4` +
kernel `vmlinux` per arch, each with a `.meta` sidecar recording the versions
baked in).

Each arch builds natively — x86_64 on `ubuntu-latest`, aarch64 on GitHub's
hosted arm64 runner (`ubuntu-24.04-arm`) — rather than cross-compiling/
cross-chrooting from x86_64, since `chroot`-ing into an aarch64 rootfs or
building an aarch64 kernel from an x86_64 host needs QEMU user-mode emulation
or a cross toolchain otherwise. `ubuntu-24.04-arm` is free for public repos;
private repos need a paid arm64 runner.

LatticeVE's kernel catalog and (planned) rootfs image catalog can point at
these release URLs the same way the existing Firecracker CI kernel catalog
entries point at `s3.amazonaws.com/spec.ccfc.min/firecracker-ci/...`.
