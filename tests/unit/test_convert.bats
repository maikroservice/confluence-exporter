#!/usr/bin/env bats
# tests/unit/test_convert.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/convert.sh"
  deps_check
}

# --- convert_to_storage ---

@test "convert_to_storage: returns raw XML unchanged" {
  input="<h1>Title</h1><p>Body</p>"
  result=$(convert_to_storage "$input")
  [ "$result" = "$input" ]
}

# --- convert_to_html ---

@test "convert_to_html: returns HTML unchanged" {
  input="<h1>Title</h1><p>Body</p>"
  result=$(convert_to_html "$input")
  [ "$result" = "$input" ]
}

# --- convert_to_markdown: headings ---

@test "convert_to_markdown: h1 becomes # heading" {
  result=$(convert_to_markdown "<h1>Title</h1>")
  [[ "$result" =~ "# Title" ]]
}

@test "convert_to_markdown: h2 becomes ## heading" {
  result=$(convert_to_markdown "<h2>Subtitle</h2>")
  [[ "$result" =~ "## Subtitle" ]]
}

@test "convert_to_markdown: h3 becomes ### heading" {
  result=$(convert_to_markdown "<h3>Section</h3>")
  [[ "$result" =~ "### Section" ]]
}

@test "convert_to_markdown: h4 becomes #### heading" {
  result=$(convert_to_markdown "<h4>Sub</h4>")
  [[ "$result" =~ "#### Sub" ]]
}

# --- convert_to_markdown: inline formatting ---

@test "convert_to_markdown: strong becomes bold" {
  result=$(convert_to_markdown "<p><strong>bold text</strong></p>")
  [[ "$result" =~ "**bold text**" ]]
}

@test "convert_to_markdown: em becomes italic" {
  result=$(convert_to_markdown "<p><em>italic text</em></p>")
  [[ "$result" =~ "*italic text*" ]]
}

@test "convert_to_markdown: inline code becomes backtick-wrapped" {
  result=$(convert_to_markdown "<p><code>some_code()</code></p>")
  [[ "$result" =~ '`some_code()`' ]]
}

@test "convert_to_markdown: anchor tag becomes [text](url)" {
  result=$(convert_to_markdown '<p><a href="https://example.com">Click here</a></p>')
  [[ "$result" =~ "[Click here](https://example.com)" ]]
}

# --- convert_to_markdown: lists ---

@test "convert_to_markdown: ul li becomes dash list item" {
  result=$(convert_to_markdown "<ul><li>Item one</li><li>Item two</li></ul>")
  [[ "$result" =~ "- Item one" ]]
  [[ "$result" =~ "- Item two" ]]
}

@test "convert_to_markdown: ol li becomes numbered list item" {
  result=$(convert_to_markdown "<ol><li>First</li><li>Second</li></ol>")
  [[ "$result" =~ "1. First" ]]
}

# --- convert_to_markdown: code blocks ---

@test "convert_to_markdown: pre becomes fenced code block" {
  result=$(convert_to_markdown '<pre><code>echo "hello"</code></pre>')
  [[ "$result" =~ '```' ]]
  [[ "$result" =~ 'echo "hello"' ]]
}

# --- convert_to_markdown: paragraphs ---

@test "convert_to_markdown: p tags are stripped leaving plain text" {
  result=$(convert_to_markdown "<p>Plain paragraph text.</p>")
  [[ "$result" =~ "Plain paragraph text." ]]
  [[ "$result" != *"<p>"* ]]
}

# --- convert_to_markdown: tag stripping ---

@test "convert_to_markdown: unknown tags are stripped" {
  result=$(convert_to_markdown "<div><span>Just text</span></div>")
  [[ "$result" =~ "Just text" ]]
  [[ "$result" != *"<div>"* ]]
  [[ "$result" != *"<span>"* ]]
}

# --- pandoc path ---

@test "convert_to_markdown: uses pandoc when HAS_PANDOC=1" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not installed"
  HAS_PANDOC=1
  result=$(convert_to_markdown "<h1>Pandoc Test</h1>")
  [[ "$result" =~ "Pandoc Test" ]]
}

@test "convert_to_markdown: uses built-in converter when HAS_PANDOC=0" {
  HAS_PANDOC=0
  result=$(convert_to_markdown "<h1>Builtin Test</h1>")
  [[ "$result" =~ "# Builtin Test" ]]
}
