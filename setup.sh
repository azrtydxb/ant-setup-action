#!/bin/sh
# Kuvryn Ant setup: GitHub OIDC -> Ant token -> tool configuration.
# POSIX sh; needs curl, wget, node (18+) or python3. Never prints the token.
set -u

fallback() {
	if [ "${ANT_REQUIRED:-false}" = "true" ]; then
		echo "::error::Kuvryn Ant: $1"
		exit 1
	fi
	echo "::warning::Kuvryn Ant: $1; using the public upstream registries"
	echo "configured=false" >>"$GITHUB_OUTPUT"
	exit 0
}

fetch() { # fetch URL [auth-header] [post-body]
	if command -v curl >/dev/null 2>&1; then
		if [ -n "${3:-}" ]; then
			curl -fsS --retry 3 -m 30 -H "$2" -H 'Content-Type: application/json' -d "$3" "$1"
		else
			curl -fsS --retry 3 -m 30 -H "$2" "$1"
		fi
	elif command -v wget >/dev/null 2>&1; then
		if [ -n "${3:-}" ]; then
			wget -q -T 30 -O - --header "$2" --header 'Content-Type: application/json' --post-data "$3" "$1"
		else
			wget -q -T 30 -O - --header "$2" "$1"
		fi
	elif command -v node >/dev/null 2>&1; then
		ANT_U="$1" ANT_H="$2" ANT_B="${3:-}" node -e '
const [k, ...v] = process.env.ANT_H.split(":");
const h = { [k]: v.join(":").trim(), "Content-Type": "application/json" };
const b = process.env.ANT_B;
fetch(process.env.ANT_U, b ? { method: "POST", headers: h, body: b } : { headers: h })
  .then(async (r) => { if (!r.ok) process.exit(22); process.stdout.write(await r.text()); })
  .catch(() => process.exit(7));'
	elif command -v python3 >/dev/null 2>&1; then
		ANT_U="$1" ANT_H="$2" ANT_B="${3:-}" python3 -I -c '
import os, sys, urllib.request
k, _, v = os.environ["ANT_H"].partition(":")
b = os.environ["ANT_B"].encode() or None
r = urllib.request.Request(os.environ["ANT_U"], data=b, headers={k: v.strip(), "Content-Type": "application/json"})
sys.stdout.write(urllib.request.urlopen(r, timeout=30).read().decode())'
	else
		return 127
	fi
}

json_field() { # json_field NAME  (reads stdin; flat string fields only)
	sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

host=${ANT_HOST:-ant.azrty.com}
base="https://$host"

# Ant must answer before anything is pointed at it.
fetch "$base/v2/" "Accept: application/json" >/dev/null 2>&1 ||
	fallback "$base is not answering"

[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
	fallback "no GitHub OIDC token (add 'permissions: id-token: write'; Dependabot and fork PRs get none)"

jwt=$(fetch "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$base" "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" | json_field value) ||
	fallback "requesting the GitHub OIDC token failed"
[ -n "$jwt" ] || fallback "empty GitHub OIDC token"

token=$(fetch "$base/api/v1/auth/github-oidc/exchange" "Accept: application/json" "{\"token\":\"$jwt\"}" | json_field access_token) ||
	fallback "OIDC exchange at $base was refused (check the trust rules)"
[ -n "$token" ] || fallback "OIDC exchange returned no token"
unset jwt
echo "::add-mask::$token"

{
	echo "ANT_HOST=$host"
	echo "ANT_TOKEN=$token"
} >>"$GITHUB_ENV"

home=${HOME:-/root}

if [ "${ANT_GO:-true}" = "true" ]; then
	netrc="$home/.netrc"
	touch "$netrc" && chmod 600 "$netrc"
	grep -v "^machine $host " "$netrc" >"$netrc.tmp" 2>/dev/null || true
	printf 'machine %s login ci password %s\n' "$host" "$token" >>"$netrc.tmp"
	mv "$netrc.tmp" "$netrc" && chmod 600 "$netrc"
	{
		echo "NETRC=$netrc"
		# "|": any Ant error (5xx during a restart, 400 for a non-module path
		# probe) falls through to the public proxy instead of failing the build.
		echo "GOPROXY=$base/feeds/${ANT_GO_FEED:-go}/go|https://proxy.golang.org,direct"
		# Checksums straight from sum.golang.org: Ant's sumdb proxy answers
		# /supported but 404s some /lookup requests, which go treats as fatal.
		[ -n "${GOSUMDB:-}" ] || echo "GOSUMDB=sum.golang.org https://sum.golang.org"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: GOPROXY=$base/feeds/${ANT_GO_FEED:-go}/go|https://proxy.golang.org,direct"
fi

if [ "${ANT_NPM:-true}" = "true" ]; then
	reg="$base/feeds/${ANT_NPM_FEED:-npm}/npm/"
	npmrc="$home/.npmrc"
	touch "$npmrc" && chmod 600 "$npmrc"
	grep -v "^//$host/" "$npmrc" | grep -v '^registry=' >"$npmrc.tmp" 2>/dev/null || true
	printf 'registry=%s\n//%s/feeds/%s/npm/:_authToken=%s\n' "$reg" "$host" "${ANT_NPM_FEED:-npm}" "$token" >>"$npmrc.tmp"
	mv "$npmrc.tmp" "$npmrc" && chmod 600 "$npmrc"
	{
		echo "NPM_CONFIG_REGISTRY=$reg"
		echo "npm_config_registry=$reg"
		echo "NODE_AUTH_TOKEN=$token"
		# Ride out a short Ant restart instead of failing the install.
		echo "npm_config_fetch_retries=6"
		echo "npm_config_fetch_retry_mintimeout=5000"
		echo "npm_config_fetch_retry_maxtimeout=60000"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: npm/pnpm registry=$reg"
fi

if [ "${ANT_CARGO:-true}" = "true" ]; then
	idx="sparse+$base/feeds/${ANT_CARGO_FEED:-cargo}/cargo/"
	cargo_home=${CARGO_HOME:-$home/.cargo}
	mkdir -p "$cargo_home"
	cfg="$cargo_home/config.toml"
	if ! grep -q '^\[source\.ant\]' "$cfg" 2>/dev/null; then
		cat >>"$cfg" <<TOML

[source.crates-io]
replace-with = "ant"
[source.ant]
registry = "$idx"
[registries.ant]
index = "$idx"
credential-provider = "cargo:token"
TOML
	fi
	{
		echo "CARGO_REGISTRIES_ANT_TOKEN=$token"
		echo "CARGO_NET_RETRY=6"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: crates.io replaced with $idx"
fi

if [ "${ANT_PIP:-true}" = "true" ]; then
	idx="https://ci:$token@$host/feeds/${ANT_PYPI_FEED:-pypi}/pypi/simple/"
	{
		echo "PIP_INDEX_URL=$idx"
		echo "UV_INDEX_URL=$idx"
		echo "UV_DEFAULT_INDEX=$idx"
		echo "PIP_RETRIES=6"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: pip/uv index=https://$host/feeds/${ANT_PYPI_FEED:-pypi}/pypi/simple/"
fi

# write_config PATH: write stdin to PATH (mode 600), keeping a one-time backup of
# a pre-existing file that Ant did not write.
write_config() {
	mkdir -p "$(dirname "$1")"
	if [ -f "$1" ] && ! grep -q 'kuvryn-ant-setup' "$1" 2>/dev/null && [ ! -f "$1.pre-ant" ]; then
		cp "$1" "$1.pre-ant"
	fi
	cat >"$1" && chmod 600 "$1"
}

if [ "${ANT_MAVEN:-false}" = "true" ]; then
	murl="$base/feeds/${ANT_MAVEN_FEED:-maven}/maven/"
	write_config "$home/.m2/settings.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!-- kuvryn-ant-setup -->
<settings>
  <mirrors>
    <mirror>
      <id>ant</id>
      <name>Kuvryn Ant</name>
      <url>$murl</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
  <servers>
    <server>
      <id>ant</id>
      <username>ci</username>
      <password>$token</password>
    </server>
  </servers>
</settings>
XML
	echo "Kuvryn Ant: maven central mirrored to $murl"
fi

if [ "${ANT_NUGET:-false}" = "true" ]; then
	nurl="$base/feeds/${ANT_NUGET_FEED:-nuget}/nuget/v3/index.json"
	write_config "$home/.nuget/NuGet/NuGet.Config" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- kuvryn-ant-setup -->
<configuration>
  <packageSources>
    <clear />
    <add key="ant" value="$nurl" />
  </packageSources>
  <packageSourceCredentials>
    <ant>
      <add key="Username" value="ci" />
      <add key="ClearTextPassword" value="$token" />
    </ant>
  </packageSourceCredentials>
</configuration>
XML
	echo "Kuvryn Ant: nuget source=$nurl"
fi

if [ "${ANT_COMPOSER:-false}" = "true" ]; then
	composer_url="$base/feeds/${ANT_COMPOSER_FEED:-composer}/composer"
	chome=${COMPOSER_HOME:-$home/.composer}
	write_config "$chome/auth.json" <<JSON
{"http-basic":{"$host":{"username":"ci","password":"$token"}}}
JSON
	write_config "$chome/config.json" <<JSON
{"repositories":[{"type":"composer","url":"$composer_url"}]}
JSON
	echo "COMPOSER_HOME=$chome" >>"$GITHUB_ENV"
	echo "Kuvryn Ant: composer repository=$composer_url"
fi

if [ "${ANT_DOCKER:-false}" = "true" ]; then
	if command -v docker >/dev/null 2>&1; then
		# Retried: a busy or restarting Ant answers 503 for a few seconds.
		logged=
		for delay in 2 5 10 20 0; do
			if printf '%s' "$token" | docker login "$host" -u ci --password-stdin >/dev/null; then
				logged=1
				break
			fi
			[ "$delay" -gt 0 ] && sleep "$delay"
		done
		[ -n "$logged" ] || fallback "docker login to $host failed"
		echo "Kuvryn Ant: docker logged in to $host"
	else
		echo "::warning::Kuvryn Ant: docker-login requested but docker is not installed"
	fi
fi

echo "configured=true" >>"$GITHUB_OUTPUT"
