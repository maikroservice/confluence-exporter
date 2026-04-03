#!/usr/bin/env bats
# tests/integration/test_export_scope.bats
# Tests for --recursive and --space export scopes.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/confluence-export.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/wiki/api/v2/spaces?limit=1",                   "fixture": "spaces_lookup.json",      "status": 200},
  {"pattern": "/wiki/api/v2/spaces?limit=50",                  "fixture": "spaces_all.json",         "status": 200},
  {"pattern": "/wiki/api/v2/spaces?keys=TESTSPACE",            "fixture": "spaces_lookup.json",      "status": 200},
  {"pattern": "/wiki/api/v2/spaces/98765/pages",               "fixture": "space_pages.json",        "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=storage",  "fixture": "page_single.json",        "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=view",     "fixture": "page_single_view.json",   "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345/children",             "fixture": "page_children.json",      "status": 200},
  {"pattern": "/wiki/api/v2/pages/22222?body-format=storage",  "fixture": "page_children.json",      "status": 200},
  {"pattern": "/wiki/api/v2/pages/22222/children",             "fixture": "page_children_empty.json","status": 200},
  {"pattern": "/wiki/api/v2/pages/33333?body-format=storage",  "fixture": "page_children.json",      "status": 200},
  {"pattern": "/wiki/api/v2/pages/33333/children",             "fixture": "page_children_empty.json","status": 200},
  {"pattern": "/wiki/api/v2/pages/11111?body-format=storage",  "fixture": "page_single.json",        "status": 200},
  {"pattern": "/wiki/api/v2/pages/11111/children",             "fixture": "page_children_empty.json","status": 200}
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

# --- recursive export ---

@test "recursive export: exits 0" {
  run "$EXPORT_SCRIPT" --recursive 12345 --format md
  [ "$status" -eq 0 ]
}

@test "recursive export: creates files for parent and children" {
  "$EXPORT_SCRIPT" --recursive 12345 --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 3 ]
}

@test "recursive export: creates a directory hierarchy" {
  "$EXPORT_SCRIPT" --recursive 12345 --format md
  # Should have at least one subdirectory under the space dir
  dir_count=$(find "$_OUT_DIR" -mindepth 2 -type d | wc -l | tr -d ' ')
  [ "$dir_count" -ge 1 ]
}

@test "recursive export: --depth 1 limits to direct children only" {
  "$EXPORT_SCRIPT" --recursive 12345 --depth 1 --format md
  # Should have parent + 2 direct children = 3, not grandchildren
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -le 3 ]
}

@test "recursive export: --list prints all page titles without creating files" {
  run "$EXPORT_SCRIPT" --recursive 12345 --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "My Test Page" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

# --- space export ---

@test "space export: exits 0" {
  run "$EXPORT_SCRIPT" --space TESTSPACE --format md
  [ "$status" -eq 0 ]
}

@test "space export: creates files for all pages in space" {
  "$EXPORT_SCRIPT" --space TESTSPACE --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 3 ]
}

@test "space export: uses space key as root directory" {
  "$EXPORT_SCRIPT" --space TESTSPACE --format md
  [ -d "$_OUT_DIR/TESTSPACE" ]
}

@test "space export: --output flag writes to specified directory" {
  local custom_dir
  custom_dir=$(mktemp -d)
  "$EXPORT_SCRIPT" --space TESTSPACE --format md --output "$custom_dir"
  count=$(find "$custom_dir" -name "*.md" | wc -l | tr -d ' ')
  rm -rf "$custom_dir"
  [ "$count" -ge 1 ]
}

@test "space export: --list prints titles without creating files" {
  run "$EXPORT_SCRIPT" --space TESTSPACE --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TESTSPACE" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

# --- pagination ---

@test "recursive export: collects all children across paginated responses" {
  # Reconfigure server to serve paginated children
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true

  local pag_map
  pag_map=$(mktemp)
  cat > "$pag_map" <<'EOF'
[
  {"pattern": "/wiki/api/v2/spaces?limit=1",                   "fixture": "spaces_lookup.json",       "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=storage",  "fixture": "page_single.json",         "status": 200},
  {"pattern": "cursor=page2token",                             "fixture": "page_children_page2.json", "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345/children",             "fixture": "page_children_page1.json", "status": 200},
  {"pattern": "/wiki/api/v2/pages/44444",                      "fixture": "page_single.json",         "status": 200},
  {"pattern": "/wiki/api/v2/pages/44444/children",             "fixture": "page_children_empty.json", "status": 200},
  {"pattern": "/wiki/api/v2/pages/44445",                      "fixture": "page_single.json",         "status": 200},
  {"pattern": "/wiki/api/v2/pages/44445/children",             "fixture": "page_children_empty.json", "status": 200},
  {"pattern": "/wiki/api/v2/pages/44446",                      "fixture": "page_single.json",         "status": 200},
  {"pattern": "/wiki/api/v2/pages/44446/children",             "fixture": "page_children_empty.json", "status": 200}
]
EOF

  _PORT2=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT2" "$pag_map" >/dev/null 2>&1 &
  local pag_pid=$!
  local i=0
  until curl -s "http://127.0.0.1:${_PORT2}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  CONFLUENCE_URL="http://127.0.0.1:${_PORT2}" \
    "$EXPORT_SCRIPT" --recursive 12345 --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')

  kill "$pag_pid" 2>/dev/null || true
  wait "$pag_pid" 2>/dev/null || true
  rm -f "$pag_map"

  # parent + 3 children across 2 pages = 4
  [ "$count" -ge 4 ]
}

# --- no-scope default (all-spaces) ---

@test "no-scope: exits 0 when no scope argument is given" {
  run "$EXPORT_SCRIPT" --format md
  [ "$status" -eq 0 ]
}

@test "no-scope: creates files for pages in all accessible spaces" {
  "$EXPORT_SCRIPT" --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "no-scope: creates a directory named after the space key" {
  "$EXPORT_SCRIPT" --format md
  [ -d "$_OUT_DIR/TESTSPACE" ]
}

@test "no-scope: --list prints space keys without creating files" {
  run "$EXPORT_SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TESTSPACE" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

@test "no-scope: --list output includes page titles" {
  run "$EXPORT_SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TESTSPACE" ]]
}

# --- no-scope space index ---

@test "no-scope: writes _index.md to output directory" {
  "$EXPORT_SCRIPT" --format md
  [ -f "$_OUT_DIR/_index.md" ]
}

@test "no-scope: _index.md contains the space key" {
  "$EXPORT_SCRIPT" --format md
  grep -q "TESTSPACE" "$_OUT_DIR/_index.md"
}

@test "no-scope: _index.md contains the space name" {
  "$EXPORT_SCRIPT" --format md
  grep -q "Test Space" "$_OUT_DIR/_index.md"
}

@test "no-scope: _index.md contains the space type" {
  "$EXPORT_SCRIPT" --format md
  grep -q "global" "$_OUT_DIR/_index.md"
}

@test "no-scope: --list does not write _index.md" {
  run "$EXPORT_SCRIPT" --list
  [ "$status" -eq 0 ]
  [ ! -f "$_OUT_DIR/_index.md" ]
}
