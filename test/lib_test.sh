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

# Host resolution: explicit input, ant-url, and the organization default.
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

exit $fail
