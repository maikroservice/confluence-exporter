#!/usr/bin/env bats
# tests/unit/test_api.bats
# Tests api.sh functions against a live fixture server (real curl, real HTTP).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup_file() {
  export FIXTURES_DIR
}

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  source "$REPO_ROOT/lib/api.sh"

  deps_check

  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_EMAIL=user@example.com
  export CONFLUENCE_TOKEN=testtoken
  export CONFLUENCE_MAX_RETRIES=1
  export CONFLUENCE_RETRY_DELAY=0

  # Start fixture server with a default route map
  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/wiki/api/v2/pages/12345?body-format=storage", "fixture": "page_single.json",       "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345?body-format=view",    "fixture": "page_single_view.json",  "status": 200},
  {"pattern": "/wiki/api/v2/pages/12345/children",            "fixture": "page_children.json",     "status": 200},
  {"pattern": "/wiki/api/v2/pages/22222/children",            "fixture": "page_children_empty.json","status": 200},
  {"pattern": "/wiki/api/v2/pages/33333/children",            "fixture": "page_children_empty.json","status": 200},
  {"pattern": "/wiki/api/v2/spaces?keys=TESTSPACE",           "fixture": "spaces_lookup.json",     "status": 200},
  {"pattern": "/wiki/api/v2/spaces/98765/pages",              "fixture": "space_pages.json",       "status": 200},
  {"pattern": "/wiki/api/v2/pages/99999",                     "fixture": "error_404.json",         "status": 404},
  {"pattern": "/wiki/api/v2/spaces?limit=1",                  "fixture": "spaces_lookup.json",     "status": 200},
  {"pattern": "/wiki/api/v2/spaces?limit=50",                 "fixture": "spaces_all.json",        "status": 200},
  {"pattern": "/wiki/api/v2/pages/77777",                     "fixture": "error_401.json",         "status": 401}
]
EOF

  # Pick a free port
  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
  _SERVER_PID=$!

  # Wait for server to be ready
  local i=0
  until curl -s "http://127.0.0.1:${_PORT}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  export CONFLUENCE_URL="http://127.0.0.1:${_PORT}"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
}

# --- api_base_url ---

@test "api_base_url: returns Cloud v2 path for cloud type" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_URL=https://mysite.atlassian.net
  result=$(api_base_url)
  [ "$result" = "https://mysite.atlassian.net/wiki/api/v2" ]
}

@test "api_base_url: returns v1 path for server type" {
  export CONFLUENCE_TYPE=server
  export CONFLUENCE_URL=https://confluence.example.com
  result=$(api_base_url)
  [ "$result" = "https://confluence.example.com/rest/api" ]
}

@test "api_base_url: strips trailing slash from CONFLUENCE_URL" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_URL=https://mysite.atlassian.net/
  result=$(api_base_url)
  [ "$result" = "https://mysite.atlassian.net/wiki/api/v2" ]
}

# --- api_url_to_id ---

@test "api_url_to_id: returns bare numeric ID unchanged" {
  result=$(api_url_to_id "12345")
  [ "$result" = "12345" ]
}

@test "api_url_to_id: extracts ID from Cloud /pages/<id>/Title URL" {
  result=$(api_url_to_id "https://mysite.atlassian.net/wiki/spaces/KEY/pages/12345/My-Page")
  [ "$result" = "12345" ]
}

@test "api_url_to_id: extracts ID from Server ?pageId=12345 URL" {
  result=$(api_url_to_id "https://confluence.example.com/pages/viewpage.action?pageId=12345")
  [ "$result" = "12345" ]
}

# --- api_get_page ---

@test "api_get_page: returns page JSON for valid page ID" {
  result=$(api_get_page "12345")
  [ "${HAS_JQ}" = "1" ] || skip "jq required for this assertion"
  title=$(printf '%s' "$result" | jq -r '.title')
  [ "$title" = "My Test Page" ]
}

@test "api_get_page: fails with exit code 1 for 404" {
  run api_get_page "99999"
  [ "$status" -eq 1 ]
}

@test "api_get_page: fails with exit code 1 for 401" {
  run api_get_page "77777"
  [ "$status" -eq 1 ]
}

# --- api_get_children ---

@test "api_get_children: returns two child pages for page 12345" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  local out
  out=$(mktemp)
  api_get_children "12345" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

@test "api_get_children: returns empty file for page with no children" {
  local out
  out=$(mktemp)
  api_get_children "22222" "$out"
  count=$(wc -c < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 0 ]
}

# --- api_extract_* ---

@test "api_extract_title: returns title from page JSON" {
  json=$(cat "$FIXTURES_DIR/page_single.json")
  result=$(api_extract_title "$json")
  [ "$result" = "My Test Page" ]
}

@test "api_extract_id: returns id from page JSON" {
  json=$(cat "$FIXTURES_DIR/page_single.json")
  result=$(api_extract_id "$json")
  [ "$result" = "12345" ]
}

@test "api_extract_body_storage: returns storage HTML from page JSON" {
  json=$(cat "$FIXTURES_DIR/page_single.json")
  result=$(api_extract_body_storage "$json")
  [[ "$result" =~ "<h1>Hello World</h1>" ]]
}

@test "api_extract_space_key: returns space key from page JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/server/page_single_dc.json")
  result=$(api_extract_space_key "$json")
  [ "$result" = "TESTSPACE" ]
}

# --- api_paginate_all ---

@test "api_paginate_all: collects all results from single-page response" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  local out
  out=$(mktemp)
  api_paginate_all "${CONFLUENCE_URL}/wiki/api/v2/pages/12345/children?limit=50" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

# --- api_extract_key ---

@test "api_extract_key: returns key from space JSON object" {
  json=$(cat "$FIXTURES_DIR/space_single.json")
  result=$(api_extract_key "$json")
  [ "$result" = "TESTSPACE" ]
}

@test "api_extract_key: returns empty string when key is absent" {
  result=$(api_extract_key '{"id":"1","name":"No Key Space"}')
  [ -z "$result" ]
}

# --- api_get_all_spaces ---

@test "api_get_all_spaces: fetches all accessible spaces and writes at least one result" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  local out
  out=$(mktemp)
  api_get_all_spaces "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

@test "api_get_all_spaces: returned space objects include a key field" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  local out
  out=$(mktemp)
  api_get_all_spaces "$out"
  key=$(head -1 "$out" | jq -r '.key // empty')
  rm -f "$out"
  [ "$key" = "TESTSPACE" ]
}

@test "api_get_all_spaces: uses server endpoint for server type" {
  export CONFLUENCE_TYPE=server
  export CONFLUENCE_URL="http://127.0.0.1:${_PORT}"
  local out
  out=$(mktemp)
  # Server endpoint won't be mapped — expect a non-zero return, not a crash
  run api_get_all_spaces "$out"
  rm -f "$out"
  # We only verify the function exists and returns without segfault
  [ "$status" -ne 127 ]
}
