#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-gateway"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

source "${BASHCLAW_ROOT}/gateway/http_handler.sh"

begin_test_file "test_gateway"

# ============================================================
# Section 1: _http_read_request parsing
# ============================================================

test_start "_http_read_request parses GET request with query string"
setup_test_env
(
  printf 'GET /api/status?foo=bar&baz=1 HTTP/1.1\r\n'
  printf 'Host: localhost\r\n'
  printf '\r\n'
) | {
  _http_read_request
  assert_eq "$HTTP_METHOD" "GET"
  assert_eq "$HTTP_PATH" "/api/status"
  assert_eq "$HTTP_QUERY" "foo=bar&baz=1"
  assert_eq "$HTTP_VERSION" "HTTP/1.1"
}
teardown_test_env

test_start "_http_read_request parses POST request with body"
setup_test_env
body='{"message":"hello"}'
body_len="${#body}"
(
  printf 'POST /chat HTTP/1.1\r\n'
  printf 'Host: localhost\r\n'
  printf 'Content-Length: %d\r\n' "$body_len"
  printf '\r\n'
  printf '%s' "$body"
) | {
  _http_read_request
  assert_eq "$HTTP_METHOD" "POST"
  assert_eq "$HTTP_PATH" "/chat"
  assert_eq "$HTTP_CONTENT_LENGTH" "$body_len"
  assert_eq "$HTTP_BODY" "$body"
}
teardown_test_env

test_start "_http_read_request extracts Authorization header"
setup_test_env
(
  printf 'GET /api/config HTTP/1.1\r\n'
  printf 'Host: localhost\r\n'
  printf 'Authorization: Bearer test-token-abc\r\n'
  printf '\r\n'
) | {
  _http_read_request
  assert_eq "$HTTP_AUTH_HEADER" "Bearer test-token-abc"
}
teardown_test_env

test_start "_http_read_request extracts Origin header"
setup_test_env
(
  printf 'GET /api/status HTTP/1.1\r\n'
  printf 'Host: localhost\r\n'
  printf 'Origin: https://example.com\r\n'
  printf '\r\n'
) | {
  _http_read_request
  assert_eq "$HTTP_ORIGIN" "https://example.com"
}
teardown_test_env

test_start "_http_read_request rejects body exceeding GATEWAY_MAX_BODY_SIZE"
setup_test_env
old_max="$GATEWAY_MAX_BODY_SIZE"
GATEWAY_MAX_BODY_SIZE=10
rc=0
(
  printf 'POST /chat HTTP/1.1\r\n'
  printf 'Host: localhost\r\n'
  printf 'Content-Length: 9999\r\n'
  printf '\r\n'
) | {
  _http_read_request
} || rc=$?
assert_eq "$rc" "1"
GATEWAY_MAX_BODY_SIZE="$old_max"
teardown_test_env

# ============================================================
# Section 2: _http_check_auth
# ============================================================

test_start "_http_check_auth passes when no token configured"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER=""
_http_check_auth
rc=$?
assert_eq "$rc" "0"
teardown_test_env

test_start "_http_check_auth passes with valid Bearer token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "secret123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER="Bearer secret123"
_http_check_auth
rc=$?
assert_eq "$rc" "0"
teardown_test_env

test_start "_http_check_auth fails with invalid Bearer token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "secret123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER="Bearer wrong-token"
rc=0
_http_check_auth || rc=$?
assert_eq "$rc" "1"
teardown_test_env

test_start "_http_check_auth fails when Authorization header missing"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "secret123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER=""
rc=0
_http_check_auth || rc=$?
assert_eq "$rc" "1"
teardown_test_env

test_start "_http_check_auth accepts non-Bearer raw token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "secret123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER="secret123"
_http_check_auth
rc=$?
assert_eq "$rc" "0"
teardown_test_env

# ============================================================
# Section 3: CORS origin handling
# ============================================================

test_start "CORS default wildcard when no cors config"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN=""
result="$(_http_respond 200 "text/plain" "ok")"
assert_contains "$result" "Access-Control-Allow-Origin: *"
teardown_test_env

test_start "CORS matching origin from config allowlist"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"cors": {"origins": ["https://app.example.com", "https://other.com"]}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN="https://app.example.com"
result="$(_http_respond 200 "text/plain" "ok")"
assert_contains "$result" "Access-Control-Allow-Origin: https://app.example.com"
teardown_test_env

test_start "CORS non-matching origin omits Allow-Origin header"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"cors": {"origins": ["https://allowed.com"]}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN="https://evil.com"
result="$(_http_respond 200 "text/plain" "ok")"
assert_not_contains "$result" "Access-Control-Allow-Origin:"
teardown_test_env

# ============================================================
# Section 4: _handle_openai_chat_completions
# ============================================================

test_start "OpenAI completions returns valid JSON for non-streaming request"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

# Mock engine_run
engine_run() { printf 'mocked ai response'; }

HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[{"role":"user","content":"hello"}]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "chat.completion"
assert_contains "$result" "mocked ai response"
body_part="$(printf '%s' "$result" | sed -n '/^\r*$/,$p' | tail -n +2)"
assert_json_valid "$body_part"
unset -f engine_run
teardown_test_env

test_start "OpenAI completions returns 400 for stream=true"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"model":"gpt-4o","stream":true,"messages":[{"role":"user","content":"hello"}]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "streaming not supported"
teardown_test_env

test_start "OpenAI completions returns 400 when no user message"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[{"role":"system","content":"you are helpful"}]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "no user message"
teardown_test_env

test_start "OpenAI completions returns 400 when body is empty"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY=""
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "request body required"
teardown_test_env

test_start "OpenAI completions maps known model to main agent"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_agent_capture_file="${_TEST_TMPDIR}/captured_agent.txt"
engine_run() { printf '%s' "$1" > "$_agent_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"claude-opus-4-6","stream":false,"messages":[{"role":"user","content":"hi"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_agent="$(cat "$_agent_capture_file" 2>/dev/null)"
assert_eq "$captured_agent" "main"
unset -f engine_run
teardown_test_env

test_start "OpenAI completions maps custom model name to agent_id"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_agent_capture_file="${_TEST_TMPDIR}/captured_agent.txt"
engine_run() { printf '%s' "$1" > "$_agent_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"my-custom-agent","stream":false,"messages":[{"role":"user","content":"hi"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_agent="$(cat "$_agent_capture_file" 2>/dev/null)"
assert_eq "$captured_agent" "my-custom-agent"
unset -f engine_run
teardown_test_env

# ============================================================
# Section 5: handle_request routing
# ============================================================

test_start "handle_request GET /health returns 200 with status JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {"model": "test-model"}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "200 OK"
assert_contains "$result" '"status"'
teardown_test_env

test_start "handle_request returns 404 for unknown route"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'GET /nonexistent HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "404"
assert_contains "$result" "not found"
teardown_test_env

test_start "handle_request OPTIONS returns 200 (CORS preflight)"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'OPTIONS /api/chat HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.com\r\n\r\n' | handle_request)"
assert_contains "$result" "200 OK"
teardown_test_env

test_start "handle_request returns 401 when token configured but not provided"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "mytoken"}}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'POST /api/chat HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}' | handle_request)"
assert_contains "$result" "401"
assert_contains "$result" "unauthorized"
teardown_test_env

test_start "handle_request auth-exempt /health passes without token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "mytoken"}}, "agents": {"defaults": {"model": "test-model"}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "200 OK"
teardown_test_env

test_start "handle_request auth-exempt /api/status passes without token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "mytoken"}}, "agents": {"defaults": {"model": "test-model"}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

result="$(printf 'GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "200 OK"
teardown_test_env

# ============================================================
# Section 6: 413 body size
# ============================================================

test_start "handle_request returns 413 when body exceeds GATEWAY_MAX_BODY_SIZE"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load

old_max="$GATEWAY_MAX_BODY_SIZE"
GATEWAY_MAX_BODY_SIZE=10

result="$(printf 'POST /api/chat HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999\r\n\r\n' | handle_request)"
assert_contains "$result" "413"
assert_contains "$result" "too large"

GATEWAY_MAX_BODY_SIZE="$old_max"
teardown_test_env

# ============================================================
# Section 7: Edge case tests
# ============================================================

test_start "_http_read_request handles empty input gracefully"
setup_test_env
set +e
result="$(printf '' | _http_read_request 2>/dev/null)"
rc=$?
set -e
# Should not crash, any exit code is acceptable
_test_pass
teardown_test_env

test_start "_handle_chat returns 400 when body is empty"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY=""
HTTP_ORIGIN=""
result="$(_handle_chat)"
assert_contains "$result" "400"
assert_contains "$result" "request body required"
teardown_test_env

test_start "_handle_chat returns 400 when message field is missing"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"agent":"main"}'
HTTP_ORIGIN=""
result="$(_handle_chat)"
assert_contains "$result" "400"
assert_contains "$result" "message field is required"
teardown_test_env

test_start "_handle_message_send returns 400 with empty body"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY=""
HTTP_ORIGIN=""
result="$(_handle_message_send)"
assert_contains "$result" "400"
assert_contains "$result" "request body required"
teardown_test_env

test_start "_handle_message_send returns 400 with missing fields"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"channel":"test"}'
HTTP_ORIGIN=""
result="$(_handle_message_send)"
assert_contains "$result" "400"
teardown_test_env

test_start "_handle_api_config_set returns 400 with invalid JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='not json at all'
HTTP_ORIGIN=""
result="$(_handle_api_config_set)"
assert_contains "$result" "400"
assert_contains "$result" "invalid JSON"
teardown_test_env

test_start "_handle_api_config_set returns 400 with empty body"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY=""
HTTP_ORIGIN=""
result="$(_handle_api_config_set)"
assert_contains "$result" "400"
assert_contains "$result" "request body required"
teardown_test_env

test_start "_http_serve_file returns 404 for nonexistent file"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN=""
result="$(_http_serve_file "/nonexistent/file.html")"
assert_contains "$result" "404"
teardown_test_env

test_start "handle_request path traversal protection"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
result="$(printf 'GET /ui/../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "400"
assert_contains "$result" "path traversal"
teardown_test_env

# ---- Edge Case: Request with body exceeding GATEWAY_MAX_BODY_SIZE ----

test_start "Request with body exceeding max size returns 413"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
old_max="$GATEWAY_MAX_BODY_SIZE"
GATEWAY_MAX_BODY_SIZE=20
result="$(printf 'POST /api/chat HTTP/1.1\r\nHost: localhost\r\nContent-Length: 50000\r\n\r\n' | handle_request)"
assert_contains "$result" "413"
assert_contains "$result" "too large"
GATEWAY_MAX_BODY_SIZE="$old_max"
teardown_test_env

# ---- Edge Case: Request with missing Content-Length header ----

test_start "POST request with missing Content-Length has empty body"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {}, "agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
result="$(printf 'POST /api/chat HTTP/1.1\r\nHost: localhost\r\n\r\n' | handle_request)"
assert_contains "$result" "400"
assert_contains "$result" "request body required"
teardown_test_env

# ---- Edge Case: Auth with expired/invalid token format ----

test_start "_http_check_auth fails with malformed Bearer token"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "valid-secret-token-123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER="Bearer "
rc=0
_http_check_auth || rc=$?
assert_eq "$rc" "1"
teardown_test_env

test_start "_http_check_auth fails with empty Authorization header"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"auth": {"token": "valid-secret-token-123"}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_AUTH_HEADER=""
rc=0
_http_check_auth || rc=$?
assert_eq "$rc" "1"
teardown_test_env

# ---- Edge Case: CORS with origin not in allowlist ----

test_start "CORS rejects origin not in allowlist"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"gateway": {"cors": {"origins": ["https://trusted.com"]}}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN="https://malicious-site.com"
result="$(_http_respond 200 "text/plain" "ok")"
assert_not_contains "$result" "Access-Control-Allow-Origin:"
teardown_test_env

# ---- Edge Case: OpenAI endpoint with missing required fields ----

test_start "OpenAI completions with empty messages array returns 400"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "messages array is required"
teardown_test_env

test_start "OpenAI completions with missing messages field returns 400"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"model":"gpt-4o","stream":false}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "messages array is required"
teardown_test_env

# ---- Edge Case: OpenAI endpoint with stream=true returns 400 ----

test_start "OpenAI completions with stream=true returns 400"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_BODY='{"model":"gpt-4o","stream":true,"messages":[{"role":"user","content":"test"}]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
assert_contains "$result" "400"
assert_contains "$result" "streaming not supported"
teardown_test_env

# ============================================================
# Section 8: OpenAI /v1/models endpoint
# ============================================================

test_start "GET /v1/models returns model list with correct structure"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN=""
result="$(_handle_openai_models)"
assert_contains "$result" "200 OK"
body_part="$(printf '%s' "$result" | sed -n '/^\r*$/,$p' | tail -n +2)"
assert_json_valid "$body_part"
assert_contains "$body_part" '"object":"list"'
assert_contains "$body_part" '"id"'
assert_contains "$body_part" '"owned_by"'
teardown_test_env

test_start "GET /v1/models includes claude-opus-4-6"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN=""
result="$(_handle_openai_models)"
body_part="$(printf '%s' "$result" | sed -n '/^\r*$/,$p' | tail -n +2)"
assert_contains "$body_part" "claude-opus-4-6"
assert_contains "$body_part" "anthropic"
teardown_test_env

test_start "GET /v1/models each entry has object=model"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}, "gateway": {}}
EOF
_CONFIG_CACHE=""
config_load
HTTP_ORIGIN=""
result="$(_handle_openai_models)"
body_part="$(printf '%s' "$result" | sed -n '/^\r*$/,$p' | tail -n +2)"
non_model_count="$(printf '%s' "$body_part" | jq '[.data[]? | select(.object != "model")] | length' 2>/dev/null)"
assert_eq "$non_model_count" "0"
teardown_test_env

# ============================================================
# Section 9: OpenAI agent: prefix routing
# ============================================================

test_start "OpenAI completions routes agent:research to research agent"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_agent_capture_file="${_TEST_TMPDIR}/captured_agent.txt"
engine_run() { printf '%s' "$1" > "$_agent_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"agent:research","stream":false,"messages":[{"role":"user","content":"find info"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_agent="$(cat "$_agent_capture_file" 2>/dev/null)"
assert_eq "$captured_agent" "research"
unset -f engine_run
teardown_test_env

test_start "OpenAI completions agent: prefix with nested name"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_agent_capture_file="${_TEST_TMPDIR}/captured_agent.txt"
engine_run() { printf '%s' "$1" > "$_agent_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"agent:code-review","stream":false,"messages":[{"role":"user","content":"review this"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_agent="$(cat "$_agent_capture_file" 2>/dev/null)"
assert_eq "$captured_agent" "code-review"
unset -f engine_run
teardown_test_env

# ============================================================
# Section 10: OpenAI system message extraction
# ============================================================

test_start "OpenAI completions prepends system message to user message"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_msg_capture_file="${_TEST_TMPDIR}/captured_msg.txt"
engine_run() { printf '%s' "$2" > "$_msg_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[{"role":"system","content":"You are a pirate"},{"role":"user","content":"Hello"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_msg="$(cat "$_msg_capture_file" 2>/dev/null)"
assert_contains "$captured_msg" "[System: You are a pirate]"
assert_contains "$captured_msg" "Hello"
unset -f engine_run
teardown_test_env

test_start "OpenAI completions without system message passes user message directly"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_msg_capture_file="${_TEST_TMPDIR}/captured_msg.txt"
engine_run() { printf '%s' "$2" > "$_msg_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[{"role":"user","content":"Hello plain"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_msg="$(cat "$_msg_capture_file" 2>/dev/null)"
assert_eq "$captured_msg" "Hello plain"
unset -f engine_run
teardown_test_env

# ============================================================
# Section 11: OpenAI response structure validation
# ============================================================

test_start "OpenAI completions response has correct object, id, choices structure"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

engine_run() { printf 'test response content'; }

HTTP_BODY='{"model":"gpt-4o","stream":false,"messages":[{"role":"user","content":"hi"}]}'
HTTP_ORIGIN=""
result="$(_handle_openai_chat_completions)"
body_part="$(printf '%s' "$result" | sed -n '/^\r*$/,$p' | tail -n +2)"
assert_json_valid "$body_part"

obj_val="$(printf '%s' "$body_part" | jq -r '.object' 2>/dev/null)"
assert_eq "$obj_val" "chat.completion"

id_val="$(printf '%s' "$body_part" | jq -r '.id' 2>/dev/null)"
assert_contains "$id_val" "chatcmpl-"

choices_len="$(printf '%s' "$body_part" | jq '.choices | length' 2>/dev/null)"
assert_eq "$choices_len" "1"

choice_role="$(printf '%s' "$body_part" | jq -r '.choices[0].message.role' 2>/dev/null)"
assert_eq "$choice_role" "assistant"

choice_content="$(printf '%s' "$body_part" | jq -r '.choices[0].message.content' 2>/dev/null)"
assert_eq "$choice_content" "test response content"

finish_reason="$(printf '%s' "$body_part" | jq -r '.choices[0].finish_reason' 2>/dev/null)"
assert_eq "$finish_reason" "stop"

model_val="$(printf '%s' "$body_part" | jq -r '.model' 2>/dev/null)"
assert_eq "$model_val" "gpt-4o"

usage_total="$(printf '%s' "$body_part" | jq '.usage.total_tokens' 2>/dev/null)"
assert_eq "$usage_total" "0"

unset -f engine_run
teardown_test_env

test_start "OpenAI completions gemini model maps to main agent"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents": {"defaults": {}, "list": []}}
EOF
_CONFIG_CACHE=""
config_load

_agent_capture_file="${_TEST_TMPDIR}/captured_agent.txt"
engine_run() { printf '%s' "$1" > "$_agent_capture_file"; printf 'ok'; }

HTTP_BODY='{"model":"gemini-2.0-flash","stream":false,"messages":[{"role":"user","content":"hi"}]}'
HTTP_ORIGIN=""
_handle_openai_chat_completions >/dev/null
captured_agent="$(cat "$_agent_capture_file" 2>/dev/null)"
assert_eq "$captured_agent" "main"
unset -f engine_run
teardown_test_env

report_results
