# Shared helpers for the Kuvryn Ant actions. POSIX sh, sourced.
# Needs curl, wget or node (18+). Never prints the token.

fetch() { # fetch URL [auth-header] [body] [method]
	_m=${4:-}
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_m" ]; then
			curl -fsS --retry 3 -m 60 -X "$_m" -H "$2" "$1"
		elif [ -n "${3:-}" ]; then
			curl -fsS --retry 3 -m 30 -H "$2" -H 'Content-Type: application/json' -d "$3" "$1"
		else
			curl -fsS --retry 3 -m 30 -H "$2" "$1"
		fi
	elif command -v wget >/dev/null 2>&1; then
		if [ -n "$_m" ]; then
			wget -q -T 60 -O - --method="$_m" --header "$2" "$1"
		elif [ -n "${3:-}" ]; then
			wget -q -T 30 -O - --header "$2" --header 'Content-Type: application/json' --post-data "$3" "$1"
		else
			wget -q -T 30 -O - --header "$2" "$1"
		fi
	elif command -v node >/dev/null 2>&1; then
		ANT_U="$1" ANT_H="$2" ANT_B="${3:-}" ANT_M="$_m" node -e '
const [k, ...v] = process.env.ANT_H.split(":");
const h = { [k]: v.join(":").trim(), "Content-Type": "application/json" };
const b = process.env.ANT_B;
const o = process.env.ANT_M ? { method: process.env.ANT_M, headers: h } : b ? { method: "POST", headers: h, body: b } : { headers: h };
fetch(process.env.ANT_U, o)
  .then(async (r) => { if (!r.ok) process.exit(22); process.stdout.write(await r.text()); })
  .catch(() => process.exit(7));'
	else
		return 127
	fi
}

json_field() { # json_field NAME  (reads stdin; flat string fields only)
	sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_number() { # json_number NAME  (reads stdin; flat numeric/boolean fields)
	sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9a-z]*\).*/\1/p" | head -n 1
}

# cache_tag_part VALUE [MAXLEN]: make VALUE a valid OCI tag fragment
# ([A-Za-z0-9_.-], no leading "." or "-"), truncated to MAXLEN (default 80).
cache_tag_part() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/^[-.]*//' | cut -c1-"${2:-80}"
}

# ant_host: print the Ant host to use. Order: the `host` input ($ANT_HOST), the host of
# the `ant-url` input ($ANT_URL), then, for repositories of the azrtydxb organization
# only, the default deployment (existing callers there pass neither). Anyone else must
# say which Ant to talk to; nothing is guessed, so no OIDC token is ever sent to a host
# the caller did not name.
ant_host() {
	if [ -n "${ANT_HOST:-}" ]; then
		printf '%s' "$ANT_HOST"
	elif [ -n "${ANT_URL:-}" ]; then
		_u=${ANT_URL#*://}
		printf '%s' "${_u%%/*}"
	elif [ "${GITHUB_REPOSITORY_OWNER:-}" = azrtydxb ]; then
		printf '%s' ant.azrty.com
	fi
}

# ant_exchange HOST: GitHub OIDC -> Ant access token in $ANT_EXCHANGED_TOKEN.
# On failure sets $ANT_EXCHANGE_ERROR (a sentence that says what to fix) and returns 1.
#
# The exchange itself is the reachability check. Ant answers an anonymous GET /v2/ with
# 401 unless a default OCI feed allows anonymous reads, so probing /v2/ would report a
# healthy Ant as down and silently send the job to the public registries.
ant_exchange() {
	_base="https://$1"
	ANT_EXCHANGED_TOKEN=
	ANT_EXCHANGE_ERROR=
	[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
		{ ANT_EXCHANGE_ERROR="no GitHub OIDC token (add 'permissions: id-token: write'; Dependabot and fork PRs get none)"; return 1; }
	_out=$(fetch "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$_base" "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN") ||
		{ ANT_EXCHANGE_ERROR="requesting the GitHub OIDC token failed"; return 1; }
	_jwt=$(printf '%s' "$_out" | json_field value)
	[ -n "$_jwt" ] || { ANT_EXCHANGE_ERROR="empty GitHub OIDC token"; return 1; }
	_out=$(fetch "$_base/api/v1/auth/github-oidc/exchange" "Accept: application/json" "{\"token\":\"$_jwt\"}")
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		case $_rc in
		22 | 8) ANT_EXCHANGE_ERROR="$_base answered but refused the OIDC exchange (check that a trust rule matches this repository and ref, and that the audience is $_base)" ;;
		127) ANT_EXCHANGE_ERROR="neither curl, wget nor node is available to contact $_base" ;;
		*) ANT_EXCHANGE_ERROR="$_base is not reachable (the OIDC exchange request failed, exit code $_rc)" ;;
		esac
		return 1
	fi
	_tok=$(printf '%s' "$_out" | json_field access_token)
	[ -n "$_tok" ] || { ANT_EXCHANGE_ERROR="the OIDC exchange at $_base returned no token"; return 1; }
	ANT_EXCHANGED_TOKEN=$_tok
	echo "::add-mask::$_tok"
}
