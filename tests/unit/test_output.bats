#!/usr/bin/env bats
# tests/unit/test_output.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/output.sh"
  _TMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$_TMP_DIR"
}

# --- output_slugify ---

@test "output_slugify: lowercases input" {
  result=$(output_slugify "UPPER CASE")
  [[ "$result" =~ ^[a-z-]+$ ]]
}

@test "output_slugify: converts spaces to hyphens" {
  result=$(output_slugify "hello world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: strips non-alphanumeric characters except hyphens" {
  result=$(output_slugify "hello! world@2024")
  [ "$result" = "hello-world-2024" ]
}

@test "output_slugify: collapses consecutive hyphens" {
  result=$(output_slugify "hello---world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: trims leading hyphens" {
  result=$(output_slugify "---hello")
  [ "$result" = "hello" ]
}

@test "output_slugify: trims trailing hyphens" {
  result=$(output_slugify "hello---")
  [ "$result" = "hello" ]
}

@test "output_slugify: handles unicode-free special chars" {
  result=$(output_slugify "My Page (Draft) v2.0")
  [ "$result" = "my-page-draft-v2-0" ]
}

# --- output_build_path ---

@test "output_build_path: single page builds flat path" {
  result=$(output_build_path "/tmp/export" "TESTSPACE" "" "my-page" "md")
  [ "$result" = "/tmp/export/TESTSPACE/my-page.md" ]
}

@test "output_build_path: nested page includes parent in path" {
  result=$(output_build_path "/tmp/export" "TESTSPACE" "parent-page" "child-page" "md")
  [ "$result" = "/tmp/export/TESTSPACE/parent-page/child-page.md" ]
}

@test "output_build_path: uses correct extension for html format" {
  result=$(output_build_path "/tmp/export" "TESTSPACE" "" "my-page" "html")
  [ "$result" = "/tmp/export/TESTSPACE/my-page.html" ]
}

@test "output_build_path: uses correct extension for raw format" {
  result=$(output_build_path "/tmp/export" "TESTSPACE" "" "my-page" "raw")
  [ "$result" = "/tmp/export/TESTSPACE/my-page.xml" ]
}

# --- output_write_file ---

@test "output_write_file: creates file at given path" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  [ -f "$_TMP_DIR/test.md" ]
}

@test "output_write_file: writes correct content" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "hello content" ]
}

@test "output_write_file: creates intermediate directories" {
  output_write_file "$_TMP_DIR/deep/nested/dir/test.md" "content"
  [ -f "$_TMP_DIR/deep/nested/dir/test.md" ]
}

@test "output_write_file: does not overwrite existing file by default" {
  printf 'original' > "$_TMP_DIR/test.md"
  output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "original" ]
}

@test "output_write_file: overwrites existing file with --force flag" {
  printf 'original' > "$_TMP_DIR/test.md"
  CONFLUENCE_FORCE=1 output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "new content" ]
}

# --- output_collision_path ---

@test "output_collision_path: appends page ID when slug conflicts" {
  # Create a file at the slug path to simulate collision
  mkdir -p "$_TMP_DIR/TESTSPACE"
  touch "$_TMP_DIR/TESTSPACE/my-page.md"

  result=$(output_collision_path "$_TMP_DIR/TESTSPACE/my-page.md" "99999")
  [ "$result" = "$_TMP_DIR/TESTSPACE/my-page--99999.md" ]
}

@test "output_collision_path: returns original path when no collision" {
  result=$(output_collision_path "$_TMP_DIR/TESTSPACE/new-page.md" "99999")
  [ "$result" = "$_TMP_DIR/TESTSPACE/new-page.md" ]
}
