#!/usr/bin/env bash
#
# Check out a specific git ref of a project into a disposable worktree, so
# testing a historical (possibly pre-migration, ant-era) version never
# touches the persistent main/master checkout under antprojects/.
# Meant to be sourced, not executed.

WORKTREE_ROOT="${WORKTREE_ROOT:-/tmp/ant-cli-testing-worktrees}"

# add_project_worktree <project_dir> <ref> <name>
# Prints the worktree path on stdout on success.
add_project_worktree() {
    local project_dir=$1 ref=$2 name=$3
    local worktree_dir

    mkdir -p "$WORKTREE_ROOT"
    git -C "$project_dir" worktree prune >/dev/null 2>&1

    worktree_dir="$(mktemp -u "$WORKTREE_ROOT/${name}-${ref//\//_}-XXXXXX")"
    git -C "$project_dir" worktree add --detach --quiet "$worktree_dir" "$ref" >&2 || return 1
    printf '%s\n' "$worktree_dir"
}

# remove_project_worktree <project_dir> <worktree_dir>
remove_project_worktree() {
    local project_dir=$1 worktree_dir=$2
    git -C "$project_dir" worktree remove --force "$worktree_dir" >/dev/null 2>&1 \
        || rm -rf "$worktree_dir"
}
