#!/bin/bash
# Prints the latest known-good version for each upstream input this repo
# builds against: k3s and the Alpine minirootfs. Also exposes fc_kernel_version()
# to resolve the newest Firecracker-supported guest kernel — the kernel is built
# by .github/workflows/build-kernel.yml against Firecracker's own CI config, so
# we track the version set Firecracker actually publishes rather than kernel.org.
#
# Usage: ./scripts/latest-versions.sh [alpine-branch, e.g. v3.21]
#
# Output (one per line, suitable for `source`-ing or eval):
#   K3S_VERSION=v1.31.5+k3s1
#   ALPINE_VERSION=3.21.7
#   FC_KERNEL_VERSION=6.1.174
#
# Requires: curl, grep, sed, awk, paste — all POSIX-compatible (works with BSD
# tools on macOS as well as GNU on Linux/CI). No jq dependency.
#
# Set GITHUB_TOKEN to avoid the unauthenticated GitHub API rate limit
# (60 req/hr per IP — easy to hit on a shared runner/sandbox IP).
set -euo pipefail

ALPINE_BRANCH="${1:-v3.24}"

# --- k3s: latest *stable* GitHub release tag --------------------------------
# k3s publishes release candidates (e.g. v1.34.9-rc3+k3s1) ahead of a stable
# cut. The daily auto-build must never pick one of those up, so list releases
# (newest first) instead of trusting /releases/latest's prerelease flag alone,
# and additionally skip any tag matching -rc<N> by name as a defensive check.
k3s_version() {
    local -a auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    local body
    body=$(curl -sSL -w '\n%{http_code}' -H "User-Agent: latticeve-k3s-images" ${auth[@]+"${auth[@]}"} \
        "https://api.github.com/repos/k3s-io/k3s/releases?per_page=30")
    local code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$code" != "200" ]; then
        echo "k3s_version: GitHub API returned HTTP $code: $(echo "$body" | head -c 300)" >&2
        return 1
    fi

    # tag_name and prerelease appear once per release object, in the same
    # order release-to-release, so a positional zip (paste) lines them up
    # without needing a JSON parser.
    local tags prereleases tag
    tags=$(echo "$body" | grep -o '"tag_name" *: *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')
    prereleases=$(echo "$body" | grep -o '"prerelease" *: *[a-z]*' | sed -E 's/.*: *//')
    tag=$(paste -d'|' <(echo "$tags") <(echo "$prereleases") \
        | awk -F'|' '$2 == "false" && $1 !~ /-[Rr][Cc][0-9]*/ { print $1; exit }')

    if [ -z "$tag" ]; then
        echo "k3s_version: no stable (non-RC) release found among the latest releases" >&2
        return 1
    fi
    echo "$tag"
}

# --- Alpine: latest minirootfs version for a release branch -----------------
alpine_version() {
    local yaml ver
    yaml=$(curl -sSL -w '\n%{http_code}' \
        "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/x86_64/latest-releases.yaml")
    local code="${yaml##*$'\n'}"
    yaml="${yaml%$'\n'*}"
    if [ "$code" != "200" ]; then
        echo "alpine_version: HTTP $code fetching latest-releases.yaml for branch $ALPINE_BRANCH" >&2
        return 1
    fi
    ver=$(echo "$yaml" | grep -B1 'flavor: alpine-minirootfs' | grep -m1 'version:' | sed -E 's/.*version:[[:space:]]*([0-9.]+).*/\1/')
    if [ -z "$ver" ]; then
        echo "alpine_version: no alpine-minirootfs entry found for branch $ALPINE_BRANCH" >&2
        return 1
    fi
    echo "$ver"
}

# --- Firecracker guest kernel: newest version with a published FC CI config --
# Firecracker only boots kernels it ships a build config for (in its CI S3
# bucket). Track that set rather than kernel.org so we (a) never build a kernel
# Firecracker can't run, and (b) automatically pick up a new line — including a
# new major like 7.x — the moment Firecracker starts publishing configs for it.
# No manual version bumping required.
fc_kernel_version() {
    local arch="${1:-x86_64}"
    local base="https://s3.amazonaws.com/spec.ccfc.min"
    # Minimum supported kernel major. Firecracker still ships 5.10 configs, but
    # LatticeVE k3s nodes target the 6.x line and up, so 5.x is filtered out.
    local min_major=6
    local dirs d vers
    # Dated CI build dirs (firecracker-ci/YYYYMMDD-<hash>-0/), newest first.
    dirs=$(curl -sSL "${base}/?list-type=2&prefix=firecracker-ci/&delimiter=/" \
        | grep -o '<Prefix>firecracker-ci/[0-9]\{8\}-[^<]*</Prefix>' \
        | sed 's|<Prefix>||;s|</Prefix>||' | sort -r)
    if [ -z "$dirs" ]; then
        echo "fc_kernel_version: no Firecracker CI build dirs found" >&2
        return 1
    fi
    # Walk newest-first; return the highest kernel version (proper version sort)
    # that has a vmlinux config for this arch, ignoring majors below min_major.
    for d in $dirs; do
        vers=$(curl -sSL "${base}/?list-type=2&prefix=${d}${arch}/vmlinux-" \
            | grep -oE 'vmlinux-[0-9]+(\.[0-9]+)+\.config' \
            | sed -E 's/^vmlinux-(.*)\.config$/\1/' \
            | awk -F. -v m="$min_major" '$1 >= m' \
            | sort -V)
        if [ -n "$vers" ]; then
            echo "$vers" | tail -1
            return 0
        fi
    done
    echo "fc_kernel_version: no vmlinux config found for arch $arch (major >= $min_major)" >&2
    return 1
}

# Allow sourcing this file (e.g. `source latest-versions.sh; alpine_version`)
# to call individual functions without running the full report.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set +e
    K3S_VERSION="$(k3s_version)"; k3s_rc=$?
    ALPINE_VERSION="$(alpine_version)"; alpine_rc=$?
    FC_KERNEL_VERSION="$(fc_kernel_version x86_64)"; kernel_rc=$?
    set -e

    echo "K3S_VERSION=$K3S_VERSION"
    echo "ALPINE_VERSION=$ALPINE_VERSION"
    echo "FC_KERNEL_VERSION=$FC_KERNEL_VERSION"

    if [ "$k3s_rc" != 0 ] || [ "$alpine_rc" != 0 ] || [ "$kernel_rc" != 0 ]; then
        exit 1
    fi
fi
