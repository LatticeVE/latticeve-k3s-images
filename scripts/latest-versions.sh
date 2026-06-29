#!/bin/bash
# Prints the latest known-good version for each upstream input this repo
# builds against: k3s and the Alpine minirootfs. (The Firecracker guest kernel
# is no longer built here — LatticeVE discovers it directly from Firecracker's
# own CI bucket, since a kernel isn't actually coupled to a specific rootfs.)
#
# Usage: ./scripts/latest-versions.sh [alpine-branch, e.g. v3.21]
#
# Output (one per line, suitable for `source`-ing or eval):
#   K3S_VERSION=v1.31.5+k3s1
#   ALPINE_VERSION=3.21.7
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

# Allow sourcing this file (e.g. `source latest-versions.sh; alpine_version`)
# to call individual functions without running the full report.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set +e
    K3S_VERSION="$(k3s_version)"; k3s_rc=$?
    ALPINE_VERSION="$(alpine_version)"; alpine_rc=$?
    set -e

    echo "K3S_VERSION=$K3S_VERSION"
    echo "ALPINE_VERSION=$ALPINE_VERSION"

    if [ "$k3s_rc" != 0 ] || [ "$alpine_rc" != 0 ]; then
        exit 1
    fi
fi
