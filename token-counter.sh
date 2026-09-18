#!/usr/bin/env bash
# How much context each /sdd-* command puts in front of a model before it has
# read a single spec file. All logic lives in .sdd/scripts/lib/token-counter.py
# — this file only resolves paths and execs python3.
#
# Usage: ./token-counter.sh              pick "all" or one command from a menu
#        ./token-counter.sh all          every command, no prompt
#        ./token-counter.sh <slash-name> one command, no prompt
#
# With no argument and no terminal to ask on — a pipe, a redirect of stderr,
# CI — it reports every command rather than blocking on a menu nobody can see.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
COUNTER="$ROOT_DIR/.sdd/scripts/lib/token-counter.py"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python3"

if [[ $# -gt 1 ]]; then
  printf 'ERROR=usage: token-counter.sh [all|<slash-name>]\n' >&2
  exit 1
fi

if [[ -x "$VENV_PYTHON" ]]; then
  PYTHON="$VENV_PYTHON"
else
  PYTHON="$(command -v python3 || true)"
  if [[ -z "$PYTHON" ]]; then
    printf 'ERROR=python3 not found\n' >&2
    exit 1
  fi
fi

if [[ ! -r "$COUNTER" ]]; then
  printf 'ERROR=missing: %s\n' "$COUNTER" >&2
  exit 1
fi

exec "$PYTHON" "$COUNTER" "$ROOT_DIR" "$@"
