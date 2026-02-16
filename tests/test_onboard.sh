#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_onboard"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- _onboard_config with existing config prompts for overwrite ----

test_start "_onboard_config with existing config prompts for overwrite"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
cfg_path="$(config_path)"
assert_file_exists "$cfg_path"
result="$(printf 'n\n' | _onboard_config 2>&1)"
assert_contains "$result" "already exists"
assert_contains "$result" "Keeping existing config"
teardown_test_env

# ---- _onboard_config without existing config creates one ----

test_start "_onboard_config without existing config creates one"
setup_test_env
_source_libs
cfg_path="$(config_path)"
assert_file_not_exists "$cfg_path"
_onboard_config >/dev/null 2>&1
assert_file_exists "$cfg_path"
teardown_test_env

# ---- onboard_channel with unknown channel returns error ----

test_start "onboard_channel with unknown channel returns error"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
set +e
onboard_channel "nonexistent_channel" >/dev/null 2>&1
rc=$?
set -e
assert_ne "$rc" "0" "unknown channel should return non-zero exit code"
teardown_test_env

# ---- _onboard_engine writes config for auto ----

test_start "_onboard_engine writes config correctly for auto"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
printf '1\n' | _onboard_engine >/dev/null 2>&1
config_load
engine="$(config_get '.agents.defaults.engine')"
assert_eq "$engine" "auto"
teardown_test_env

# ---- _onboard_engine writes config for builtin ----

test_start "_onboard_engine writes config correctly for builtin"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
printf '2\n' | _onboard_engine >/dev/null 2>&1
config_load
engine="$(config_get '.agents.defaults.engine')"
assert_eq "$engine" "builtin"
teardown_test_env

# ---- _onboard_engine invalid choice defaults to auto ----

test_start "_onboard_engine invalid choice defaults to auto"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
printf '99\n' | _onboard_engine >/dev/null 2>&1
config_load
engine="$(config_get '.agents.defaults.engine')"
assert_eq "$engine" "auto"
teardown_test_env

# ---- _onboard_gateway generates a UUID token ----

test_start "_onboard_gateway generates a UUID token"
setup_test_env
_source_libs
config_init_default >/dev/null 2>&1
result="$(printf 'y\n' | _onboard_gateway 2>&1)"
assert_contains "$result" "Gateway auth token generated"
config_load
token="$(config_get '.gateway.auth.token')"
assert_ne "$token" ""
assert_ne "$token" "null"
# UUID format: 8-4-4-4-12 hex characters
assert_match "$token" '^[0-9a-fA-F-]+$'
teardown_test_env

# ---- _onboard_verify_api_key with anthropic provider (mock curl) ----

test_start "_onboard_verify_api_key with anthropic provider mock"
setup_test_env
_source_libs

mock_dir="${_TEST_TMPDIR}/mockbin"
mkdir -p "$mock_dir"
cat > "${mock_dir}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '{"id":"msg_test","type":"message","content":[{"type":"text","text":"hi"}]}'
MOCKEOF
chmod +x "${mock_dir}/curl"
export PATH="${mock_dir}:$PATH"

result="$(_onboard_verify_api_key "anthropic" "sk-ant-test-key" 2>&1)"
assert_contains "$result" "OK"
teardown_test_env

# ---- _onboard_verify_api_key with anthropic provider returns error on auth failure ----

test_start "_onboard_verify_api_key anthropic returns error on auth failure"
setup_test_env
_source_libs

mock_dir="${_TEST_TMPDIR}/mockbin"
mkdir -p "$mock_dir"
cat > "${mock_dir}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '{"error":{"type":"authentication_error","message":"invalid x-api-key"}}'
MOCKEOF
chmod +x "${mock_dir}/curl"
export PATH="${mock_dir}:$PATH"

set +e
_onboard_verify_api_key "anthropic" "bad-key" >/dev/null 2>&1
rc=$?
set -e
assert_ne "$rc" "0" "invalid API key should return non-zero"
teardown_test_env

report_results
