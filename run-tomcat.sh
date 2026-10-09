#!/usr/bin/env bash
#
# Mint a PNC DA access token and run the ant-manipulation CLI against the
# Tomcat corpus. Rewrites in place by default (the target is a git checkout,
# so `git restore` undoes it); pass --preview for a dry run that only logs
# the planned edits.
#
#   ./run-tomcat.sh            # rewrite build files in place
#   ./run-tomcat.sh --preview  # dry run: log planned edits only
#
set -euo pipefail

# --- config ---------------------------------------------------------------
LTWL_BASE=$HOME/project/git/lightwell/
REPO="$LTWL_BASE/ant-manipulator"
JAR="$REPO/cli/target/ant-manipulation-cli.jar"
TARGET="$LTWL_BASE/antprojects/$1"          # NB: plural "antprojects"; the singular path does not exist
BUILD_FILE="$TARGET/build.xml"
DA_URL="https://da.pnc.engineering.redhat.com/rest/v-1"
DEPLOY_VERSION="7.0.30"                    # tomcat's maven.asf.release.deploy.version (runtime-echoed; must be supplied)
SAVED="$HOME/.config/pnc-bacon/saved-user.json"
JAVA_HOME="/Library/Java/JavaVirtualMachines/graalvm-25.jdk/Contents/Home"
[ -x "$JAVA_HOME/bin/java" ] && JAVA="$JAVA_HOME/bin/java" || JAVA="java"

# write in place unless the caller asks for a dry run
PREVIEW=""
[ "${1:-}" = "--preview" ] && PREVIEW="--preview"

# --- sanity checks --------------------------------------------------------
[ -f "$JAR" ]        || { echo "jar not found: $JAR (run mvn package)"; exit 1; }
[ -f "$BUILD_FILE" ] || { echo "build file not found: $BUILD_FILE"; exit 1; }
[ -f "$SAVED" ]      || { echo "bacon token cache not found: $SAVED"; exit 1; }

# --- 1. rotate the refresh token via a throwaway bacon lookup -------------
echo ">> rotating refresh token via bacon da lookup ..."
bacon da lookup maven junit:junit:4.13.2 >/dev/null 2>&1 \
  || echo "   (bacon lookup failed/skipped — will try minting from the cached refresh token)"

# --- 2. mint a fresh access token from the refresh token ------------------
echo ">> minting access token from Keycloak ..."
TOKEN="$(python3 - <<'PY'
import json, os, ssl, sys, urllib.parse, urllib.request, urllib.error
saved = os.path.expanduser("~/.config/pnc-bacon/saved-user.json")
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
)"
[ -n "$TOKEN" ] || { echo "no token minted, aborting"; exit 1; }
echo "   got access token (${#TOKEN} chars)"

# --- 3. run the CLI against the tomcat tree ------------------------------
echo ">> running ant-manipulation against $TARGET ${PREVIEW:-(WRITE MODE)} ..."
"$JAVA" -jar "$JAR" \
  -f "$BUILD_FILE" \
  -DrestURL="$DA_URL" \
  -DrestMode=PERSISTENT \
  -DversionIncrementalSuffix=redhat \
  -Dmaven.asf.release.deploy.version="$DEPLOY_VERSION" \
  -DrestHeaders="Authorization:Bearer $TOKEN" \
  $PREVIEW
