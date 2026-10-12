#!/usr/bin/env bash
#
# Mint a PNC DA access token and run the ant-manipulation CLI against one or
# all project versions listed in projects.conf. Each entry's git ref is
# checked out into a disposable worktree (never touching the persistent
# main/master checkout under antprojects/), since some checkouts have
# migrated off ant and only historical refs still have a usable build.xml.
# Rewrites build files in place inside that worktree by default; pass
# --preview for a dry run that only logs the planned edits. Worktrees from
# preview runs are removed automatically; worktrees from real (write) runs
# are left on disk so the rewritten build files can be inspected, and must
# be removed manually (path printed at the end of the run).
#
#   ./run-tests.sh tomcat              # run every configured tomcat version
#   ./run-tests.sh tomcat --preview    # dry run for tomcat only
#   ./run-tests.sh --all               # run every project/version in projects.conf
#   ./run-tests.sh --all --preview     # dry run for everything
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/token.sh
source "$SCRIPT_DIR/lib/token.sh"
# shellcheck source=lib/run-cli.sh
source "$SCRIPT_DIR/lib/run-cli.sh"
# shellcheck source=lib/checkout.sh
source "$SCRIPT_DIR/lib/checkout.sh"

# --- config -----------------------------------------------------------------
LTWL_BASE="${LTWL_BASE:-$HOME/projects/git/lightwell}"
REPO="${REPO:-$LTWL_BASE/ant-manipulator}"
JAR="${JAR:-$REPO/cli/target/ant-manipulation-cli.jar}"
ANTPROJECTS="${ANTPROJECTS:-$LTWL_BASE/antprojects}"
PROJECTS_CONF="${PROJECTS_CONF:-$SCRIPT_DIR/projects.conf}"
DA_URL="${DA_URL:-https://da.pnc.engineering.redhat.com/rest/v-1}"
LOGS_DIR="${LOGS_DIR:-$SCRIPT_DIR/logs}"
RUN_TS="$(date +%Y%m%dT%H%M%S)"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <project-name>|--all [--preview]

Projects are read from $PROJECTS_CONF.
EOF
    exit 1
}

# --- parse args ---------------------------------------------------------------
TARGET_NAME=""
RUN_ALL=""
PREVIEW=""
for arg in "$@"; do
    case "$arg" in
        --preview) PREVIEW="--preview" ;;
        --all)     RUN_ALL=1 ;;
        -*)        usage ;;
        *)         TARGET_NAME="$arg" ;;
    esac
done
[ -n "$TARGET_NAME" ] || [ -n "$RUN_ALL" ] || usage

# --- load selected projects from config ---------------------------------------
[ -f "$PROJECTS_CONF" ] || { echo "projects config not found: $PROJECTS_CONF"; exit 1; }

declare -a SELECTED_NAMES SELECTED_DIRS SELECTED_REFS SELECTED_VERSIONS SELECTED_GROUP_IDS SELECTED_ARTIFACT_IDS
while IFS='|' read -r name dir ref version group_id artifact_id; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ -n "$RUN_ALL" ] || [ "$name" = "$TARGET_NAME" ]; then
        SELECTED_NAMES+=("$name")
        SELECTED_DIRS+=("$dir")
        SELECTED_REFS+=("$ref")
        SELECTED_VERSIONS+=("$version")
        SELECTED_GROUP_IDS+=("$group_id")
        SELECTED_ARTIFACT_IDS+=("$artifact_id")
    fi
done < "$PROJECTS_CONF"

[ "${#SELECTED_NAMES[@]}" -gt 0 ] || { echo "no matching project '$TARGET_NAME' in $PROJECTS_CONF"; exit 1; }

# --- sanity checks --------------------------------------------------------------
[ -f "$JAR" ] || { echo "jar not found: $JAR (run mvn package)"; exit 1; }
mkdir -p "$LOGS_DIR"

# --- mint one token, reuse it across every selected project ---------------------
refresh_bacon_token
TOKEN="$(mint_access_token)"

# --- run --------------------------------------------------------------------------
FAILED=()
KEPT_WORKTREES=()
for i in "${!SELECTED_NAMES[@]}"; do
    name="${SELECTED_NAMES[$i]}"
    dir="${SELECTED_DIRS[$i]}"
    ref="${SELECTED_REFS[$i]}"
    version="${SELECTED_VERSIONS[$i]}"
    group_id="${SELECTED_GROUP_IDS[$i]}"
    artifact_id="${SELECTED_ARTIFACT_IDS[$i]}"
    project_dir="$ANTPROJECTS/$dir"

    echo "=== $name @ $ref (deploy-version $version) ==="

    if [ ! -d "$project_dir" ]; then
        echo "project dir not found: $project_dir" >&2
        FAILED+=("$name@$ref")
        continue
    fi

    if worktree_dir="$(add_project_worktree "$project_dir" "$ref" "$name")"; then
        :
    else
        echo "failed to check out ref '$ref' for '$name'" >&2
        FAILED+=("$name@$ref")
        continue
    fi

    build_file="$worktree_dir/build.xml"
    log_file="$LOGS_DIR/${name}-${ref//\//_}-${RUN_TS}.log"
    echo "    log: $log_file"

    if [ -f "$build_file" ]; then
        if run_ant_manipulation "$JAR" "$build_file" "$version" "$DA_URL" "$TOKEN" "$PREVIEW" "$group_id" "$artifact_id" > >(tee "$log_file") 2>&1; then
            rc=0
        else
            rc=$?
        fi
    else
        echo "build.xml not found at ref '$ref': $build_file" | tee "$log_file" >&2
        rc=1
    fi

    [ "$rc" -eq 0 ] || FAILED+=("$name@$ref")

    if [ -n "$PREVIEW" ]; then
        remove_project_worktree "$project_dir" "$worktree_dir"
    else
        echo "    worktree left for inspection: $worktree_dir"
        git -C "$worktree_dir" diff --stat || true
        KEPT_WORKTREES+=("$worktree_dir")
    fi
done

echo "logs written to $LOGS_DIR (run $RUN_TS)"

if [ "${#KEPT_WORKTREES[@]}" -gt 0 ]; then
    echo "worktrees with real changes kept for inspection:"
    printf '  %s\n' "${KEPT_WORKTREES[@]}"
    echo "remove them yourself when done, e.g.:"
    printf '  git -C <project_dir> worktree remove --force %s\n' "${KEPT_WORKTREES[@]}"
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "FAILED: ${FAILED[*]}" >&2
    exit 1
fi
