#!/usr/bin/env bash
# lib/auth.sh - Auth header construction for all credential schemes

# Returns the Authorization header value (not the header name)
auth_build_header() {
  case "${CONFLUENCE_AUTH_TYPE:-basic}" in
    bearer)
      if [ -z "${CONFLUENCE_TOKEN:-}" ]; then
        log_fatal "CONFLUENCE_TOKEN is required for bearer auth"
      fi
      printf 'Bearer %s' "${CONFLUENCE_TOKEN}"
      ;;
    basic)
      local credentials
      if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
        if [ -z "${CONFLUENCE_EMAIL:-}" ] || [ -z "${CONFLUENCE_TOKEN:-}" ]; then
          log_fatal "CONFLUENCE_EMAIL and CONFLUENCE_TOKEN are required for Cloud basic auth"
        fi
        credentials="${CONFLUENCE_EMAIL}:${CONFLUENCE_TOKEN}"
      else
        # Server/DC: use token as password if set, else use password
        local pass="${CONFLUENCE_TOKEN:-${CONFLUENCE_PASSWORD:-}}"
        if [ -z "${CONFLUENCE_USERNAME:-}" ] || [ -z "$pass" ]; then
          log_fatal "CONFLUENCE_USERNAME and CONFLUENCE_TOKEN (or CONFLUENCE_PASSWORD) are required for Server basic auth"
        fi
        credentials="${CONFLUENCE_USERNAME}:${pass}"
      fi
      # base64 encode without line wrapping (-w 0 on GNU, no flag needed on macOS)
      local encoded
      encoded=$(printf '%s' "$credentials" | base64 | tr -d '\n')
      printf 'Basic %s' "$encoded"
      ;;
    *)
      log_fatal "Unknown CONFLUENCE_AUTH_TYPE: ${CONFLUENCE_AUTH_TYPE}"
      ;;
  esac
}

# Test API connectivity with a lightweight request
# Returns 0 on success, 1 on auth failure, 2 on other error
auth_test_connectivity() {
  local base_url="${CONFLUENCE_URL%/}"
  local test_url
  local auth_header
  auth_header=$(auth_build_header)

  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    test_url="${base_url}/wiki/api/v2/spaces?limit=1"
  else
    test_url="${base_url}/rest/api/space?limit=1"
  fi

  log_debug "Testing connectivity: $test_url"
  local http_code
  http_code=$(curl -s -L --max-redirs 10 -o /dev/null -w "%{http_code}" \
    -H "Authorization: ${auth_header}" \
    -H "Accept: application/json" \
    "${test_url}" 2>/dev/null)

  case "$http_code" in
    200) log_debug "Connectivity test passed (HTTP 200)"; return 0 ;;
    401|403) log_error "Authentication failed (HTTP ${http_code}). Check your credentials."; return 1 ;;
    000) log_error "Could not connect to ${base_url}. Check CONFLUENCE_URL."; return 2 ;;
    3*) log_error "Unexpected redirect (HTTP ${http_code}). Check CONFLUENCE_URL — ensure it uses https:// and points directly to your Confluence instance (not a login/SSO page)."; return 2 ;;
    *) log_error "Unexpected HTTP ${http_code} from ${base_url}"; return 2 ;;
  esac
}
