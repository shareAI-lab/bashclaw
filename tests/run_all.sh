#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
VERBOSE=false
SINGLE_FILE=""
MODE="all"  # all, unit, integration, compat

for arg in "$@"; do
  case "$arg" in
    --verbose|-v)
      VERBOSE=true
      ;;
    --skip-integration)
      MODE="unit"
      ;;
    --unit)
      MODE="unit"
      ;;
    --integration)
      MODE="integration"
      ;;
    --compat)
      MODE="compat"
      ;;
    --all)
      MODE="all"
      ;;
    *)
      SINGLE_FILE="$arg"
      ;;
  esac
done

export TEST_VERBOSE="$VERBOSE"

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_TESTS=0
FAILED_FILES=()
FILE_RESULTS=()
SUITE_START="$(date +%s)"

printf '====================================\n'
printf '  bashclaw test suite\n'
printf '====================================\n'
printf '  Mode: %s\n' "$MODE"
printf '====================================\n'

run_test_file() {
  local file="$1"
  local name
  name="$(basename "$file")"

  if [[ ! -f "$file" ]]; then
    printf 'WARNING: Skipping missing file: %s\n' "$file"
    return
  fi

  local file_start
  file_start="$(date +%s)"

  # Run in subshell and capture output + exit code
  set +e
  output="$(bash "$file" 2>&1)"
  rc=$?
  set -e

  local file_end
  file_end="$(date +%s)"
  local file_duration=$(( file_end - file_start ))

  printf '%s\n' "$output"

  # Parse passed/failed from output (macOS-compatible sed)
  local file_passed file_failed file_total
  file_passed="$(printf '%s\n' "$output" | sed -n 's/.*Passed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  file_failed="$(printf '%s\n' "$output" | sed -n 's/.*Failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  file_total="$(printf '%s\n' "$output" | sed -n 's/.*Total:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"

  file_passed="${file_passed:-0}"
  file_failed="${file_failed:-0}"
  file_total="${file_total:-0}"

  TOTAL_PASSED=$((TOTAL_PASSED + file_passed))
  TOTAL_FAILED=$((TOTAL_FAILED + file_failed))
  TOTAL_TESTS=$((TOTAL_TESTS + file_total))

  if (( rc != 0 )); then
    FAILED_FILES+=("$name")
    FILE_RESULTS+=("FAIL $name ($file_passed/$file_total passed, ${file_duration}s)")
  else
    FILE_RESULTS+=("PASS $name ($file_passed/$file_total passed, ${file_duration}s)")
  fi
}

# Collect test files based on mode
if [[ -n "$SINGLE_FILE" ]]; then
  if [[ -f "$SINGLE_FILE" ]]; then
    TEST_FILES=("$SINGLE_FILE")
  elif [[ -f "${SCRIPT_DIR}/${SINGLE_FILE}" ]]; then
    TEST_FILES=("${SCRIPT_DIR}/${SINGLE_FILE}")
  elif [[ -f "${SCRIPT_DIR}/${SINGLE_FILE}.sh" ]]; then
    TEST_FILES=("${SCRIPT_DIR}/${SINGLE_FILE}.sh")
  else
    printf 'ERROR: Test file not found: %s\n' "$SINGLE_FILE"
    exit 1
  fi
else
  UNIT_FILES=(
    "${SCRIPT_DIR}/test_utils.sh"
    "${SCRIPT_DIR}/test_config.sh"
    "${SCRIPT_DIR}/test_session.sh"
    "${SCRIPT_DIR}/test_tools.sh"
    "${SCRIPT_DIR}/test_routing.sh"
    "${SCRIPT_DIR}/test_agent.sh"
    "${SCRIPT_DIR}/test_channels.sh"
    "${SCRIPT_DIR}/test_cli.sh"
    "${SCRIPT_DIR}/test_memory.sh"
    "${SCRIPT_DIR}/test_hooks.sh"
    "${SCRIPT_DIR}/test_security.sh"
    "${SCRIPT_DIR}/test_process.sh"
    "${SCRIPT_DIR}/test_boot.sh"
    "${SCRIPT_DIR}/test_autoreply.sh"
    "${SCRIPT_DIR}/test_daemon.sh"
    "${SCRIPT_DIR}/test_install.sh"
    "${SCRIPT_DIR}/test_onboard.sh"
    "${SCRIPT_DIR}/test_heartbeat.sh"
    "${SCRIPT_DIR}/test_events.sh"
    "${SCRIPT_DIR}/test_cron_advanced.sh"
    "${SCRIPT_DIR}/test_plugin.sh"
    "${SCRIPT_DIR}/test_skills.sh"
    "${SCRIPT_DIR}/test_dedup.sh"
    "${SCRIPT_DIR}/test_engine.sh"
    "${SCRIPT_DIR}/test_gateway.sh"
    "${SCRIPT_DIR}/test_workspace_session_spawn.sh"
  )

  INTEGRATION_FILES=(
    "${SCRIPT_DIR}/test_integration.sh"
  )

  COMPAT_FILES=(
    "${SCRIPT_DIR}/test_compat.sh"
  )

  case "$MODE" in
    unit)
      TEST_FILES=("${UNIT_FILES[@]}")
      ;;
    integration)
      TEST_FILES=("${INTEGRATION_FILES[@]}")
      ;;
    compat)
      TEST_FILES=("${COMPAT_FILES[@]}")
      ;;
    all)
      TEST_FILES=("${UNIT_FILES[@]}" "${INTEGRATION_FILES[@]}" "${COMPAT_FILES[@]}")
      ;;
  esac
fi

for file in "${TEST_FILES[@]}"; do
  run_test_file "$file"
done

SUITE_END="$(date +%s)"
SUITE_DURATION=$(( SUITE_END - SUITE_START ))

# Final summary
printf '\n====================================\n'
printf '  FINAL SUMMARY\n'
printf '====================================\n\n'

for line in "${FILE_RESULTS[@]}"; do
  printf '  %s\n' "$line"
done

printf '\n'
printf '  Total tests:  %d\n' "$TOTAL_TESTS"
printf '  Passed:       %d\n' "$TOTAL_PASSED"
printf '  Failed:       %d\n' "$TOTAL_FAILED"
printf '  Duration:     %ds\n' "$SUITE_DURATION"

if (( ${#FAILED_FILES[@]} > 0 )); then
  printf '\n  Failed files:\n'
  for f in "${FAILED_FILES[@]}"; do
    printf '    - %s\n' "$f"
  done
fi

printf '\n'

if (( TOTAL_FAILED > 0 )); then
  printf 'RESULT: FAIL\n'
  exit 1
else
  printf 'RESULT: PASS\n'
  exit 0
fi
