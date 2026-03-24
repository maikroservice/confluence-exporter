#!/usr/bin/env bash
# lib/api.sh - Confluence REST API calls, pagination, and retry logic

# Build the base API URL depending on Cloud vs Server/DC
api_base_url() {
  local base="${CONFLUENCE_URL%/}"
  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    printf '%s/wiki/api/v2' "$base"
  else
    printf '%s/rest/api' "$base"
  fi
}

# Core curl wrapper with retry logic and auth headers
# Usage: api_curl <url> [extra_curl_args...]
# Writes response body to stdout; exports API_LAST_HTTP_CODE
api_curl() {
  local url="$1"; shift
  local auth_header
  auth_header=$(auth_build_header)

  local attempt=1
  local max_retries="${CONFLUENCE_MAX_RETRIES:-3}"
  local retry_delay="${CONFLUENCE_RETRY_DELAY:-5}"
  local tmp_body
  tmp_body=$(mktemp)

  while [ "$attempt" -le "$max_retries" ]; do
    log_debug "curl attempt ${attempt}/${max_retries}: $url"
    API_LAST_HTTP_CODE=$(curl -s -w "%{http_code}" -o "$tmp_body" \
      -H "Authorization: ${auth_header}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "$@" \
      "$url" 2>/dev/null)

    case "$API_LAST_HTTP_CODE" in
      200|201)
        cat "$tmp_body"
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        return 0
        ;;
      401|403)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Authentication failed (HTTP ${API_LAST_HTTP_CODE}) for: $url"
        return 1
        ;;
      404)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Not found (HTTP 404): $url"
        return 1
        ;;
      429)
        local wait_time="$retry_delay"
        if [ "${HAS_JQ:-0}" = "1" ]; then
          local retry_after
          retry_after=$(cat "$tmp_body" | jq -r '.retryAfter // empty' 2>/dev/null)
          [ -n "$retry_after" ] && wait_time="$retry_after"
        fi
        log_warn "Rate limited (HTTP 429). Waiting ${wait_time}s before retry ${attempt}/${max_retries}..."
        sleep "$wait_time"
        retry_delay=$((retry_delay * 2))
        attempt=$((attempt + 1))
        ;;
      000)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Network error: could not connect to ${CONFLUENCE_URL}"
        return 2
        ;;
      *)
        log_warn "HTTP ${API_LAST_HTTP_CODE} from API (attempt ${attempt}/${max_retries})"
        attempt=$((attempt + 1))
        sleep "$retry_delay"
        ;;
    esac
  done

  rm -f "$tmp_body"
  log_error "API request failed after ${max_retries} attempts: $url"
  return 2
}

# Extract the page ID from a Confluence URL or return it if already an ID
# Handles:
#   Cloud:     https://site.atlassian.net/wiki/spaces/KEY/pages/12345/Title
#   Server/DC: https://site.example.com/display/KEY/Page+Title
#              https://site.example.com/pages/viewpage.action?pageId=12345
api_url_to_id() {
  local url="$1"

  # Already a bare numeric ID
  if printf '%s' "$url" | grep -qE '^[0-9]+$'; then
    printf '%s' "$url"
    return 0
  fi

  # Cloud: /pages/12345/... or /pages/12345
  local page_id
  page_id=$(printf '%s' "$url" | sed -n 's|.*/pages/\([0-9][0-9]*\).*|\1|p')
  if [ -n "$page_id" ]; then
    printf '%s' "$page_id"
    return 0
  fi

  # Server/DC: ?pageId=12345
  page_id=$(printf '%s' "$url" | sed -n 's/.*[?&]pageId=\([0-9][0-9]*\).*/\1/p')
  if [ -n "$page_id" ]; then
    printf '%s' "$page_id"
    return 0
  fi

  # Server/DC: /display/SPACEKEY/Page+Title — need API title lookup
  local space_key page_title
  space_key=$(printf '%s' "$url" | sed -n 's|.*/display/\([^/?]*\)/.*|\1|p')
  page_title=$(printf '%s' "$url" | sed -n 's|.*/display/[^/?]*/\([^?]*\).*|\1|p' \
    | sed 's/+/ /g' | sed 's/%20/ /g')

  if [ -n "$space_key" ] && [ -n "$page_title" ]; then
    log_debug "Looking up page ID for: space=$space_key title=$page_title"
    local encoded_title
    encoded_title=$(printf '%s' "$page_title" | sed 's/ /+/g')
    local search_url
    search_url="$(api_base_url)/content?spaceKey=${space_key}&title=${encoded_title}&expand=space"
    local response
    response=$(api_curl "$search_url") || {
      log_error "Could not look up page by title: $page_title"
      return 1
    }
    if [ "${HAS_JQ:-0}" = "1" ]; then
      page_id=$(printf '%s' "$response" | jq -r '.results[0].id // empty')
    else
      page_id=$(printf '%s' "$response" | grep -o '"id":"[0-9]*"' | head -1 \
        | sed 's/"id":"//;s/"//')
    fi
    if [ -n "$page_id" ] && [ "$page_id" != "null" ]; then
      printf '%s' "$page_id"
      return 0
    fi
  fi

  log_error "Could not extract page ID from: $url"
  return 1
}

# Fetch a single page's metadata + storage body
# Usage: api_get_page <page_id>
api_get_page() {
  local page_id="$1"
  local base url
  base=$(api_base_url)

  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    url="${base}/pages/${page_id}?body-format=storage"
  else
    url="${base}/content/${page_id}?expand=body.storage,body.view,ancestors,space,version,title"
  fi

  log_debug "Fetching page: $page_id"
  api_curl "$url"
}

# Fetch a single page with rendered (view) body — may need a separate request on Cloud v2
api_get_page_view() {
  local page_id="$1"
  local base url
  base=$(api_base_url)

  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    url="${base}/pages/${page_id}?body-format=view"
  else
    url="${base}/content/${page_id}?expand=body.view"
  fi

  api_curl "$url"
}

# Fetch direct children of a page; appends JSON objects (one per line) to out_file
api_get_children() {
  local page_id="$1"
  local out_file="$2"
  local base
  base=$(api_base_url)

  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    api_paginate_all "${base}/pages/${page_id}/children?limit=50" "$out_file"
  else
    api_paginate_all \
      "${base}/content/${page_id}/child/page?limit=50&expand=title,space,ancestors" \
      "$out_file"
  fi
}

# Recursively collect all descendants; appends to out_file
# Usage: api_get_descendants <page_id> <out_file> [depth] [max_depth]
api_get_descendants() {
  local page_id="$1"
  local out_file="$2"
  local depth="${3:-0}"
  local max_depth="${4:-999}"

  [ "$depth" -ge "$max_depth" ] && return 0

  local children_file
  children_file=$(mktemp)
  api_get_children "$page_id" "$children_file" || { rm -f "$children_file"; return 1; }

  local child_id
  while IFS= read -r child_json; do
    [ -z "$child_json" ] && continue
    if [ "${HAS_JQ:-0}" = "1" ]; then
      child_id=$(printf '%s' "$child_json" | jq -r '.id // empty')
    else
      # Try quoted id first (Server v1), then unquoted (Cloud v2)
      child_id=$(printf '%s' "$child_json" \
        | grep -o '"id":"[0-9]*"' | head -1 | sed 's/"id":"//;s/"//')
      if [ -z "$child_id" ]; then
        child_id=$(printf '%s' "$child_json" \
          | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
      fi
    fi
    [ -z "$child_id" ] || [ "$child_id" = "null" ] && continue

    printf '%s\n' "$child_json" >> "$out_file"
    api_get_descendants "$child_id" "$out_file" "$((depth + 1))" "$max_depth"
  done < "$children_file"

  rm -f "$children_file"
}

# Fetch all pages in a space; appends JSON objects (one per line) to out_file
api_get_space_pages() {
  local space_key="$1"
  local out_file="$2"
  local base
  base=$(api_base_url)

  if [ "${CONFLUENCE_TYPE:-cloud}" = "cloud" ]; then
    # Cloud v2: look up space ID from key first
    local spaces_response space_id
    spaces_response=$(api_curl "${base}/spaces?keys=${space_key}&limit=1") || return 1
    space_id=$(printf '%s' "$spaces_response" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [ -z "$space_id" ] || [ "$space_id" = "null" ]; then
      log_error "Could not find space with key: $space_key"
      return 1
    fi
    api_paginate_all "${base}/spaces/${space_id}/pages?limit=50&depth=all" "$out_file"
  else
    api_paginate_all \
      "${base}/content?spaceKey=${space_key}&type=page&limit=50&expand=title,space,ancestors" \
      "$out_file"
  fi
}

# Paginate through all results, appending compact JSON objects (one per line) to out_file
# Handles cursor-based pagination (Cloud v2 _links.next) and offset pagination (Server v1)
api_paginate_all() {
  local url="$1"
  local out_file="$2"
  local page_num=0

  while [ -n "$url" ]; do
    log_debug "Paginating [page $((page_num + 1))]: $url"
    local response
    response=$(api_curl "$url") || {
      log_error "Pagination failed at: $url"
      return 1
    }

    if [ "${HAS_JQ:-0}" = "1" ]; then
      printf '%s' "$response" | jq -c '.results[]?' 2>/dev/null >> "$out_file"

      # Cursor pagination (Cloud v2)
      local next
      next=$(printf '%s' "$response" | jq -r '._links.next // empty' 2>/dev/null)
      if [ -n "$next" ]; then
        local base_domain="${CONFLUENCE_URL%/}"
        # next may be an absolute path like /wiki/api/v2/... or a full URL
        if printf '%s' "$next" | grep -q '^http'; then
          url="$next"
        else
          url="${base_domain}${next}"
        fi
      else
        # Offset pagination (Server v1)
        local size limit start
        size=$(printf '%s' "$response" | jq -r '.size // 0')
        limit=$(printf '%s' "$response" | jq -r '.limit // 25')
        start=$(printf '%s' "$response" | jq -r '.start // 0')
        if [ "$size" -ge "$limit" ] 2>/dev/null; then
          local next_start=$((start + limit))
          if printf '%s' "$url" | grep -q 'start='; then
            url=$(printf '%s' "$url" | sed "s/start=[0-9]*/start=${next_start}/")
          else
            url="${url}&start=${next_start}"
          fi
        else
          url=""
        fi
      fi
    else
      # No jq fallback: basic awk extraction, no pagination
      printf '%s' "$response" | awk '
        BEGIN { depth=0; capture=0; buf="" }
        /"results"[[:space:]]*:\[/ { capture=1; next }
        capture && /^\s*\{/ && depth==0 { depth=1; buf=$0"\n"; next }
        capture && depth>0 {
          buf=buf $0 "\n"
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1)
            if(c=="{") depth++
            if(c=="}") depth--
          }
          if(depth<=0){ print buf; buf=""; next }
        }
      ' >> "$out_file"
      url=""
    fi

    page_num=$((page_num + 1))
  done

  log_debug "Pagination complete: $page_num page(s) fetched"
}

# --- JSON field extractors ---

api_extract_body_storage() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.body.storage.value // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"value":"[^"]*"' | head -1 \
      | sed 's/"value":"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g'
  fi
}

api_extract_body_view() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.body.view.value // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"value":"[^"]*"' | sed -n '2p' \
      | sed 's/"value":"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g'
  fi
}

api_extract_title() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.title // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 \
      | sed 's/"title":"//;s/"$//'
  fi
}

api_extract_id() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null
  else
    local id
    id=$(printf '%s' "$json" | grep -o '"id":"[0-9]*"' | head -1 \
      | sed 's/"id":"//;s/"//')
    if [ -z "$id" ]; then
      id=$(printf '%s' "$json" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')
    fi
    printf '%s' "$id"
  fi
}

api_extract_space_key() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.space.key // .spaceId // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"key":"[^"]*"' | head -1 \
      | sed 's/"key":"//;s/"//'
  fi
}
