# latticeve-k3s-images

Builds the k3s-on-Firecracker rootfs LatticeVE's Kubernetes provisioning
needs:

- `rootfs/` — a reproducible Alpine + k3s ext4 rootfs (`build.sh`). Boots via
  the `k3s-bootstrap` OpenRC service, which reads its role/token/server/etc.
  from Firecracker MMDS at boot.

There's no guest kernel build here — a Firecracker kernel isn't actually
coupled to a specific rootfs (one kernel boots many rootfs versions), so
LatticeVE discovers and imports Firecracker guest kernels directly from
Firecracker's own CI bucket via its Kernel Catalog, independent of this repo.

## Building locally

```bash
cd rootfs && K3S_VERSION=v1.31.5+k3s1 ALPINE_VERSION=3.24.1 sudo -E ./build.sh
```

Produces `k3s-<version>-<amd64|arm64>.ext4` (e.g. `k3s-v1.31.5+k3s1-amd64.ext4`),
with a `.meta` sidecar recording the k3s/Alpine versions baked in.

## CI

`.github/workflows/build.yml` runs two ways:

- **Daily cron** (`schedule`): checks k3s's releases for the newest *stable*
  release (release candidates like `v1.34.9-rc3+k3s1` are skipped — see
  `scripts/latest-versions.sh`'s `k3s_version()`) and only builds if it's
  different from what this repo already published.
- **Manual `workflow_dispatch`**: pick an explicit k3s version and Alpine
  version and it always builds, regardless of what's already published.

Either way, it builds the rootfs for **both x86_64 and aarch64** and
publishes the result as a GitHub Release tagged `k3s-<version>-r<run>` (e.g.
`k3s-v1.31.5+k3s1-r12`).

Each arch builds natively — x86_64 on `ubuntu-latest`, aarch64 on GitHub's
hosted arm64 runner (`ubuntu-24.04-arm`) — rather than cross-compiling/
cross-chrooting from x86_64, since `chroot`-ing into an aarch64 rootfs from an
x86_64 host needs QEMU user-mode emulation or a cross toolchain otherwise.
`ubuntu-24.04-arm` is free for public repos; private repos need a paid arm64
runner.

LatticeVE's Kubernetes page discovers and imports the latest release from
this repo directly (`GET .../releases/latest`), the same "discover, then
import on demand" pattern it already uses for the Firecracker kernel catalog.
