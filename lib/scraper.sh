#!/usr/bin/env bash
# lib/scraper.sh - HTML scraper fallback for public Confluence pages
# Uses curl + awk only; no external HTML parsing tools required.

# Fetch a public Confluence page and extract its main content as HTML
# Usage: scraper_fetch_page <url>
scraper_fetch_page() {
  local url="$1"
  local tmp_html
  tmp_html=$(mktemp)

  log_debug "Scraping: $url"
  local http_code
  http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_html" \
    -H "User-Agent: Mozilla/5.0 (compatible; confluence-exporter)" \
    "$url" 2>/dev/null)

  case "$http_code" in
    200) ;;
    401|403)
      rm -f "$tmp_html"
      log_error "Access denied (HTTP ${http_code}): $url — page may require authentication"
      return 1
      ;;
    404)
      rm -f "$tmp_html"
      log_error "Page not found (HTTP 404): $url"
      return 1
      ;;
    000)
      rm -f "$tmp_html"
      log_error "Network error: could not connect to $url"
      return 2
      ;;
    *)
      rm -f "$tmp_html"
      log_error "HTTP ${http_code} fetching: $url"
      return 1
      ;;
  esac

  # Extract main content with awk depth-tracking state machine.
  # Targets: id="main-content", class="wiki-content", id="content",
  #          class="confluence-page-content"
  local extracted
  extracted=$(awk '
    # Count net depth change from all tags on a line using regex iteration
    function count_depth(line,    tmp, tag, delta) {
      tmp = line
      delta = 0
      while (match(tmp, /<[^>]+>/)) {
        tag = substr(tmp, RSTART, RLENGTH)
        if (tag ~ /^<\//) {
          delta--
        } else if (tag !~ /\/>$/ && tag !~ /^<!/) {
          delta++
        }
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      return delta
    }

    BEGIN { depth=0; printing=0 }

    !printing && (/id="main-content"/ || /id="content"[^-]/ || /class="[^"]*wiki-content[^"]*"/ || /class="[^"]*confluence-page-content[^"]*"/) {
      printing=1
      # Start at 1 for the trigger element itself; add any additional nesting on same line
      depth = 1 + count_depth($0) - 1
      if (depth < 1) depth = 1
      print
      next
    }

    printing {
      print
      depth += count_depth($0)
      if (depth <= 0) { printing=0; exit }
    }
  ' "$tmp_html")

  rm -f "$tmp_html"

  if [ -z "$extracted" ]; then
    log_error "Could not find main content in page: $url"
    return 1
  fi

  # Strip scripts, styles, and Confluence nav chrome
  printf '%s' "$extracted" | _scraper_strip_chrome
}

_scraper_strip_chrome() {
  awk '
    BEGIN { skip=0 }
    /<script[^>]*>/  { skip++; next }
    /<\/script>/     { if(skip>0) skip--; next }
    /<style[^>]*>/   { skip++; next }
    /<\/style>/      { if(skip>0) skip--; next }
    skip > 0         { next }
    { print }
  '
}

# Extract the page title from raw HTML, stripping " - Confluence" suffix
# Usage: scraper_extract_title <html_string>
scraper_extract_title() {
  local html="$1"
  printf '%s' "$html" \
    | grep -o '<title>[^<]*</title>' \
    | head -1 \
    | sed 's/<title>//;s/<\/title>//' \
    | sed 's/ - Confluence$//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Extract page ID from data-page-id attribute or URL patterns
# Usage: scraper_extract_page_id <html_string>
scraper_extract_page_id() {
  local html="$1"
  local page_id

  page_id=$(printf '%s' "$html" \
    | grep -o 'data-page-id="[0-9]*"' | head -1 \
    | sed 's/data-page-id="//;s/"//')
  [ -n "$page_id" ] && { printf '%s' "$page_id"; return 0; }

  page_id=$(printf '%s' "$html" \
    | grep -o 'pageId=[0-9]*' | head -1 \
    | sed 's/pageId=//')
  [ -n "$page_id" ] && { printf '%s' "$page_id"; return 0; }

  page_id=$(printf '%s' "$html" \
    | grep -o '/pages/[0-9]*/' | head -1 \
    | sed 's|/pages/||;s|/||')
  printf '%s' "$page_id"
}

# Guard: reject unsupported scopes in scraper mode
scraper_check_scope() {
  local scope="$1"
  case "$scope" in
    page) return 0 ;;
    recursive|space)
      log_fatal "Scraper mode supports only single-page export (--page). Recursive and space exports require API credentials."
      ;;
  esac
}
