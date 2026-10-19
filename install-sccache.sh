#!/bin/sh
# Install sccache (checksum verified) when the job wants it and it is missing.
# Runs with or without Ant: without a remote store sccache still works on local disk.
# Exits 0 when sccache is on PATH afterwards.
set -u
home=${HOME:-/root}

want=${ANT_SCCACHE:-auto}
if [ "$want" = "auto" ]; then
	want=false
	if command -v cargo >/dev/null 2>&1 || command -v rustc >/dev/null 2>&1 ||
		[ -f "${GITHUB_WORKSPACE:-.}/Cargo.toml" ]; then
		want=true
	fi
fi

install_sccache() { # installs ANT_SCCACHE_VERSION into the first writable bin dir
	[ "$(uname -s)" = "Linux" ] || { echo "::warning::Kuvryn Ant: sccache install supports Linux only"; return 1; }
	case "$(uname -m)" in
	x86_64 | amd64) triple=x86_64-unknown-linux-musl ;;
	aarch64 | arm64) triple=aarch64-unknown-linux-musl ;;
	*) echo "::warning::Kuvryn Ant: no sccache binary for $(uname -m)"; return 1 ;;
	esac
	ver=${ANT_SCCACHE_VERSION:-0.17.0}
	file="sccache-v$ver-$triple.tar.gz"
	url="https://github.com/mozilla/sccache/releases/download/v$ver/$file"
	tmp=$(mktemp -d)
	dl() {
		if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -m 120 -o "$2" "$1"
		elif command -v wget >/dev/null 2>&1; then wget -q -T 120 -O "$2" "$1"
		else return 127; fi
	}
	dl "$url" "$tmp/$file" && dl "$url.sha256" "$tmp/$file.sha256" || { echo "::warning::Kuvryn Ant: downloading sccache $ver failed"; rm -rf "$tmp"; return 1; }
	want_sum=$(awk '{print $1; exit}' "$tmp/$file.sha256")
	got_sum=$(sha256sum "$tmp/$file" | awk '{print $1}')
	if [ -z "$want_sum" ] || [ "$want_sum" != "$got_sum" ]; then
		echo "::warning::Kuvryn Ant: sccache $ver checksum mismatch; not installing it"
		rm -rf "$tmp"
		return 1
	fi
	tar xzf "$tmp/$file" -C "$tmp" || { rm -rf "$tmp"; return 1; }
	bin=$(ls "$tmp"/sccache-v*/sccache 2>/dev/null | head -n 1)
	[ -n "$bin" ] || { rm -rf "$tmp"; return 1; }
	dest=/usr/local/bin
	if ! { mkdir -p "$dest" && [ -w "$dest" ]; } 2>/dev/null; then
		dest="$home/.local/bin"
		mkdir -p "$dest"
		echo "$dest" >>"$GITHUB_PATH"
		PATH="$dest:$PATH"
	fi
	install -m 755 "$bin" "$dest/sccache"
	rm -rf "$tmp"
}

if [ "$want" = "true" ] && ! command -v sccache >/dev/null 2>&1; then
	install_sccache || true
fi
if [ "$want" = "true" ] && ! command -v sccache >/dev/null 2>&1; then
	echo "::warning::Kuvryn Ant: sccache is not available; Rust builds compile without it"
	exit 1
fi
[ "$want" = "true" ]
