#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
VERSIONS_FILE="$ROOT/Versions.env"

fail() {
    printf '%s\n' "SyncnextHybrid patch error: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing required file: $1"
}

require_file "$VERSIONS_FILE"
# shellcheck disable=SC1090
. "$VERSIONS_FILE"

validate_commit() {
    case "$2" in
        *[!0-9a-f]*|"") fail "$1 commit is not a lowercase hexadecimal SHA" ;;
    esac
    [ "${#2}" -eq 40 ] || fail "$1 commit must be a full 40-character SHA"
}

validate_commit AetherEngine "$AETHERENGINE_COMMIT"
validate_commit FFmpegBuild "$FFMPEGBUILD_COMMIT"

validate_submodule_registration() {
    name=$1
    expected_remote=$2
    path="$ROOT/$name"

    [ ! -L "$path" ] || fail "$name path must not be a symlink"
    registered_path=$(git -C "$ROOT" config -f .gitmodules --get "submodule.$name.path" || true)
    registered_url=$(git -C "$ROOT" config -f .gitmodules --get "submodule.$name.url" || true)
    [ "$registered_path" = "$name" ] || fail "$name is not registered at the expected path"
    [ "$registered_url" = "$expected_remote" ] || fail "$name .gitmodules URL is not the official repository"
    mode=$(git -C "$ROOT" ls-files --stage -- "$name" | awk 'NR == 1 { print $1 }')
    [ "$mode" = "160000" ] || fail "$name is not a gitlink"
}

validate_submodule_registration AetherEngine "$AETHERENGINE_REMOTE"
validate_submodule_registration FFmpegBuild "$FFMPEGBUILD_REMOTE"

git -C "$ROOT" submodule update --init --recursive -- AetherEngine FFmpegBuild

validate_checkout() {
    name=$1
    expected_remote=$2
    path="$ROOT/$name"

    [ -d "$path" ] || fail "$name checkout is missing"
    [ ! -L "$path" ] || fail "$name checkout became a symlink"
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        fail "$name is not a git worktree"
    actual_remote=$(git -C "$path" remote get-url origin)
    [ "$actual_remote" = "$expected_remote" ] ||
        fail "$name origin is '$actual_remote', expected '$expected_remote'"
}

validate_checkout AetherEngine "$AETHERENGINE_REMOTE"
validate_checkout FFmpegBuild "$FFMPEGBUILD_REMOTE"

(
    cd "$ROOT"
    shasum -a 256 -c Patches/manifest.sha256
)

validate_series() {
    name=$1
    series="$ROOT/Patches/$name/series"
    require_file "$series"

    listed=$(awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$series")
    for entry in $listed; do
        case "$entry" in
            */*|.*) fail "$name series contains an unsafe entry: $entry" ;;
        esac
        require_file "$ROOT/Patches/$name/$entry"
    done

    actual=$(
        find "$ROOT/Patches/$name" -maxdepth 1 -type f -name '*.patch' -exec basename {} \; |
            LC_ALL=C sort
    )
    expected=$(printf '%s\n' "$listed" | sed '/^$/d' | LC_ALL=C sort)
    [ "$actual" = "$expected" ] ||
        fail "$name series does not enumerate every patch exactly once"
}

validate_series AetherEngine
validate_series FFmpegBuild

reset_checkout() {
    name=$1
    commit=$2
    path="$ROOT/$name"

    git -C "$path" reset --hard "$commit"
    git -C "$path" clean -ffd
    git -C "$path" checkout --detach "$commit"
    [ "$(git -C "$path" rev-parse HEAD)" = "$commit" ] ||
        fail "$name did not reach pinned commit $commit"
    branch=$(git -C "$path" symbolic-ref -q --short HEAD || true)
    [ -z "$branch" ] || fail "$name must remain on detached HEAD"
}

reset_checkout AetherEngine "$AETHERENGINE_COMMIT"
reset_checkout FFmpegBuild "$FFMPEGBUILD_COMMIT"

apply_series() {
    name=$1
    mode=$2
    path="$ROOT/$name"
    series="$ROOT/Patches/$name/series"

    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            ""|\#*) continue ;;
        esac
        patch="$ROOT/Patches/$name/$entry"
        git -C "$path" apply --check --whitespace=error-all "$patch"
        git -C "$path" apply --whitespace=error-all "$patch"
        printf '%s\n' "$mode $name/$entry"
    done < "$series"
}

# The check phase deliberately applies into disposable worktrees so dependent
# patches are checked in series order. Nothing is considered final until every
# patch in both repositories has passed.
apply_series AetherEngine checked
apply_series FFmpegBuild checked

reset_checkout AetherEngine "$AETHERENGINE_COMMIT"
reset_checkout FFmpegBuild "$FFMPEGBUILD_COMMIT"

apply_series AetherEngine applied
apply_series FFmpegBuild applied

[ "$(git -C "$ROOT/AetherEngine" rev-parse HEAD)" = "$AETHERENGINE_COMMIT" ] ||
    fail "AetherEngine HEAD changed while patching"
[ "$(git -C "$ROOT/FFmpegBuild" rev-parse HEAD)" = "$FFMPEGBUILD_COMMIT" ] ||
    fail "FFmpegBuild HEAD changed while patching"

grep -Fq '.package(path: "../FFmpegBuild")' "$ROOT/AetherEngine/Package.swift" ||
    fail "AetherEngine does not resolve the sibling FFmpegBuild"
if grep -Fq 'github.com/superuser404notfound/FFmpegBuild' "$ROOT/AetherEngine/Package.swift"; then
    fail "AetherEngine still declares a remote FFmpegBuild dependency"
fi

(
    cd "$ROOT"
    swift package resolve
    graph=$(swift package show-dependencies --format json)
    printf '%s' "$graph" | grep -Fq "\"path\": \"$ROOT/FFmpegBuild\"" ||
        fail "resolved dependency graph does not contain the pinned local FFmpegBuild"
    if printf '%s' "$graph" | grep -Fq '"url": "https://github.com/superuser404notfound/FFmpegBuild'; then
        fail "resolved dependency graph contains a remote FFmpegBuild duplicate"
    fi
    swift build --target SyncnextHybrid
    swift test
    xcodebuild -scheme SyncnextHybrid -destination 'generic/platform=tvOS' build \
        CODE_SIGNING_ALLOWED=NO
)

printf '%s\n' "SyncnextHybrid patched workspace is reproducible and validated."
