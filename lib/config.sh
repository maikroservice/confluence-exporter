#!/usr/bin/env bash
# lib/config.sh - Configuration loading
# Precedence (highest to lowest): CLI flags > env vars > .confluencerc > defaults

config_load() {
  # Load .confluencerc from project dir or home dir (not both)
  local rc_file=""
  if [ -f "./.confluencerc" ]; then
    rc_file="./.confluencerc"
  elif [ -f "${HOME}/.confluencerc" ]; then
    rc_file="${HOME}/.confluencerc"
  fi

  if [ -n "$rc_file" ]; then
    log_debug "Loading config from $rc_file"
    # Parse KEY=VALUE lines, skip comments and blank lines
    while IFS='=' read -r key value; do
      case "$key" in
        \#*|"") continue ;;
      esac
      # Strip inline comments and surrounding whitespace/quotes from value
      value=$(printf '%s' "$value" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed "s/^['\"]//;s/['\"]$//")
      key=$(printf '%s' "$key" | sed 's/[[:space:]]//g')
      # Only set if not already set by environment
      eval "CONFLUENCE_RC_${key}=\"\${value}\""
    done < "$rc_file"

    # Apply rc values only if env vars not already set
    _config_apply_rc CONFLUENCE_URL
    _config_apply_rc CONFLUENCE_TYPE
    _config_apply_rc CONFLUENCE_USERNAME
    _config_apply_rc CONFLUENCE_EMAIL
    _config_apply_rc CONFLUENCE_TOKEN
    _config_apply_rc CONFLUENCE_PASSWORD
    _config_apply_rc CONFLUENCE_AUTH_TYPE
    _config_apply_rc CONFLUENCE_OUTPUT_DIR
    _config_apply_rc CONFLUENCE_FORMAT
    _config_apply_rc CONFLUENCE_DEBUG
    _config_apply_rc CONFLUENCE_MAX_RETRIES
    _config_apply_rc CONFLUENCE_RETRY_DELAY
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

_config_apply_rc() {
  local var="$1"
  local rc_var="CONFLUENCE_RC_${var#CONFLUENCE_}"
  # If the main var is unset and the rc var has a value, apply it
  if [ -z "${!var:-}" ]; then
    local rc_val
    rc_val=$(eval "printf '%s' \"\${${rc_var}:-}\"")
    if [ -n "$rc_val" ]; then
      export "$var"="$rc_val"
    fi
  fi
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
