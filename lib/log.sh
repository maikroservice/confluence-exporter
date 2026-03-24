#!/usr/bin/env bash
# lib/log.sh - Logging helpers

# All output goes to stderr so stdout stays clean for piping/redirection

_log_color() {
  local code="$1"
  if [ -t 2 ] && command -v tput >/dev/null 2>&1; then
    tput setaf "$code" 2>/dev/null || true
  fi
}

_log_reset() {
  if [ -t 2 ] && command -v tput >/dev/null 2>&1; then
    tput sgr0 2>/dev/null || true
  fi
}

log_info() {
  _log_color 2 >&2
  printf '[INFO]  %s\n' "$*" >&2
  _log_reset >&2
}

log_warn() {
  _log_color 3 >&2
  printf '[WARN]  %s\n' "$*" >&2
  _log_reset >&2
}

log_error() {
  _log_color 1 >&2
  printf '[ERROR] %s\n' "$*" >&2
  _log_reset >&2
}

log_debug() {
  if [ "${CONFLUENCE_DEBUG:-0}" = "1" ]; then
    _log_color 6 >&2
    printf '[DEBUG] %s\n' "$*" >&2
    _log_reset >&2
  fi
}

log_fatal() {
  log_error "$*"
  exit 1
}
