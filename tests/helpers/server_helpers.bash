#!/usr/bin/env bash
# tests/helpers/server_helpers.bash
# Shared bats helper: start/stop the fixture server and write route maps.

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${HELPERS_DIR}/../fixtures"
FIXTURE_SERVER_SCRIPT="${HELPERS_DIR}/fixture_server.py"

# Start the fixture server with a given route map file.
# Usage: start_fixture_server <map_file> [port]
# Sets FIXTURE_SERVER_PID and FIXTURE_SERVER_PORT.
start_fixture_server() {
  local map_file="$1"
  local port="${2:-0}"

  # Pick a random high port if not specified
  if [ "$port" -eq 0 ]; then
    port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  fi

  export FIXTURE_SERVER_PORT="$port"
  export FIXTURES_DIR

  # Start server; first line of stdout is the PID
  FIXTURE_SERVER_PID=$(python3 "$FIXTURE_SERVER_SCRIPT" "$port" "$map_file" &
    # The server prints its PID to stdout before entering serve_forever
    # We capture it via process substitution trick below
  )

  # Simpler: run in background and grab PID directly
  python3 "$FIXTURE_SERVER_SCRIPT" "$port" "$map_file" >/tmp/fixture_server_pid_$$ 2>/tmp/fixture_server_log_$$ &
  local bg_pid=$!

  # Wait briefly for server to be ready
  local attempts=0
  while [ $attempts -lt 20 ]; do
    if curl -s "http://127.0.0.1:${port}/" >/dev/null 2>&1 || \
       curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" 2>/dev/null | grep -q '[0-9]'; then
      break
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done

  export FIXTURE_SERVER_PID="$bg_pid"
  export CONFLUENCE_URL="http://127.0.0.1:${port}"

  if [ $attempts -ge 20 ]; then
    echo "fixture_server failed to start" >&2
    cat /tmp/fixture_server_log_$$ >&2
    return 1
  fi
}

# Stop the fixture server
stop_fixture_server() {
  if [ -n "${FIXTURE_SERVER_PID:-}" ]; then
    kill "$FIXTURE_SERVER_PID" 2>/dev/null || true
    wait "$FIXTURE_SERVER_PID" 2>/dev/null || true
    unset FIXTURE_SERVER_PID
  fi
  rm -f /tmp/fixture_server_pid_$$ /tmp/fixture_server_log_$$
}

# Write a route map JSON file and return the path
# Usage: write_route_map <output_file> <json_array_string>
write_route_map() {
  local out="$1"
  local json="$2"
  printf '%s' "$json" > "$out"
}
