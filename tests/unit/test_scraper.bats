#!/usr/bin/env bats
# tests/unit/test_scraper.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/scraper.sh"
  deps_check

  # Start fixture server serving HTML fixtures
  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/wiki/spaces/TEST/pages/12345",  "fixture": "page_public.html",           "status": 200},
  {"pattern": "/wiki/spaces/TEST/pages/login",  "fixture": "page_no_main_content.html",  "status": 200},
  {"pattern": "/wiki/spaces/TEST/pages/denied", "fixture": "error_403.json",             "status": 403},
  {"pattern": "/wiki/spaces/TEST/pages/missing","fixture": "error_404.json",             "status": 404}
]
EOF

  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
  _SERVER_PID=$!

  local i=0
  until curl -s "http://127.0.0.1:${_PORT}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  export _BASE_URL="http://127.0.0.1:${_PORT}"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
}

# --- scraper_fetch_page ---

@test "scraper_fetch_page: succeeds on a page with main-content div" {
  run scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/12345"
  [ "$status" -eq 0 ]
}

@test "scraper_fetch_page: output contains page heading" {
  result=$(scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/12345")
  [[ "$result" =~ "Hello World" ]]
}

@test "scraper_fetch_page: output contains page body text" {
  result=$(scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/12345")
  [[ "$result" =~ "Item one" ]]
}

@test "scraper_fetch_page: output does not contain script tags" {
  result=$(scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/12345")
  [[ "$result" != *"<script"* ]]
}

@test "scraper_fetch_page: output does not contain footer content" {
  result=$(scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/12345")
  [[ "$result" != *"Footer content"* ]]
}

@test "scraper_fetch_page: fails with exit 1 when no main-content div found" {
  run scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/login"
  [ "$status" -ne 0 ]
}

@test "scraper_fetch_page: fails with exit 1 on HTTP 403" {
  run scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/denied"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "403" ]]
}

@test "scraper_fetch_page: fails with exit 1 on HTTP 404" {
  run scraper_fetch_page "${_BASE_URL}/wiki/spaces/TEST/pages/missing"
  [ "$status" -ne 0 ]
}

# --- scraper_extract_title ---

@test "scraper_extract_title: extracts title and strips ' - Confluence' suffix" {
  html=$(cat "$FIXTURES_DIR/page_public.html")
  result=$(scraper_extract_title "$html")
  [ "$result" = "My Test Page" ]
}

@test "scraper_extract_title: returns empty string when no title tag" {
  result=$(scraper_extract_title "<html><body>no title</body></html>")
  [ -z "$result" ]
}

# --- scraper_extract_page_id ---

@test "scraper_extract_page_id: extracts ID from data-page-id attribute" {
  html=$(cat "$FIXTURES_DIR/page_public.html")
  result=$(scraper_extract_page_id "$html")
  [ "$result" = "12345" ]
}

@test "scraper_extract_page_id: returns empty when no page ID found" {
  result=$(scraper_extract_page_id "<html><body>no id here</body></html>")
  [ -z "$result" ]
}

# --- scraper_check_scope ---

@test "scraper_check_scope: allows 'page' scope" {
  run scraper_check_scope "page"
  [ "$status" -eq 0 ]
}

@test "scraper_check_scope: rejects 'recursive' scope with fatal error" {
  run bash -c "
    source '${REPO_ROOT}/lib/log.sh'
    source '${REPO_ROOT}/lib/scraper.sh'
    scraper_check_scope 'recursive'
  " 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" =~ [Rr]ecursive ]]
}

@test "scraper_check_scope: rejects 'space' scope with fatal error" {
  run scraper_check_scope "space"
  [ "$status" -ne 0 ]
}
