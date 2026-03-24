#!/usr/bin/env bats
# tests/integration/test_api_mode.bats
# End-to-end API mode flows using a real fixture server.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/confluence-export.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/wiki/api/v2/spaces?limit=1",                  "fixture": "spaces_lookup.json",     "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=storage", "fixture": "page_single.json",       "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=view",    "fixture": "page_single_view.json",  "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345/children",            "fixture": "page_children_empty.json","status": 200},
  {"pattern": "/wiki/api/v2/pages/99999",                     "fixture": "error_404.json",         "status": 404},
  {"pattern": "/wiki/api/v2/pages/77777",                     "fixture": "error_401.json",         "status": 401}
]
EOF

  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
  _SERVER_PID=$!

  local i=0
  until curl -s "http://127.0.0.1:${_PORT}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  export CONFLUENCE_URL="http://127.0.0.1:${_PORT}"
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_EMAIL=user@example.com
  export CONFLUENCE_TOKEN=testtoken
  export CONFLUENCE_OUTPUT_DIR="$_OUT_DIR"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
  rm -rf "$_OUT_DIR"
}

# --- single page export ---

@test "single page export: exits 0 for valid page ID" {
  run "$EXPORT_SCRIPT" --page 12345 --format md
  [ "$status" -eq 0 ]
}

@test "single page export: creates a file in the output directory" {
  "$EXPORT_SCRIPT" --page 12345 --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single page export: output file contains page heading" {
  "$EXPORT_SCRIPT" --page 12345 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "Hello World" "$file"
}

@test "single page export: output file contains body text" {
  "$EXPORT_SCRIPT" --page 12345 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "Item one" "$file"
}

@test "single page export: html format creates .html file" {
  "$EXPORT_SCRIPT" --page 12345 --format html
  count=$(find "$_OUT_DIR" -name "*.html" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single page export: raw format creates .xml file" {
  "$EXPORT_SCRIPT" --page 12345 --format raw
  count=$(find "$_OUT_DIR" -name "*.xml" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single page export: exits non-zero for 404 page" {
  run "$EXPORT_SCRIPT" --page 99999 --format md
  [ "$status" -ne 0 ]
}

@test "single page export: exits non-zero for 401 auth failure" {
  run "$EXPORT_SCRIPT" --page 77777 --format md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "401" ]] || [[ "$output" =~ "auth" ]] || [[ "$output" =~ "Auth" ]]
}

@test "single page export: --output flag overrides CONFLUENCE_OUTPUT_DIR" {
  local custom_dir
  custom_dir=$(mktemp -d)
  run "$EXPORT_SCRIPT" --page 12345 --format md --output "$custom_dir"
  count=$(find "$custom_dir" -name "*.md" | wc -l | tr -d ' ')
  rm -rf "$custom_dir"
  [ "$count" -ge 1 ]
}

# --- --list dry run ---

@test "--list flag prints page title without creating files" {
  run "$EXPORT_SCRIPT" --page 12345 --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "My Test Page" ]]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- URL input ---

@test "single page export: accepts Cloud URL instead of bare ID" {
  run "$EXPORT_SCRIPT" \
    --page "http://127.0.0.1:${_PORT}/wiki/spaces/TESTSPACE/pages/12345/My-Test-Page" \
    --format md
  [ "$status" -eq 0 ]
}
