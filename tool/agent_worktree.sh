#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tool/agent_worktree.sh list
  tool/agent_worktree.sh create <branch> [base]

Environment:
  WORKTREE_ROOT  Parent directory for worktrees.
                 Default: <repo>/.agents/worktrees

This helper intentionally does not commit, merge, remove worktrees, or delete
branches. Those operations require explicit user confirmation in this project.
EOF
}

repo_root="$(git rev-parse --show-toplevel)"
default_root="$repo_root/.agents/worktrees"
worktree_root="${WORKTREE_ROOT:-$default_root}"

case "${1:-}" in
  list)
    git -C "$repo_root" worktree list
    ;;
  create)
    branch="${2:-}"
    base="${3:-main}"
    if [[ -z "$branch" ]]; then
      usage >&2
      exit 2
    fi
    if [[ "$branch" == -* || "$branch" == *..* ]]; then
      echo "Invalid branch name: $branch" >&2
      exit 2
    fi
    git -C "$repo_root" check-ref-format --branch "$branch" >/dev/null
    slug="${branch//\//-}"
    target="$worktree_root/$slug"
    if [[ -e "$target" ]]; then
      echo "Target already exists; refusing to overwrite: $target" >&2
      exit 1
    fi
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "Branch already exists; refusing ambiguous reuse: $branch" >&2
      exit 1
    fi
    mkdir -p "$worktree_root"
    git -C "$repo_root" rev-parse --verify "$base^{commit}" >/dev/null
    git -C "$repo_root" worktree add -b "$branch" "$target" "$base"
    printf 'worktree=%s\nbranch=%s\nbase=%s\n' "$target" "$branch" "$base"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
