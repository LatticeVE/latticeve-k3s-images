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
cd rootfs && K3S_VERSION=v1.31.5+k3s1 ALPINE_VERSION=3.21.7 sudo -E ./build.sh
cd kernel && KERNEL_VERSION=6.1.128 ./build.sh
```

## CI

`.github/workflows/build.yml` is a `workflow_dispatch` job: pick a k3s version,
Alpine version, kernel version, and arch, and it builds both artifacts and
publishes them as a GitHub Release (rootfs `.ext4` + kernel `vmlinux`, each
with a `.meta` sidecar recording the versions baked in).

LatticeVE's kernel catalog and (planned) rootfs image catalog can point at
these release URLs the same way the existing Firecracker CI kernel catalog
entries point at `s3.amazonaws.com/spec.ccfc.min/firecracker-ci/...`.
