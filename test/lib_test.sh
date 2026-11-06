#!/bin/sh
# Unit tests for lib.sh: the OIDC exchange must not need an anonymous GET /v2/, and it must say
# why it fell back. fetch is replaced by a function that plays a server; no network is used.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"

fail=0
check() { # check NAME CONDITION-RESULT(0=ok)
	if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/oidc?x=1"
ACTIONS_ID_TOKEN_REQUEST_TOKEN="runner-secret"

# A server like Ant without an anonymous OCI feed: /v2/ answers 401 (curl -f exits 22), the OIDC
# provider and the exchange endpoint work.
EXCHANGE_RC=0
V2_PROBES=0
fetch() {
	case "$1" in
	*/v2/*) V2_PROBES=$((V2_PROBES + 1)); return 22 ;;
	https://token.example/*) printf '{"value":"jwt-value"}' ;;
	*/api/v1/auth/github-oidc/exchange)
		[ "$EXCHANGE_RC" -eq 0 ] || return "$EXCHANGE_RC"
		printf '{"access_token":"ant_tok","token_type":"Bearer"}' ;;
	*) return 22 ;;
	esac
}

ant_exchange ant.example.com >/dev/null
check "exchange succeeds although anonymous /v2/ answers 401" $?
[ "$ANT_EXCHANGED_TOKEN" = ant_tok ]
check "token returned" $?
[ "$V2_PROBES" -eq 0 ]
check "no anonymous /v2/ probe is made" $?

EXCHANGE_RC=22
ant_exchange ant.example.com >/dev/null
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$ANT_EXCHANGE_ERROR" | grep -q "refused"
check "an HTTP error from the exchange is reported as refused: $ANT_EXCHANGE_ERROR" $?

EXCHANGE_RC=7
ant_exchange ant.example.com >/dev/null
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$ANT_EXCHANGE_ERROR" | grep -q "not reachable"
check "a connection failure is reported as not reachable: $ANT_EXCHANGE_ERROR" $?

EXCHANGE_RC=0
unset ACTIONS_ID_TOKEN_REQUEST_URL
ant_exchange ant.example.com >/dev/null
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$ANT_EXCHANGE_ERROR" | grep -q "id-token: write"
check "a missing OIDC token explains the permission: $ANT_EXCHANGE_ERROR" $?

# Host resolution: explicit input, ant-url, the runner default, and the organization default.
ANT_DEFAULT_HOST=
ANT_HOST=custom.example.com ANT_URL=
[ "$(ant_host)" = custom.example.com ]
check "host input wins" $?
ANT_HOST= ANT_URL=https://ant.other.example/base/
[ "$(ant_host)" = ant.other.example ]
check "ant-url is reduced to its host" $?
ANT_HOST= ANT_URL= GITHUB_REPOSITORY_OWNER=azrtydxb
[ "$(ant_host)" = ant.azrty.com ]
check "the azrtydxb organization keeps its default" $?
ANT_HOST= ANT_URL= GITHUB_REPOSITORY_OWNER=someone-else
[ -z "$(ant_host)" ]
check "other owners get no implicit host" $?

ANT_HOST= ANT_URL= ANT_DEFAULT_HOST=ant.kw.example.lab GITHUB_REPOSITORY_OWNER=azrtydxb
[ "$(ant_host)" = ant.kw.example.lab ]
check "the runner default beats the organization default" $?
ANT_HOST= ANT_URL= ANT_DEFAULT_HOST=ant.kw.example.lab GITHUB_REPOSITORY_OWNER=someone-else
[ "$(ant_host)" = ant.kw.example.lab ]
check "the runner default works for any owner" $?
ANT_HOST=custom.example.com ANT_URL= ANT_DEFAULT_HOST=ant.kw.example.lab
[ "$(ant_host)" = custom.example.com ]
check "host input beats the runner default" $?
ANT_HOST= ANT_URL=https://ant.other.example/ ANT_DEFAULT_HOST=ant.kw.example.lab
[ "$(ant_host)" = ant.other.example ]
check "ant-url beats the runner default" $?
ANT_HOST= ANT_URL= ANT_DEFAULT_HOST=https://ant.kw.example.lab/ GITHUB_REPOSITORY_OWNER=azrtydxb
[ -z "$(ant_host 2>/dev/null)" ] && ant_host 2>&1 | grep -q "bare host name"
check "a runner default with a scheme or path is refused, not replaced by the org default" $?

exit $fail

# Extra docker login host: only for a runner-default host, azrtydxb, docker-login on.
x() { ANT_DOCKER=$1 ANT_HOST=$2 ANT_URL=$3 ANT_DEFAULT_HOST=$4 GITHUB_REPOSITORY_OWNER=$5 ant_extra_login_host "$6"; }
[ "$(x true '' '' ant.kw.example.lab azrtydxb ant.kw.example.lab)" = ant.azrty.com ]
check "runner default + azrtydxb + docker-login adds the org Ant login" $?
[ -z "$(x false '' '' ant.kw.example.lab azrtydxb ant.kw.example.lab)" ]
check "no extra login without docker-login" $?
[ -z "$(x true custom.example.com '' ant.kw.example.lab azrtydxb custom.example.com)" ]
check "no extra login when the host input is set" $?
[ -z "$(x true '' https://custom.example.com '' azrtydxb custom.example.com)" ]
check "no extra login when ant-url is set" $?
[ -z "$(x true '' '' ant.kw.example.lab someone-else ant.kw.example.lab)" ]
check "no extra login for other owners (no token to a host they did not configure)" $?
[ -z "$(x true '' '' '' azrtydxb ant.azrty.com)" ]
check "no extra login when the org default already applies" $?
[ -z "$(x true '' '' ant.azrty.com azrtydxb ant.azrty.com)" ]
check "no duplicate login when the runner default is the org Ant" $?
[ -z "$(x true '' '' 'bad host' azrtydxb '')" ]
check "no extra login for a rejected (malformed) runner default" $?
