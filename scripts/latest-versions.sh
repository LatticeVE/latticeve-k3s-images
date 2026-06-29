#!/bin/bash
# Prints the latest known-good version for each upstream input this repo
# builds against: k3s, Alpine minirootfs, and the Firecracker CI guest kernel.
#
# Usage: ./scripts/latest-versions.sh [alpine-branch, e.g. v3.21]
#
# Output (one per line, suitable for `source`-ing or eval):
#   K3S_VERSION=v1.31.5+k3s1
#   ALPINE_VERSION=3.21.7
#   KERNEL_VERSION=6.1.174
#
# Requires: curl, grep, sed — all POSIX-compatible (works with BSD grep on
# macOS as well as GNU grep on Linux/CI). No jq dependency.
#
# Set GITHUB_TOKEN to avoid the unauthenticated GitHub API rate limit
# (60 req/hr per IP — easy to hit on a shared runner/sandbox IP).
set -euo pipefail

ALPINE_BRANCH="${1:-v3.24}"

# --- k3s: latest GitHub release tag ----------------------------------------
k3s_version() {
    local -a auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    local body
    body=$(curl -sSL -w '\n%{http_code}' -H "User-Agent: latticeve-k3s-images" ${auth[@]+"${auth[@]}"} \
        https://api.github.com/repos/k3s-io/k3s/releases/latest)
    local code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$code" != "200" ]; then
        echo "k3s_version: GitHub API returned HTTP $code: $(echo "$body" | head -c 300)" >&2
        return 1
    fi
    local tag
    tag=$(echo "$body" | grep -m1 -o '"tag_name" *: *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')
    if [ -z "$tag" ]; then
        echo "k3s_version: HTTP 200 but no tag_name found in response (first 300 chars): $(echo "$body" | head -c 300)" >&2
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

# --- Firecracker CI guest kernel: latest patch in the newest CI build -------
# The bucket is laid out as firecracker-ci/<dated-build>/<arch>/vmlinux-X.Y.Z
# (plus a debug/ subfolder with debug-symbol variants, which we exclude).
# We walk: newest dated build dir -> vmlinux-* filenames directly under
# <build>/x86_64/, skipping the debug/ subfolder.
# Portable across BSD and GNU grep: extract tag content via grep -Eo (POSIX
# ERE, no lookaround needed) then strip the tags with sed.
s3_common_prefixes() {
    # $1 = prefix, $2 = delimiter (default "/")
    curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/?list-type=2&prefix=$1&delimiter=${2:-/}" \
        | grep -Eo '<Prefix>[^<]*</Prefix>' \
        | sed -E 's#</?Prefix>##g'
}

kernel_version() {
    local fc_build
    fc_build=$(s3_common_prefixes "firecracker-ci/" | grep -E '^firecracker-ci/[0-9]{8}-' | sort -V | tail -1)
    [ -n "$fc_build" ] || { echo "could not find a dated firecracker-ci build" >&2; return 1; }

    curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/?list-type=2&prefix=${fc_build}x86_64/" \
        | grep -Eo '<Key>[^<]*</Key>' \
        | sed -E 's#</?Key>##g' \
        | grep -v '/debug/' \
        | grep -E 'vmlinux-[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed -E 's#.*vmlinux-([0-9]+\.[0-9]+\.[0-9]+)$#\1#' \
        | sort -V | tail -1
}

# Allow sourcing this file (e.g. `source latest-versions.sh; alpine_version`)
# to call individual functions without running the full report.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set +e
    K3S_VERSION="$(k3s_version)"; k3s_rc=$?
    ALPINE_VERSION="$(alpine_version)"; alpine_rc=$?
    KERNEL_VERSION="$(kernel_version)"; kernel_rc=$?
    set -e

    echo "K3S_VERSION=$K3S_VERSION"
    echo "ALPINE_VERSION=$ALPINE_VERSION"
    echo "KERNEL_VERSION=$KERNEL_VERSION"

    if [ "$k3s_rc" != 0 ] || [ "$alpine_rc" != 0 ] || [ "$kernel_rc" != 0 ]; then
        exit 1
    fi
fi
