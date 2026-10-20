#!/bin/sh
# Delete a branch's caches from the Ant cache feeds. Never prints the token.
set -u
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

skip() { # skip MESSAGE: warn and succeed unless required
	if [ "${ANT_REQUIRED:-false}" = "true" ]; then
		echo "::error::Kuvryn Ant cache cleanup: $1"
		exit 1
	fi
	echo "::warning::Kuvryn Ant cache cleanup: $1"
	exit 0
}

host=$(ant_host)
[ -n "$host" ] || skip "no Ant host configured: set the 'host' input (for example host: ant.example.com) or 'ant-url'"
base="https://$host"

if [ "${ANT_EVENT_REF_TYPE:-}" = "tag" ] && [ -z "${ANT_CLEAN_BRANCH:-}" ]; then
	echo "Kuvryn Ant cache cleanup: a deleted tag has no cache of its own (tag builds share the default branch cache)"
	exit 0
fi
branch=${ANT_CLEAN_BRANCH:-}
[ -n "$branch" ] || branch=${ANT_EVENT_REF:-}
if [ -z "$branch" ] && [ "${GITHUB_EVENT_NAME:-}" = "delete" ]; then
	skip "delete event without a ref"
fi
[ -n "$branch" ] || branch=${GITHUB_HEAD_REF:-}
[ -n "$branch" ] || branch=${GITHUB_REF_NAME:-}
[ -n "$branch" ] || skip "no branch given and none in the event"

if [ -n "${ANT_DEFAULT_BRANCH:-}" ] && [ "$branch" = "$ANT_DEFAULT_BRANCH" ] && [ -z "${ANT_CLEAN_BRANCH:-}" ]; then
	skip "refusing to clean the default branch '$branch' (pass branch explicitly to override)"
fi

tagpart=$(cache_tag_part "$branch")
[ -n "$tagpart" ] || skip "branch '$branch' sanitizes to nothing"
repo=${ANT_CLEAN_REPO:-$GITHUB_REPOSITORY}
lrepo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')

ant_exchange "$host" || skip "$ANT_EXCHANGE_ERROR"
token=$ANT_EXCHANGED_TOKEN
auth="Authorization: Bearer $token"

feed_id() { # feed_id SLUG
	fetch "$base/api/v1/feeds?prefix=$1" "$auth" | tr '{' '\n' |
		sed -n "s/.*\"id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*\"slug\"[[:space:]]*:[[:space:]]*\"$1\".*/\1/p" | head -n 1
}

# clean FEED_SLUG PREFIX: loop while the API answers truncated.
clean() { # clean FEED_SLUG PREFIX [DEFAULT_ID]
	_id=$(feed_id "$1")
	# The feed is found by slug. An id passed explicitly (cache-feed-id, sccache-feed-id) is only
	# a fallback for a server whose CI tokens cannot list feeds; there is no built-in id.
	[ -n "$_id" ] || _id=${3:-}
	[ -n "$_id" ] || { echo "::warning::Kuvryn Ant cache cleanup: feed '$1' not found or not readable with this token"; return 0; }
	_enc=$(printf '%s' "$2" | sed 's/%/%25/g; s/:/%3A/g; s/ /%20/g')
	_try=0
	while [ "$_try" -lt 20 ]; do
		_try=$((_try + 1))
		_resp=$(fetch "$base/api/v1/feeds/$_id/cache?prefix=$_enc" "$auth" "" DELETE) ||
			{ echo "::warning::Kuvryn Ant cache cleanup: DELETE on feed '$1' failed"; return 0; }
		_t=$(printf '%s' "$_resp" | json_number tags_removed)
		_b=$(printf '%s' "$_resp" | json_number bytes_released)
		_m=$(printf '%s' "$_resp" | json_number matched)
		tags_total=$((tags_total + ${_t:-0}))
		bytes_total=$((bytes_total + ${_b:-0}))
		echo "Kuvryn Ant cache cleanup: $1 prefix '$2': matched ${_m:-0}, tags removed ${_t:-0}, bytes released ${_b:-0}"
		[ "$(printf '%s' "$_resp" | json_number truncated)" = "true" ] || return 0
	done
}

tags_total=0
bytes_total=0
clean "${ANT_CACHE_FEED:-buildcache}" "$lrepo:$tagpart-" "$([ "${ANT_CACHE_FEED:-buildcache}" = buildcache ] && printf '%s' "${ANT_CACHE_FEED_ID:-}")"
# sccache keys are content hashes under the key prefix (org/repo by default, shared
# between branches), so this removes files only for a repository that put the
# branch into SCCACHE_WEBDAV_KEY_PREFIX (org/repo/<branch>).
clean "${ANT_SCCACHE_FEED:-sccache}" "$repo/$tagpart/" "$([ "${ANT_SCCACHE_FEED:-sccache}" = sccache ] && printf '%s' "${ANT_SCCACHE_FEED_ID:-}")"
{
	echo "tags-removed=$tags_total"
	echo "bytes-released=$bytes_total"
} >>"$GITHUB_OUTPUT"
