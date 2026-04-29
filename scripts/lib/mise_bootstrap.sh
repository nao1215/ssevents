#!/bin/sh
# mise_bootstrap.sh -- Shared helper that makes mise-managed tools
# (erlang, gleam, rebar, node) visible on PATH without requiring the
# caller to have run `mise activate` in the current shell.

_ssevents_mise_prepend() {
  case ":${PATH-}:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}" ;;
  esac
}

_SSEVENTS_MISE_TOOLS="gleam escript erl rebar3 node"

ssevents_mise_bootstrap() {
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.local/bin" ]; then
    _ssevents_mise_prepend "$HOME/.local/bin"
  fi

  if command -v mise >/dev/null 2>&1; then
    for _ssevents_bootstrap_tool in $_SSEVENTS_MISE_TOOLS; do
      _ssevents_bootstrap_path="$(mise which "$_ssevents_bootstrap_tool" 2>/dev/null || true)"
      if [ -n "$_ssevents_bootstrap_path" ]; then
        _ssevents_mise_prepend "$(dirname "$_ssevents_bootstrap_path")"
      fi
    done
    unset _ssevents_bootstrap_tool _ssevents_bootstrap_path
  fi

  if ! command -v gleam >/dev/null 2>&1 && [ -n "${HOME:-}" ]; then
    _ssevents_mise_prepend "$HOME/.local/share/mise/shims"
  fi

  export PATH
}

ssevents_require_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<EOF
error: required tool '$1' was not found on PATH.

This repository manages its toolchain (Erlang, Gleam, rebar3, Node)
with mise. To set up the development environment from a fresh
checkout:

    mise install

If mise itself is missing, see https://mise.jdx.dev/getting-started.html.
Alternatively, install '$1' by hand and make sure it is on PATH
before running this command.
EOF
  return 127
}

ssevents_mise_bootstrap
