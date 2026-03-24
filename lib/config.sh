#!/usr/bin/env bash
# lib/config.sh - Configuration loading
# Precedence (highest to lowest): CLI flags > env vars > .confluencerc > .env > defaults

config_load() {
  # Load in priority order (highest first). Each file only sets vars not already set,
  # so earlier files win over later ones.

  # 1. .confluencerc (project dir or home dir) — highest file-based priority
  local rc_file=""
  if [ -f "./.confluencerc" ]; then
    rc_file="./.confluencerc"
  elif [ -f "${HOME}/.confluencerc" ]; then
    rc_file="${HOME}/.confluencerc"
  fi
  if [ -n "$rc_file" ]; then
    log_debug "Loading config from $rc_file"
    _config_parse_file "$rc_file"
  fi

  # 2. .env (project dir only) — lowest file-based priority
  if [ -f "./.env" ]; then
    log_debug "Loading config from .env"
    _config_parse_file "./.env"
  fi

  # Apply defaults for anything still unset
  : "${CONFLUENCE_TYPE:=cloud}"
  : "${CONFLUENCE_FORMAT:=md}"
  : "${CONFLUENCE_OUTPUT_DIR:=./export}"
  : "${CONFLUENCE_MAX_RETRIES:=3}"
  : "${CONFLUENCE_RETRY_DELAY:=5}"
  : "${CONFLUENCE_DEBUG:=0}"
  : "${CONFLUENCE_AUTH_TYPE:=basic}"

  # Derive auth type if not explicitly set
  if [ -z "${CONFLUENCE_AUTH_TYPE:-}" ] || [ "${CONFLUENCE_AUTH_TYPE}" = "basic" ]; then
    if [ -n "${CONFLUENCE_TOKEN:-}" ] && [ -z "${CONFLUENCE_USERNAME:-}" ] && [ -z "${CONFLUENCE_EMAIL:-}" ]; then
      CONFLUENCE_AUTH_TYPE="bearer"
    fi
  fi

  export CONFLUENCE_URL CONFLUENCE_TYPE CONFLUENCE_USERNAME CONFLUENCE_EMAIL
  export CONFLUENCE_TOKEN CONFLUENCE_PASSWORD CONFLUENCE_AUTH_TYPE
  export CONFLUENCE_OUTPUT_DIR CONFLUENCE_FORMAT
  export CONFLUENCE_MAX_RETRIES CONFLUENCE_RETRY_DELAY CONFLUENCE_DEBUG

  log_debug "Config loaded: type=${CONFLUENCE_TYPE} format=${CONFLUENCE_FORMAT} output=${CONFLUENCE_OUTPUT_DIR}"
}

# Parse a KEY=VALUE file (supports comments, quoted values, inline comments).
# Only processes CONFLUENCE_* keys. Does not overwrite vars already set in the environment.
_config_parse_file() {
  local file="$1"
  local line key value
  while IFS= read -r line; do
    # Strip leading whitespace and skip blank lines and comments
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$line" in
      \#*|"") continue ;;
    esac
    # Split on first = only, preserving = signs in the value (e.g. base64 tokens)
    key=${line%%=*}
    value=${line#*=}
    # Clean key: remove all whitespace
    key=$(printf '%s' "$key" | sed 's/[[:space:]]//g')
    # Only process CONFLUENCE_* keys
    case "$key" in
      CONFLUENCE_*) ;;
      *) continue ;;
    esac
    # Clean value: strip inline comments, surrounding whitespace and quotes
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed "s/^['\"]//;s/['\"]$//")
    # Only apply if the env var is not already set
    if [ -z "${!key:-}" ]; then
      export "$key"="$value"
    fi
  done < "$file"
}


config_require() {
  local var="$1"
  local hint="${2:-Set $var in .confluencerc or as an environment variable}"
  if [ -z "${!var:-}" ]; then
    log_fatal "$var is required but not set. $hint (see .env.example)"
  fi
}

config_require_api() {
  config_require CONFLUENCE_URL "Set CONFLUENCE_URL to your Confluence base URL (e.g. https://yoursite.atlassian.net)"
  case "${CONFLUENCE_AUTH_TYPE}" in
    bearer)
      config_require CONFLUENCE_TOKEN "Set CONFLUENCE_TOKEN to your API token or PAT"
      ;;
    basic)
      if [ "${CONFLUENCE_TYPE}" = "cloud" ]; then
        config_require CONFLUENCE_EMAIL "Set CONFLUENCE_EMAIL to your Atlassian account email"
        config_require CONFLUENCE_TOKEN "Set CONFLUENCE_TOKEN to your Atlassian API token"
      else
        config_require CONFLUENCE_USERNAME "Set CONFLUENCE_USERNAME for Server/DC auth"
        # Password OR token required
        if [ -z "${CONFLUENCE_TOKEN:-}" ] && [ -z "${CONFLUENCE_PASSWORD:-}" ]; then
          log_fatal "Either CONFLUENCE_TOKEN or CONFLUENCE_PASSWORD is required for Server/DC basic auth"
        fi
      fi
      ;;
    *)
      log_fatal "Unknown CONFLUENCE_AUTH_TYPE: ${CONFLUENCE_AUTH_TYPE}. Use 'basic' or 'bearer'."
      ;;
  esac
}
