#!/bin/sh
set -eu

case "${1:-}" in
  *Username*) printf '%s\n' "${FORGEJO_USERNAME:?FORGEJO_USERNAME is required}" ;;
  *Password*) printf '%s\n' "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}" ;;
  *) exit 1 ;;
esac
