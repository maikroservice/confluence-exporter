#!/usr/bin/env bash
# lib/output.sh - File writing, path building, and slug generation

# Convert a page title to a filesystem-safe slug
# Usage: output_slugify <title>
output_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//'
}

# Build the full output path for a page
# Usage: output_build_path <output_dir> <space_key> <parent_slug> <page_slug> <format>
# parent_slug may be empty for top-level pages
output_build_path() {
  local out_dir="$1"
  local space_key="$2"
  local parent_slug="$3"
  local page_slug="$4"
  local format="$5"

  local ext
  case "$format" in
    md)   ext="md"  ;;
    html) ext="html" ;;
    raw)  ext="xml"  ;;
    *)    ext="md"   ;;
  esac

  if [ -n "$parent_slug" ]; then
    printf '%s/%s/%s/%s.%s' "$out_dir" "$space_key" "$parent_slug" "$page_slug" "$ext"
  else
    printf '%s/%s/%s.%s' "$out_dir" "$space_key" "$page_slug" "$ext"
  fi
}

# Return a collision-free path: if the path exists, append --<page_id> before extension
# Usage: output_collision_path <path> <page_id>
output_collision_path() {
  local path="$1"
  local page_id="$2"

  if [ ! -e "$path" ]; then
    printf '%s' "$path"
    return 0
  fi

  local dir base ext
  dir=$(dirname "$path")
  base=$(basename "$path")
  ext="${base##*.}"
  base="${base%.*}"

  printf '%s/%s--%s.%s' "$dir" "$base" "$page_id" "$ext"
}

# Write content to a file, creating intermediate directories as needed
# Respects CONFLUENCE_FORCE=1 to allow overwriting
# Usage: output_write_file <path> <content>
output_write_file() {
  local path="$1"
  local content="$2"

  if [ -e "$path" ] && [ "${CONFLUENCE_FORCE:-0}" != "1" ]; then
    log_warn "Skipping existing file (use --force to overwrite): $path"
    return 0
  fi

  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || { log_error "Could not create directory: $dir"; return 1; }

  # Atomic write via temp file
  local tmp
  tmp=$(mktemp "${dir}/.tmp_XXXXXX")
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path" || {
    rm -f "$tmp"
    log_error "Could not write file: $path"
    return 1
  }

  log_debug "Wrote: $path"
}
