#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_memory"

# Helper to source all libs in a fresh test env
_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- memory_store + memory_get round-trip ----

test_start "memory_store + memory_get round-trip"
setup_test_env
_source_libs
memory_store "test_key" "test_value"
result="$(memory_get "test_key")"
assert_eq "$result" "test_value"
teardown_test_env

# ---- memory_store with tags ----

test_start "memory_store with tags"
setup_test_env
_source_libs
memory_store "tagged_key" "tagged_value" --tags "tag1,tag2"
result="$(memory_get "tagged_key")"
assert_eq "$result" "tagged_value"
# Verify tags are stored in the JSON file
dir="$(memory_dir)"
safe_key="$(_memory_key_to_filename "tagged_key")"
tags="$(jq -r '.tags | join(",")' < "${dir}/${safe_key}.json")"
assert_contains "$tags" "tag1"
assert_contains "$tags" "tag2"
teardown_test_env

# ---- memory_search keyword matching ----

test_start "memory_search keyword matching"
setup_test_env
_source_libs
memory_store "fruit_apple" "red fruit"
memory_store "fruit_banana" "yellow fruit"
memory_store "veggie_carrot" "orange vegetable"
result="$(memory_search "fruit")"
assert_json_valid "$result"
assert_contains "$result" "fruit_apple"
assert_contains "$result" "fruit_banana"
teardown_test_env

# ---- memory_search no results ----

test_start "memory_search no results"
setup_test_env
_source_libs
memory_store "alpha" "value_a"
result="$(memory_search "zzz_nonexistent")"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "0"
teardown_test_env

# ---- memory_list with limit ----

test_start "memory_list with limit"
setup_test_env
_source_libs
memory_store "k1" "v1"
memory_store "k2" "v2"
memory_store "k3" "v3"
memory_store "k4" "v4"
memory_store "k5" "v5"
result="$(memory_list --limit 3)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "3"
teardown_test_env

# ---- memory_delete removes entry ----

test_start "memory_delete removes entry"
setup_test_env
_source_libs
memory_store "del_key" "del_value"
result="$(memory_get "del_key")"
assert_eq "$result" "del_value"
memory_delete "del_key"
set +e
result="$(memory_get "del_key" 2>/dev/null)"
rc=$?
set -e
if (( rc != 0 )); then
  _test_pass
else
  _test_fail "memory_get should fail after delete"
fi
teardown_test_env

# ---- memory_export valid JSON array ----

test_start "memory_export valid JSON array"
setup_test_env
_source_libs
memory_store "exp1" "val1"
memory_store "exp2" "val2"
result="$(memory_export)"
assert_json_valid "$result"
length="$(printf '%s' "$result" | jq 'length')"
assert_ge "$length" 2
teardown_test_env

# ---- memory_import restores entries ----

test_start "memory_import restores entries"
setup_test_env
_source_libs
memory_store "imp1" "val1"
memory_store "imp2" "val2"
# Export to a file
export_file="${BASHCLAW_STATE_DIR}/export.json"
memory_export > "$export_file"
# Clear entries
memory_delete "imp1"
memory_delete "imp2"
# Import from file
memory_import "$export_file"
result1="$(memory_get "imp1")"
assert_eq "$result1" "val1"
result2="$(memory_get "imp2")"
assert_eq "$result2" "val2"
teardown_test_env

# ---- memory_compact deduplicates ----

test_start "memory_compact removes invalid entries"
setup_test_env
_source_libs
memory_store "dup_key" "first"
memory_store "dup_key" "second"
# Create an invalid JSON file in memory dir
dir="$(memory_dir)"
printf 'not json' > "${dir}/bad_entry.json"
memory_compact
result="$(memory_get "dup_key")"
assert_eq "$result" "second"
# bad_entry.json should be removed
assert_file_not_exists "${dir}/bad_entry.json"
teardown_test_env

# ---- access_count increments on get ----

test_start "access_count increments on get"
setup_test_env
_source_libs
memory_store "access_key" "val"
memory_get "access_key" >/dev/null
memory_get "access_key" >/dev/null
memory_get "access_key" >/dev/null
dir="$(memory_dir)"
safe_key="$(_memory_key_to_filename "access_key")"
ac="$(jq -r '.access_count // 0' < "${dir}/${safe_key}.json")"
assert_ge "$ac" 3
teardown_test_env

# ---- Edge Case: memory_store with empty key ----

test_start "memory_store with empty key fails"
setup_test_env
_source_libs
rc=0
(memory_store "" "some_value") 2>/dev/null || rc=$?
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: memory_store with key containing special characters ----

test_start "memory_store with key containing special characters"
setup_test_env
_source_libs
memory_store "key/with:special@chars!&spaces" "special_value"
result="$(memory_get "key/with:special@chars!&spaces")"
assert_eq "$result" "special_value"
teardown_test_env

# ---- Edge Case: memory_recall with no matching results ----

test_start "memory_search with no matching results returns empty"
setup_test_env
_source_libs
memory_store "alpha_key" "alpha_value"
memory_store "beta_key" "beta_value"
result="$(memory_search "zzz_completely_nonexistent_string_xyz")"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "0"
teardown_test_env

# ---- Edge Case: memory_forget non-existent key ----

test_start "memory_delete non-existent key returns failure"
setup_test_env
_source_libs
set +e
memory_delete "totally_nonexistent_key_xyz" 2>/dev/null
rc=$?
set -e
assert_ne "$rc" "0"
teardown_test_env

# ---- Edge Case: memory_search with empty query ----

test_start "memory_search with empty query fails"
setup_test_env
_source_libs
rc=0
(memory_search "") 2>/dev/null || rc=$?
assert_ne "$rc" "0"
teardown_test_env

# ---- memory_search_text returns scored results ----

test_start "memory_search_text returns scored results"
setup_test_env
_source_libs
memory_store "fruit_apple" "red apple fruit" --tags "food,fruit"
memory_store "fruit_banana" "yellow banana fruit" --tags "food,fruit"
memory_store "veggie_carrot" "orange vegetable carrot" --tags "food,veggie"
result="$(memory_search_text "fruit" 10)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_ge "$count" 2
# Each result should have a score field
has_score="$(printf '%s' "$result" | jq '.[0].score // 0')"
assert_gt "$has_score" 0
teardown_test_env

# ---- memory_search_text handles empty query ----

test_start "memory_search_text handles empty query"
setup_test_env
_source_libs
memory_store "some_key" "some_value"
result="$(memory_search_text "" 10)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "0"
teardown_test_env

# ---- memory_search_text key boost ----

test_start "memory_search_text boosts key matches"
setup_test_env
_source_libs
# Both entries contain "apple" in value, but only one has it in the key
memory_store "apple_info" "apple is a tasty red fruit"
memory_store "random_info" "apple is a red fruit"
result="$(memory_search_text "apple" 10)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_ge "$count" 2
# The entry with "apple" in the key should score higher due to 2x key boost
first_key="$(printf '%s' "$result" | jq -r '.[0].key')"
assert_eq "$first_key" "apple_info"
teardown_test_env

# ---- memory_search_workspace scans MEMORY.md ----

test_start "memory_search_workspace scans MEMORY.md"
setup_test_env
_source_libs
agent_id="test_agent_ws"
mkdir -p "${BASHCLAW_STATE_DIR}/agents/${agent_id}/memory"
printf '# Memory\n\n## Project Setup\n\nThis section covers deployment pipeline\n\n## API Design\n\nREST endpoints for the service\n' > "${BASHCLAW_STATE_DIR}/agents/${agent_id}/MEMORY.md"
result="$(memory_search_workspace "deployment" "$agent_id")"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_ge "$count" 1
assert_contains "$result" "deployment"
teardown_test_env

# ---- memory_search_workspace handles missing workspace ----

test_start "memory_search_workspace handles missing workspace"
setup_test_env
_source_libs
result="$(memory_search_workspace "anything" "nonexistent_agent")"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_eq "$count" "0"
teardown_test_env

# ---- memory_sync_workspace indexes MEMORY.md ----

test_start "memory_sync_workspace indexes MEMORY.md"
setup_test_env
_source_libs
agent_id="sync_test_agent"
mkdir -p "${BASHCLAW_STATE_DIR}/agents/${agent_id}/memory"
printf '# Memory\n\n## Architecture\n\nMicroservices with event bus\n' > "${BASHCLAW_STATE_DIR}/agents/${agent_id}/MEMORY.md"
result="$(memory_sync_workspace "$agent_id")"
assert_json_valid "$result"
updated="$(printf '%s' "$result" | jq '.files_updated')"
assert_gt "$updated" 0
# Verify index file was created
assert_file_exists "${BASHCLAW_STATE_DIR}/memory/.workspace_index.json"
teardown_test_env

# ---- memory_search_all combines results ----

test_start "memory_search_all combines KV and workspace results"
setup_test_env
_source_libs
memory_store "deploy_notes" "kubernetes deployment guide" --tags "infra"
agent_id="all_test_agent"
mkdir -p "${BASHCLAW_STATE_DIR}/agents/${agent_id}/memory"
printf '# Memory\n\n## Deployment\n\nDocker compose setup for deployment\n' > "${BASHCLAW_STATE_DIR}/agents/${agent_id}/MEMORY.md"
result="$(memory_search_all "deployment" "$agent_id" 10)"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_ge "$count" 1
teardown_test_env

report_results
