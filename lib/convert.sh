#!/usr/bin/env bash
# lib/convert.sh - HTML to output format conversion

convert_to_storage() {
  printf '%s' "$1"
}

convert_to_html() {
  printf '%s' "$1"
}

convert_to_markdown() {
  local html="$1"
  if [ "${HAS_PANDOC:-0}" = "1" ]; then
    printf '%s' "$html" | pandoc -f html -t gfm --wrap=none 2>/dev/null
  else
    log_debug "pandoc unavailable — using built-in HTML→Markdown converter (degraded)"
    printf '%s' "$html" | _convert_builtin
  fi
}

# Built-in sed/awk HTML→Markdown converter
# Handles: h1-h6, p, strong/b, em/i, code, pre, a, ul/ol/li, br
# All other tags are stripped.
_convert_builtin() {
  # Normalize: ensure each tag starts on its own line so patterns match reliably
  # on both single-line (compact) and multi-line HTML
  sed 's/></>\n</g' | sed \
    -e 's|<h1[^>]*>\(.*\)</h1>|# \1|g' \
    -e 's|<h2[^>]*>\(.*\)</h2>|## \1|g' \
    -e 's|<h3[^>]*>\(.*\)</h3>|### \1|g' \
    -e 's|<h4[^>]*>\(.*\)</h4>|#### \1|g' \
    -e 's|<h5[^>]*>\(.*\)</h5>|##### \1|g' \
    -e 's|<h6[^>]*>\(.*\)</h6>|###### \1|g' \
    -e 's|<strong[^>]*>\(.*\)</strong>|**\1**|g' \
    -e 's|<b[^>]*>\(.*\)</b>|**\1**|g' \
    -e 's|<em[^>]*>\(.*\)</em>|*\1*|g' \
    -e 's|<i[^>]*>\(.*\)</i>|*\1*|g' \
    -e 's|<code[^>]*>\(.*\)</code>|`\1`|g' \
    -e 's|<a[^>]*href="\([^"]*\)"[^>]*>\(.*\)</a>|[\2](\1)|g' \
    -e "s|<a[^>]*href='\([^']*\)'[^>]*>\(.*\)</a>|[\2](\1)|g" \
    -e 's|<br[[:space:]]*/?>||g' \
    -e 's|<p[^>]*>||g' \
    -e 's|</p>||g' \
  | _convert_list_items \
  | _convert_pre_blocks \
  | _strip_remaining_tags \
  | _collapse_blank_lines
}

# Convert <ul>/<ol>/<li> to Markdown list items, tracking ordered vs unordered context
_convert_list_items() {
  awk '
    BEGIN { in_ol=0; counter=0 }
    /<ol[^>]*>/ { in_ol=1; counter=0; next }
    /<\/ol>/    { in_ol=0; print ""; next }
    /<ul[^>]*>/ { in_ol=0; next }
    /<\/ul>/    { print ""; next }
    /<li[^>]*>/ {
      sub(/<li[^>]*>/, "")
      sub(/<\/li>/, "")
      # strip leading/trailing whitespace
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (in_ol) {
        counter++
        print counter ". " $0
      } else {
        print "- " $0
      }
      next
    }
    /<\/li>/ { next }
    { print }
  '
}

# Convert <pre>...</pre> blocks to fenced code blocks
# Must handle multi-line content so we use awk
_convert_pre_blocks() {
  awk '
    /<pre[^>]*>/ {
      in_pre=1
      # strip opening pre/code tags from this line
      line=$0
      sub(/<pre[^>]*>/, "", line)
      sub(/<code[^>]*>/, "", line)
      print "```"
      if (line !~ /^[[:space:]]*$/) print line
      next
    }
    /<\/pre>/ {
      in_pre=0
      line=$0
      sub(/<\/code>/, "", line)
      sub(/<\/pre>/, "", line)
      if (line !~ /^[[:space:]]*$/) print line
      print "```"
      next
    }
    in_pre {
      # strip inner code tags if present
      sub(/<code[^>]*>/, "")
      sub(/<\/code>/, "")
      print
      next
    }
    { print }
  '
}

# Strip any remaining HTML tags
_strip_remaining_tags() {
  sed 's/<[^>]*>//g'
}

# Collapse 3+ consecutive blank lines into 2
_collapse_blank_lines() {
  awk '
    /^[[:space:]]*$/ { blank++; if (blank <= 2) print; next }
    { blank=0; print }
  '
}
