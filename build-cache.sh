# Build caches: buildx registry cache refs and sccache. Sourced by setup.sh after
# the token exists; uses $host, $token, $base and $home from it.

# --- buildx -----------------------------------------------------------------
if [ "${build_cache_docker:-true}" = "true" ]; then
	repo=$(printf '%s' "${GITHUB_REPOSITORY:-}" | tr 'A-Z' 'a-z')
	cache_repo="$host/${ANT_CACHE_FEED:-buildcache}/$repo"

	arch=${ANT_ARCH_SUFFIX:-}
	if [ -z "$arch" ]; then
		case "$(uname -m)" in
		x86_64 | amd64) arch=amd64 ;;
		aarch64 | arm64) arch=arm64 ;;
		*) arch=$(uname -m) ;;
		esac
	fi
	arch=$(cache_tag_part "$arch" 20)

	default_branch=$(cache_tag_part "${ANT_DEFAULT_BRANCH:-main}")
	[ -n "$default_branch" ] || default_branch=main
	if [ -n "${ANT_CACHE_BRANCH_IN:-}" ]; then
		branch=$ANT_CACHE_BRANCH_IN
	elif [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
		# A release builds from the default branch's lineage: share its cache
		# instead of leaving one cache per tag.
		branch=$default_branch
	elif [ -n "${GITHUB_HEAD_REF:-}" ]; then
		branch=$GITHUB_HEAD_REF
	else
		branch=${GITHUB_REF_NAME:-$default_branch}
	fi
	branch=$(cache_tag_part "$branch")
	[ -n "$branch" ] || branch=$default_branch

	name=
	if [ -n "${ANT_CACHE_NAME:-}" ]; then
		name="-$(cache_tag_part "$ANT_CACHE_NAME" 30)"
	fi
	tag="$branch$name-$arch"
	default_tag="$default_branch$name-$arch"

	# Only name caches that exist: a cache-from ref that is missing is fatal for
	# build-push-action v6 and a warning for v7.
	cache_exists() {
		command -v curl >/dev/null 2>&1 || return 0
		curl -fsS -o /dev/null --retry 2 -m 20 -H "Authorization: Bearer $token" \
			-H "Accept: application/vnd.oci.image.manifest.v1+json" \
			"$base/v2/${ANT_CACHE_FEED:-buildcache}/$repo/manifests/$1" >/dev/null 2>&1
	}
	cache_from=
	for t in "$tag" "$default_tag"; do
		cache_exists "$t" || continue
		case "
$cache_from
" in *"
type=registry,ref=$cache_repo:$t
"*) continue ;; esac
		cache_from="${cache_from:+$cache_from
}type=registry,ref=$cache_repo:$t"
	done
	cache_to=
	if [ "${ANT_CACHE_WRITE:-true}" = "true" ]; then
		cache_to="type=registry,ref=$cache_repo:$tag,mode=max,image-manifest=true,ignore-error=true"
	fi

	{
		echo "cache-ref=$cache_repo"
		echo "cache-tag=$tag"
		echo "cache-from<<ANT_EOF"
		echo "$cache_from"
		echo "ANT_EOF"
		echo "cache-to<<ANT_EOF"
		echo "$cache_to"
		echo "ANT_EOF"
	} >>"$GITHUB_OUTPUT"
	{
		echo "ANT_CACHE_REPO=$cache_repo"
		echo "ANT_CACHE_BRANCH=$branch"
		echo "ANT_CACHE_DEFAULT_BRANCH=$default_branch"
		echo "ANT_CACHE_ARCH=$arch"
		echo "ANT_CACHE_FROM<<ANT_EOF"
		echo "$cache_from"
		echo "ANT_EOF"
		echo "ANT_CACHE_TO<<ANT_EOF"
		echo "$cache_to"
		echo "ANT_EOF"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: buildx cache $cache_repo:$tag (fallback $default_tag)"
else
	{
		echo "cache-ref="
		echo "cache-tag="
		printf 'cache-from<<ANT_EOF\n\nANT_EOF\ncache-to<<ANT_EOF\n\nANT_EOF\n'
	} >>"$GITHUB_OUTPUT"
fi

# --- sccache ----------------------------------------------------------------
sccache_ok=false
if sh "$(dirname "$0")/install-sccache.sh"; then
	sccache_ok=true
	{
		echo "RUSTC_WRAPPER=sccache"
		echo "CARGO_INCREMENTAL=0"
		echo "SCCACHE_WEBDAV_ENDPOINT=$base/feeds/${ANT_SCCACHE_FEED:-sccache}/raw"
		echo "SCCACHE_WEBDAV_TOKEN=$token"
		echo "SCCACHE_WEBDAV_KEY_PREFIX=${ANT_SCCACHE_PREFIX:-${GITHUB_REPOSITORY:-}}"
	} >>"$GITHUB_ENV"
	echo "Kuvryn Ant: sccache $(sccache --version 2>/dev/null | awk '{print $2}') -> $base/feeds/${ANT_SCCACHE_FEED:-sccache}/raw"
fi
echo "sccache=$sccache_ok" >>"$GITHUB_OUTPUT"
