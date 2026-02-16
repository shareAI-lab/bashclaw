#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_boot"

_source_libs() {
  export LOG_LEVEL="silent"
  for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
    [[ -f "$_lib" ]] && source "$_lib"
  done
  unset _lib
}

# ---- boot_parse_md extracts code blocks from markdown ----

test_start "boot_parse_md extracts code blocks from markdown"
setup_test_env
_source_libs
md_file="${BASHCLAW_STATE_DIR}/test_boot.md"
cat > "$md_file" <<'MDEOF'
# Boot Script

Some description text.

```bash
echo "hello from boot"
```

More text here.

```sh
echo "second block"
```
MDEOF
result="$(boot_parse_md "$md_file")"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq 'length')"
assert_ge "$count" 2
assert_contains "$result" "hello from boot"
assert_contains "$result" "second block"
teardown_test_env

# ---- boot_status tracking states ----

test_start "boot_status returns JSON with status field"
setup_test_env
_source_libs
result="$(boot_status)"
assert_json_valid "$result"
status="$(printf '%s' "$result" | jq -r '.status')"
assert_eq "$status" "none"
teardown_test_env

report_results
