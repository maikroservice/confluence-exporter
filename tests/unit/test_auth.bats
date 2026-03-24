#!/usr/bin/env bats
# tests/unit/test_auth.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  unset CONFLUENCE_URL CONFLUENCE_TYPE CONFLUENCE_AUTH_TYPE
  unset CONFLUENCE_EMAIL CONFLUENCE_TOKEN CONFLUENCE_USERNAME CONFLUENCE_PASSWORD
}

# --- Cloud basic auth ---

@test "auth_build_header: Cloud basic auth encodes email:token as Base64" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_EMAIL=user@example.com
  export CONFLUENCE_TOKEN=myapitoken

  result=$(auth_build_header)
  expected="Basic $(printf 'user@example.com:myapitoken' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Cloud basic auth header has no newlines" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_EMAIL=user@example.com
  export CONFLUENCE_TOKEN=myapitoken

  result=$(auth_build_header)
  [[ "$result" != *$'\n'* ]]
}

@test "auth_build_header: Cloud basic auth exits non-zero when EMAIL missing" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_TOKEN=myapitoken
  unset CONFLUENCE_EMAIL

  run auth_build_header
  [ "$status" -ne 0 ]
}

@test "auth_build_header: Cloud basic auth exits non-zero when TOKEN missing" {
  export CONFLUENCE_TYPE=cloud
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_EMAIL=user@example.com
  unset CONFLUENCE_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Server basic auth ---

@test "auth_build_header: Server basic auth encodes username:password" {
  export CONFLUENCE_TYPE=server
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_USERNAME=admin
  export CONFLUENCE_PASSWORD=secret

  result=$(auth_build_header)
  expected="Basic $(printf 'admin:secret' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Server basic auth uses TOKEN as password when set" {
  export CONFLUENCE_TYPE=server
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_USERNAME=admin
  export CONFLUENCE_TOKEN=pat_token
  unset CONFLUENCE_PASSWORD

  result=$(auth_build_header)
  expected="Basic $(printf 'admin:pat_token' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Server basic auth exits non-zero when USERNAME missing" {
  export CONFLUENCE_TYPE=server
  export CONFLUENCE_AUTH_TYPE=basic
  export CONFLUENCE_PASSWORD=secret
  unset CONFLUENCE_USERNAME

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Bearer auth ---

@test "auth_build_header: bearer auth returns Bearer <token>" {
  export CONFLUENCE_AUTH_TYPE=bearer
  export CONFLUENCE_TOKEN=my_pat_token

  result=$(auth_build_header)
  [ "$result" = "Bearer my_pat_token" ]
}

@test "auth_build_header: bearer auth exits non-zero when TOKEN missing" {
  export CONFLUENCE_AUTH_TYPE=bearer
  unset CONFLUENCE_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Unknown auth type ---

@test "auth_build_header: exits non-zero for unknown auth type" {
  export CONFLUENCE_AUTH_TYPE=oauth2
  export CONFLUENCE_TOKEN=something

  run auth_build_header
  [ "$status" -ne 0 ]
}
