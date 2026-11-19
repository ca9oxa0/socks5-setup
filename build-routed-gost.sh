#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    printf '用法: bash %s OUTPUT\n' "$0" >&2
    exit 2
fi
if [[ "$(uname -s)" != Linux ]]; then
    printf '此构建脚本需在 Linux 上运行。\n' >&2
    exit 1
fi
for cmd in go git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '缺少构建依赖: %s\n' "$cmd" >&2
        exit 1
    fi
done

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="$1"
[[ "$output" == /* ]] || output="$PWD/$output"
if [[ -d "$output" ]]; then
    printf '输出路径必须是文件: %s\n' "$output" >&2
    exit 2
fi
work="$(mktemp -d)"
work="$(cd -- "$work" && pwd)"
trap 'rm -rf -- "$work"' EXIT

fetch_source() {
    local name="$1" commit="$2" tree="$work/$1"
    git init -q "$tree"
    git -C "$tree" fetch -q --depth 1 "https://github.com/go-gost/$name.git" "$commit"
    git -C "$tree" -c core.autocrlf=false checkout --quiet --detach "$commit"
    git -C "$tree" apply --whitespace=error "$src/routed-$name.patch"
}

# gost v3.0.0-rc10 及其 go.mod 指定的 x 提交。
fetch_source gost e27d2bc593704f19db258291c22dbd5f0de78414
fetch_source x 5b1183661f6c8301a28c79e59c8e475474bd4bd3
(
    cd -- "$work/gost"
    export GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux
    go mod edit -replace github.com/go-gost/x=../x
    go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' -o "$work/routed-gost" ./cmd/gost
)
install -m 0755 -- "$work/routed-gost" "$output"
