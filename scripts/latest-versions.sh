#!/bin/bash
# Prints the latest known-good version for each upstream input this repo
# builds against: k3s, Alpine minirootfs, and the Firecracker CI guest kernel.
#
# Usage: ./scripts/latest-versions.sh [alpine-branch, e.g. v3.21]
#
# Output (one per line, suitable for `source`-ing or eval):
#   K3S_VERSION=v1.31.5+k3s1
#   ALPINE_VERSION=3.21.7
#   KERNEL_VERSION=6.1.155
#
# Requires: curl, grep -P (GNU grep). No jq dependency — everything is parsed
# with grep/sed so this runs on a bare GitHub Actions ubuntu-latest runner.
# macOS ships BSD grep (no -P) — install GNU grep (`brew install grep`, as
# `ggrep`) or run this inside the build container/CI if testing locally.
#
# Set GITHUB_TOKEN to avoid the unauthenticated GitHub API rate limit
# (60 req/hr per IP — easy to hit on a shared runner/sandbox IP).
set -euo pipefail

ALPINE_BRANCH="${1:-v3.21}"

# --- k3s: latest GitHub release tag ----------------------------------------
k3s_version() {
    local -a auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL -H "User-Agent: latticeve-k3s-images" ${auth[@]+"${auth[@]}"} \
        https://api.github.com/repos/k3s-io/k3s/releases/latest \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

# --- Alpine: latest minirootfs version for a release branch -----------------
alpine_version() {
    curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/x86_64/latest-releases.yaml" \
        | grep -A2 'flavor: alpine-minirootfs' \
        | grep -m1 'version:' \
        | sed -E 's/.*version:\s*([0-9.]+).*/\1/'
}

# --- Firecracker CI guest kernel: latest patch in the newest CI build -------
# The bucket is laid out as firecracker-ci/<dated-build>/<arch>/vmlinux-X.Y.Z
# (plus a debug/ subfolder with debug-symbol variants, which we exclude).
# We walk: newest dated build dir -> vmlinux-* filenames directly under
# <build>/x86_64/, skipping the debug/ subfolder.
s3_common_prefixes() {
    # $1 = prefix, $2 = delimiter (default "/")
    curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/?list-type=2&prefix=$1&delimiter=${2:-/}" \
        | grep -oP '(?<=<Prefix>)[^<]+'
}

kernel_version() {
    local fc_build
    fc_build=$(s3_common_prefixes "firecracker-ci/" | grep -E '^firecracker-ci/[0-9]{8}-' | sort -V | tail -1)
    [ -n "$fc_build" ] || { echo "could not find a dated firecracker-ci build" >&2; return 1; }

    curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/?list-type=2&prefix=${fc_build}x86_64/" \
        | grep -oP '(?<=<Key>)[^<]+' \
        | grep -v '/debug/' \
        | grep -oP 'vmlinux-\K[0-9]+\.[0-9]+\.[0-9]+(?=$)' \
        | sort -V | tail -1
}

# Allow sourcing this file (e.g. `source latest-versions.sh; alpine_version`)
# to call individual functions without running the full report.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    K3S_VERSION="$(k3s_version)"
    ALPINE_VERSION="$(alpine_version)"
    KERNEL_VERSION="$(kernel_version)"

    echo "K3S_VERSION=$K3S_VERSION"
    echo "ALPINE_VERSION=$ALPINE_VERSION"
    echo "KERNEL_VERSION=$KERNEL_VERSION"
fi
