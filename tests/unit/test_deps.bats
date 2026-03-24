#!/usr/bin/env bats
# tests/unit/test_deps.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  unset HAS_CURL HAS_JQ HAS_PANDOC
}

# --- curl ---

@test "deps_check: sets HAS_CURL=1 when curl is on PATH" {
  deps_check
  [ "$HAS_CURL" = "1" ]
}

@test "deps_check: exits 1 when curl is missing" {
  local fake_bin old_path="$PATH"
  fake_bin=$(mktemp -d)
  export PATH="$fake_bin"
  run deps_check
  export PATH="$old_path"
  rm -rf "$fake_bin"
  [ "$status" -eq 1 ]
}

# --- jq ---

@test "deps_check: sets HAS_JQ=1 when jq is on PATH" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  deps_check
  [ "$HAS_JQ" = "1" ]
}

@test "deps_check: sets HAS_JQ=0 and does not exit when jq is missing" {
  local fake_bin old_path="$PATH"
  fake_bin=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$fake_bin/curl"
  chmod +x "$fake_bin/curl"
  export PATH="$fake_bin"
  run deps_check
  export PATH="$old_path"
  rm -rf "$fake_bin"
  [ "$status" -eq 0 ]
  [ "$HAS_JQ" != "1" ]
}

@test "deps_check: warns when jq is missing" {
  local fake_bin old_path="$PATH"
  fake_bin=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$fake_bin/curl"
  chmod +x "$fake_bin/curl"
  export PATH="$fake_bin"
  run deps_check
  export PATH="$old_path"
  rm -rf "$fake_bin"
  [[ "$output" =~ "jq" ]]
}

# --- pandoc ---

@test "deps_check: sets HAS_PANDOC=1 when pandoc is on PATH" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not installed"
  deps_check
  [ "$HAS_PANDOC" = "1" ]
}

@test "deps_check: sets HAS_PANDOC=0 and does not exit when pandoc is missing" {
  local fake_bin old_path="$PATH"
  fake_bin=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$fake_bin/curl"
  chmod +x "$fake_bin/curl"
  export PATH="$fake_bin"
  run deps_check
  export PATH="$old_path"
  rm -rf "$fake_bin"
  [ "$status" -eq 0 ]
  [ "$HAS_PANDOC" != "1" ]
}

@test "HAS_* flags are exported to subshells" {
  deps_check
  local val
  val=$(bash -c 'printf "%s" "$HAS_CURL"')
  [ "$val" = "1" ]
}

# --- json_get ---

@test "json_get: extracts string field with jq" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  HAS_JQ=1
  result=$(json_get "title" '{"title":"Hello World"}')
  [ "$result" = "Hello World" ]
}

@test "json_get: extracts string field with sed fallback" {
  HAS_JQ=0
  result=$(json_get "title" '{"title":"Hello World"}')
  [ "$result" = "Hello World" ]
}

@test "json_is_empty: true for empty string" {
  json_is_empty ""
}

@test "json_is_empty: true for null" {
  json_is_empty "null"
}

@test "json_is_empty: false for a real value" {
  run json_is_empty "something"
  [ "$status" -ne 0 ]
}
