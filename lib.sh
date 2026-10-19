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

# ant_exchange HOST: GitHub OIDC -> Ant access token in $ANT_EXCHANGED_TOKEN.
# On failure sets $ANT_EXCHANGE_ERROR and returns 1.
ant_exchange() {
	_base="https://$1"
	ANT_EXCHANGED_TOKEN=
	ANT_EXCHANGE_ERROR=
	fetch "$_base/v2/" "Accept: application/json" >/dev/null 2>&1 ||
		{ ANT_EXCHANGE_ERROR="$_base is not answering"; return 1; }
	[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
		{ ANT_EXCHANGE_ERROR="no GitHub OIDC token (add 'permissions: id-token: write'; Dependabot and fork PRs get none)"; return 1; }
	_jwt=$(fetch "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$_base" "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" | json_field value) ||
		{ ANT_EXCHANGE_ERROR="requesting the GitHub OIDC token failed"; return 1; }
	[ -n "$_jwt" ] || { ANT_EXCHANGE_ERROR="empty GitHub OIDC token"; return 1; }
	_tok=$(fetch "$_base/api/v1/auth/github-oidc/exchange" "Accept: application/json" "{\"token\":\"$_jwt\"}" | json_field access_token) ||
		{ ANT_EXCHANGE_ERROR="OIDC exchange at $_base was refused (check the trust rules)"; return 1; }
	[ -n "$_tok" ] || { ANT_EXCHANGE_ERROR="OIDC exchange returned no token"; return 1; }
	ANT_EXCHANGED_TOKEN=$_tok
	echo "::add-mask::$_tok"
}
