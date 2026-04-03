#!/usr/bin/env bash
# confluence-export.sh - Export Confluence pages via API or HTML scraping
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source all library modules
for _lib in log deps config auth api scraper convert output; do
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/${_lib}.sh"
done

# ---------------------------------------------------------------------------
# Signal handling — clean up partial writes and report progress on interrupt
# ---------------------------------------------------------------------------
_PAGES_WRITTEN=0
_INTERRUPTED=0

_on_exit() {
  # Remove any partial-write temp files left by output_write_file's atomic write
  if [ -n "${CONFLUENCE_OUTPUT_DIR:-}" ] && [ -d "${CONFLUENCE_OUTPUT_DIR}" ]; then
    find "${CONFLUENCE_OUTPUT_DIR}" -name '.tmp_*' -delete 2>/dev/null || true
  fi
  if [ "$_INTERRUPTED" = "1" ] && [ "${LIST_ONLY:-0}" != "1" ]; then
    if [ "$_PAGES_WRITTEN" -gt 0 ]; then
      log_info "Interrupted — ${_PAGES_WRITTEN} page(s) written to ${CONFLUENCE_OUTPUT_DIR}"
    else
      log_warn "Interrupted — no pages written yet (still fetching page list from API)"
    fi
  fi
}

trap '_INTERRUPTED=1; exit 130' INT TERM
trap '_on_exit' EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Export Confluence pages to Markdown, HTML, or raw storage XML.

Scope (optional — defaults to all accessible spaces):
  --page <url|id>        Export a single page
  --recursive <url|id>   Export a page and all its descendants
  --space <SPACE_KEY>    Export all pages in a space
                         (no flag: export all spaces the token can access)

Format:
  --format md|html|raw   Output format (default: md)

Output:
  --output <dir>         Output directory (default: ./export)
  --force                Overwrite existing files

Mode:
  --mode api|scraper     Force a specific mode (default: api)
  --scraper-fallback     Fall back to scraper mode on auth failure (401/403)

Options:
  --depth <n>            Limit recursive export depth (default: unlimited)
  --list                 Dry run: print what would be exported, no files written
  --debug                Enable verbose debug output
  --help                 Show this help

Authentication (via env vars or .confluencerc):
  CONFLUENCE_URL         Base URL (e.g. https://yoursite.atlassian.net)
  CONFLUENCE_TYPE        cloud (default) or server
  CONFLUENCE_AUTH_TYPE   basic (default) or bearer
  CONFLUENCE_EMAIL       Atlassian account email (Cloud basic auth)
  CONFLUENCE_TOKEN       API token (Cloud) or PAT (Server bearer)
  CONFLUENCE_USERNAME    Username (Server basic auth)
  CONFLUENCE_PASSWORD    Password (Server basic auth, if not using token)

See .env.example for all options.
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SCOPE=""
SCOPE_TARGET=""
FORMAT=""
OUTPUT_DIR=""
MODE=""
SCRAPER_FALLBACK=0
DEPTH=999
LIST_ONLY=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --page)        SCOPE=page;      SCOPE_TARGET="$2"; shift 2 ;;
    --recursive)   SCOPE=recursive; SCOPE_TARGET="$2"; shift 2 ;;
    --space)       SCOPE=space;     SCOPE_TARGET="$2"; shift 2 ;;
    --format)      FORMAT="$2";     shift 2 ;;
    --output)      OUTPUT_DIR="$2"; shift 2 ;;
    --mode)        MODE="$2";       shift 2 ;;
    --depth)       DEPTH="$2";      shift 2 ;;
    --force)       FORCE=1;         shift ;;
    --list)        LIST_ONLY=1;     shift ;;
    --scraper-fallback) SCRAPER_FALLBACK=1; shift ;;
    --debug)       export CONFLUENCE_DEBUG=1; shift ;;
    --help|-h)     usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

[ -z "$SCOPE" ] && SCOPE="all-spaces"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
deps_check
config_load

# CLI flags override config
[ -n "$FORMAT" ]     && export CONFLUENCE_FORMAT="$FORMAT"
[ -n "$OUTPUT_DIR" ] && export CONFLUENCE_OUTPUT_DIR="$OUTPUT_DIR"
[ "$FORCE" = "1" ]   && export CONFLUENCE_FORCE=1

: "${CONFLUENCE_FORMAT:=md}"
: "${CONFLUENCE_OUTPUT_DIR:=./export}"

# ---------------------------------------------------------------------------
# Determine mode
# ---------------------------------------------------------------------------
if [ -z "$MODE" ]; then
  MODE="api"
fi

if [ "$MODE" = "api" ]; then
  # Validate we have enough config to attempt API
  if [ -z "${CONFLUENCE_URL:-}" ]; then
    if [ "$SCRAPER_FALLBACK" = "1" ] && [ "$SCOPE" = "page" ]; then
      log_warn "CONFLUENCE_URL not set — switching to scraper mode"
      MODE="scraper"
    else
      log_fatal "CONFLUENCE_URL is required. Set it in .confluencerc or as an env var."
    fi
  fi
fi

if [ "$MODE" = "api" ]; then
  if [ "$SCRAPER_FALLBACK" = "1" ] && [ "$SCOPE" = "page" ]; then
    # Soft path: if no credentials at all, skip straight to scraper
    if [ -z "${CONFLUENCE_EMAIL:-}${CONFLUENCE_USERNAME:-}${CONFLUENCE_TOKEN:-}" ]; then
      log_warn "No credentials provided — using scraper mode"
      MODE="scraper"
    else
      # Have credentials: validate and test; fall back on failure
      config_require_api
      if ! auth_test_connectivity; then
        log_warn "API authentication failed — falling back to scraper mode"
        MODE="scraper"
      fi
    fi
  else
    config_require_api
    if ! auth_test_connectivity; then
      exit 1
    fi
  fi
fi

if [ "$MODE" = "scraper" ]; then
  scraper_check_scope "$SCOPE"
fi

log_debug "mode=${MODE} scope=${SCOPE} format=${CONFLUENCE_FORMAT} output=${CONFLUENCE_OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Export a single page (shared by API and scraper modes)
# ---------------------------------------------------------------------------
_export_page_api() {
  local page_id="$1"
  local parent_slug="${2:-}"

  log_debug "Exporting page: $page_id"
  local page_json
  page_json=$(api_get_page "$page_id") || return 1

  local title space_key slug
  title=$(api_extract_title "$page_json")
  space_key=$(api_extract_space_key "$page_json")
  # Fall back to extracting from URL if space_key missing (Cloud v2 uses spaceId not key)
  if [ -z "$space_key" ] || [ "$space_key" = "null" ]; then
    space_key="export"
  fi
  slug=$(output_slugify "$title")

  if [ "$LIST_ONLY" = "1" ]; then
    printf '[%s] %s (%s)\n' "$space_key" "$title" "$page_id"
    return 0
  fi

  local content
  case "$CONFLUENCE_FORMAT" in
    md)
      local view_html
      view_html=$(api_get_page_view "$page_id") || view_html=""
      if [ -z "$view_html" ]; then
        view_html=$(api_extract_body_view "$page_json")
      else
        view_html=$(api_extract_body_view "$view_html")
      fi
      content=$(convert_to_markdown "$view_html")
      ;;
    html)
      local view_json
      view_json=$(api_get_page_view "$page_id") || view_json="$page_json"
      content=$(api_extract_body_view "$view_json")
      ;;
    raw)
      content=$(api_extract_body_storage "$page_json")
      ;;
  esac

  local path
  path=$(output_build_path "$CONFLUENCE_OUTPUT_DIR" "$space_key" "$parent_slug" "$slug" "$CONFLUENCE_FORMAT")
  path=$(output_collision_path "$path" "$page_id")
  output_write_file "$path" "$content"
  _PAGES_WRITTEN=$((_PAGES_WRITTEN + 1))
  log_info "Exported: $title → $path"
}

_export_page_scraper() {
  local url="$1"

  log_debug "Scraping page: $url"
  local raw_html
  raw_html=$(scraper_fetch_page "$url") || return 1

  local title page_id slug
  # Fetch the full page HTML once to extract title/id
  local full_html
  full_html=$(curl -s -L \
    -H "User-Agent: Mozilla/5.0 (compatible; confluence-exporter)" \
    "$url" 2>/dev/null)
  title=$(scraper_extract_title "$full_html")
  page_id=$(scraper_extract_page_id "$full_html")
  [ -z "$title" ] && title="page-${page_id:-unknown}"
  slug=$(output_slugify "$title")

  if [ "$LIST_ONLY" = "1" ]; then
    printf '[scraper] %s (%s)\n' "$title" "${page_id:-unknown}"
    return 0
  fi

  local content
  case "$CONFLUENCE_FORMAT" in
    md)   content=$(convert_to_markdown "$raw_html") ;;
    html) content="$raw_html" ;;
    raw)  content="$raw_html" ;;
  esac

  local space_key="scraped"
  local path
  path=$(output_build_path "$CONFLUENCE_OUTPUT_DIR" "$space_key" "" "$slug" "$CONFLUENCE_FORMAT")
  path=$(output_collision_path "$path" "${page_id:-0}")
  output_write_file "$path" "$content"
  _PAGES_WRITTEN=$((_PAGES_WRITTEN + 1))
  log_info "Scraped: $title → $path"
}

# ---------------------------------------------------------------------------
# Write a space index file immediately after the space list is fetched
# ---------------------------------------------------------------------------
_write_spaces_index() {
  local spaces_file="$1"
  local index_path="${CONFLUENCE_OUTPUT_DIR}/_index.md"

  mkdir -p "$CONFLUENCE_OUTPUT_DIR" || return 1

  local date_str
  date_str=$(date '+%Y-%m-%d %H:%M:%S')

  {
    printf '# Confluence Spaces\n\n'
    printf '_Generated: %s_\n\n' "$date_str"
    printf '| Space Key | Name | Type | Export Path |\n'
    printf '|-----------|------|------|-------------|\n'

    while IFS= read -r space_json; do
      [ -z "$space_json" ] && continue
      local skey sname stype
      skey=$(api_extract_key "$space_json")
      [ -z "$skey" ] || [ "$skey" = "null" ] && continue

      if [ "${HAS_JQ:-0}" = "1" ]; then
        sname=$(printf '%s' "$space_json" | jq -r '.name // ""' 2>/dev/null)
        stype=$(printf '%s' "$space_json" | jq -r '.type // ""' 2>/dev/null)
      else
        sname=$(printf '%s' "$space_json" | grep -o '"name":"[^"]*"' | head -1 \
          | sed 's/"name":"//;s/"$//')
        stype=$(printf '%s' "$space_json" | grep -o '"type":"[^"]*"' | head -1 \
          | sed 's/"type":"//;s/"$//')
      fi

      printf '| %s | %s | %s | ./%s/ |\n' \
        "$skey" "${sname:-$skey}" "${stype:-}" "$skey"
    done < "$spaces_file"
  } > "$index_path"

  log_info "Space index written to: $index_path"
}

# ---------------------------------------------------------------------------
# Recursive export
# ---------------------------------------------------------------------------
_export_recursive() {
  local page_id="$1"
  local parent_slug="${2:-}"
  local depth="${3:-0}"

  [ "$depth" -ge "$DEPTH" ] && return 0

  local page_json title slug
  page_json=$(api_get_page "$page_id") || return 1
  title=$(api_extract_title "$page_json")
  slug=$(output_slugify "$title")

  _export_page_api "$page_id" "$parent_slug"

  local children_file
  children_file=$(mktemp)
  api_get_children "$page_id" "$children_file" || { rm -f "$children_file"; return 1; }

  local child_id child_json
  while IFS= read -r child_json; do
    [ -z "$child_json" ] && continue
    child_id=$(api_extract_id "$child_json")
    [ -z "$child_id" ] || [ "$child_id" = "null" ] && continue
    _export_recursive "$child_id" "$slug" "$((depth + 1))"
  done < "$children_file"

  rm -f "$children_file"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "$SCOPE" in

  all-spaces)
    log_info "No scope provided — checking all accessible Confluence spaces"
    spaces_file=$(mktemp)
    api_get_all_spaces "$spaces_file" || { rm -f "$spaces_file"; exit 1; }

    [ "$LIST_ONLY" != "1" ] && _write_spaces_index "$spaces_file"

    while IFS= read -r space_json; do
      [ -z "$space_json" ] && continue
      skey=$(api_extract_key "$space_json")
      [ -z "$skey" ] || [ "$skey" = "null" ] && continue

      if [ "$LIST_ONLY" = "1" ]; then
        sname=""
        if [ "${HAS_JQ:-0}" = "1" ]; then
          sname=$(printf '%s' "$space_json" | jq -r '.name // empty' 2>/dev/null)
        fi
        printf '[%s] %s\n' "$skey" "${sname:-$skey}"
      else
        log_info "Exporting space: $skey"
        pages_file=$(mktemp)
        if ! api_get_space_pages "$skey" "$pages_file"; then
          log_warn "Skipping space $skey (could not fetch pages)"
          rm -f "$pages_file"
          continue
        fi

        while IFS= read -r page_json; do
          [ -z "$page_json" ] && continue
          pid=$(api_extract_id "$page_json")
          [ -z "$pid" ] || [ "$pid" = "null" ] && continue
          _export_page_api "$pid" ""
        done < "$pages_file"
        rm -f "$pages_file"
      fi
    done < "$spaces_file"

    rm -f "$spaces_file"
    ;;

  page)
    if [ "$MODE" = "scraper" ]; then
      _export_page_scraper "$SCOPE_TARGET"
    else
      page_id=$(api_url_to_id "$SCOPE_TARGET") || exit 1
      _export_page_api "$page_id"
    fi
    ;;

  recursive)
    page_id=$(api_url_to_id "$SCOPE_TARGET") || exit 1
    _export_recursive "$page_id" "" 0
    ;;

  space)
    if [ "$LIST_ONLY" = "1" ]; then
      log_info "Listing pages in space: $SCOPE_TARGET"
    fi
    pages_file=$(mktemp)
    api_get_space_pages "$SCOPE_TARGET" "$pages_file" || { rm -f "$pages_file"; exit 1; }

    while IFS= read -r page_json; do
      [ -z "$page_json" ] && continue
      pid=$(api_extract_id "$page_json")
      [ -z "$pid" ] || [ "$pid" = "null" ] && continue

      ptitle=$(api_extract_title "$page_json")
      if [ "$LIST_ONLY" = "1" ]; then
        printf '[%s] %s (%s)\n' "$SCOPE_TARGET" "$ptitle" "$pid"
      else
        _export_page_api "$pid" ""
      fi
    done < "$pages_file"

    rm -f "$pages_file"
    ;;

esac
