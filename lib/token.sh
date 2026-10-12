#!/usr/bin/env bash
#
# Mint a PNC DA access token from the cached bacon refresh token.
# Meant to be sourced, not executed.

SAVED_USER_JSON="${SAVED_USER_JSON:-$HOME/.config/pnc-bacon/saved-user.json}"

# Best-effort refresh-token rotation via a throwaway bacon lookup. Safe to
# ignore failures: mint_access_token() will still try the cached refresh
# token afterwards.
refresh_bacon_token() {
    echo ">> rotating refresh token via bacon da lookup ..." >&2
    bacon da lookup maven junit:junit:4.13.2 >/dev/null 2>&1 \
        || echo "   (bacon lookup failed/skipped — will try minting from the cached refresh token)" >&2
}

# Prints a fresh access token on stdout, or returns non-zero with a message
# on stderr.
mint_access_token() {
    [ -f "$SAVED_USER_JSON" ] || { echo "bacon token cache not found: $SAVED_USER_JSON" >&2; return 1; }

    echo ">> minting access token from Keycloak ..." >&2
    local token
    token="$(python3 - "$SAVED_USER_JSON" <<'PY'
import json, os, ssl, sys, urllib.parse, urllib.request, urllib.error
saved = sys.argv[1]
cd = json.load(open(saved)).get("cachedData", {})
if not cd:
    sys.stderr.write("no cachedData entries in saved-user.json — run bacon interactively to log in\n"); sys.exit(1)
# pick the entry whose refresh token expires furthest out
e = max(cd.values(), key=lambda v: v.get("refreshTokenExpiresIn", 0))
url = e["keycloakBaseUrl"].rstrip("/") + f"/auth/realms/{e['realm']}/protocol/openid-connect/token"
body = urllib.parse.urlencode({
    "grant_type":   "refresh_token",
    "client_id":    e.get("client", "pncdirect"),
    "refresh_token": e["refreshToken"],
}).encode()
# RH internal CA is absent from Python's trust store; verify OFF here (Java uses its own truststore fine)
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    resp = urllib.request.urlopen(urllib.request.Request(url, data=body), context=ctx)
except urllib.error.HTTPError as ex:
    sys.stderr.write("Keycloak mint failed: %s\n%s\n" % (ex, ex.read().decode()))
    sys.stderr.write("If 'invalid_grant / Token is not active', run any 'bacon da lookup ...' interactively to re-login.\n")
    sys.exit(1)
print(json.load(resp)["access_token"])
PY
    )" || return 1

    [ -n "$token" ] || { echo "no token minted, aborting" >&2; return 1; }
    echo "   got access token (${#token} chars)" >&2
    printf '%s\n' "$token"
}
