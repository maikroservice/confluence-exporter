#!/usr/bin/env bash
# lib/deps.sh - Dependency detection; sets HAS_* capability flags

deps_check() {
  # curl is required; everything else degrades gracefully
  if ! command -v curl >/dev/null 2>&1; then
    log_fatal "curl is required but not found. Install curl and retry."
  fi
  export HAS_CURL=1

  if command -v jq >/dev/null 2>&1; then
    export HAS_JQ=1
    log_debug "jq found: $(command -v jq)"
  else
    export HAS_JQ=0
    log_warn "jq not found — JSON parsing will use basic grep/sed fallbacks (less reliable). Install jq for best results."
  fi

  if command -v pandoc >/dev/null 2>&1; then
    export HAS_PANDOC=1
    log_debug "pandoc found: $(command -v pandoc)"
  else
    export HAS_PANDOC=0
    log_info "pandoc not found — Markdown conversion will use built-in sed/awk converter (degraded output). Install pandoc for best results."
  fi
}

# Extract a JSON field without jq - basic fallback
# Usage: json_get <field> <json_string>
json_get() {
  local field="$1"
  local json="$2"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r ".$field // empty" 2>/dev/null
  else
    # Basic sed extraction - handles simple string values
    printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

# Extract a nested JSON field (dot notation, no arrays)
# Usage: json_get_nested <field.subfield> <json_string>
json_get_nested() {
  local field="$1"
  local json="$2"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r ".${field} // empty" 2>/dev/null
  else
    # For nested fields, attempt a best-effort grep
    local last_key
    last_key=$(printf '%s' "$field" | sed 's/.*\.//')
    json_get "$last_key" "$json"
  fi
}

# Check if a JSON value is null or empty
json_is_empty() {
  local val="$1"
  [ -z "$val" ] || [ "$val" = "null" ]
}
