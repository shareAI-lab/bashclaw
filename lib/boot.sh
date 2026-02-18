#!/usr/bin/env bash
# Boot automation module for bashclaw
# Parses BOOT.md files and executes startup instructions

# ---- Agent Workspace Boot Discovery ----

# Find BOOT.md for a specific agent in the standard workspace location
boot_find() {
  local agent_id="${1:?agent_id required}"

  local workspace="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}"
  local boot_file="${workspace}/BOOT.md"

  if [[ -f "$boot_file" ]]; then
    printf '%s' "$boot_file"
    return 0
  fi

  return 1
}

# Auto-boot on first agent start if BOOT.md exists and not already completed
boot_auto() {
  local agent_id="${1:?agent_id required}"

  local boot_file
  boot_file="$(boot_find "$agent_id" 2>/dev/null)" || return 0

  # Check if boot already completed for this agent
  local status_file="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}/boot_status.json"
  if [[ -f "$status_file" ]]; then
    local status
    status="$(jq -r '.status // "none"' < "$status_file" 2>/dev/null)"
    if [[ "$status" == "completed" || "$status" == "completed_with_errors" ]]; then
      log_debug "Boot already completed for agent=$agent_id"
      return 0
    fi
  fi

  log_info "Auto-boot triggered for agent=$agent_id"
  local workspace
  workspace="$(dirname "$boot_file")"
  boot_run "$workspace"
}

# Run boot sequence for a workspace directory
# Looks for BOOT.md, parses it, and executes code blocks via agent
boot_run() {
  local workspace_dir="${1:?workspace directory required}"

  if [[ ! -d "$workspace_dir" ]]; then
    log_error "Workspace directory not found: $workspace_dir"
    return 1
  fi

  local boot_file="${workspace_dir}/BOOT.md"
  if [[ ! -f "$boot_file" ]]; then
    log_debug "No BOOT.md found in $workspace_dir"
    return 0
  fi

  log_info "Boot: processing $boot_file"

  # Update boot status
  _boot_set_status "running" "$boot_file" "" "$workspace_dir"

  local blocks
  blocks="$(boot_parse_md "$boot_file")"
  if [[ -z "$blocks" || "$blocks" == "[]" ]]; then
    log_info "Boot: no executable blocks found in BOOT.md"
    _boot_set_status "completed" "$boot_file" "no blocks" "$workspace_dir"
    return 0
  fi

  require_command jq "boot_run requires jq"

  local count
  count="$(printf '%s' "$blocks" | jq 'length')"
  local i=0
  local errors=0

  while (( i < count )); do
    local block_type block_content
    block_type="$(printf '%s' "$blocks" | jq -r ".[$i].type // \"text\"")"
    block_content="$(printf '%s' "$blocks" | jq -r ".[$i].content // \"\"")"

    case "$block_type" in
      bash|sh|shell)
        log_info "Boot: executing shell block $((i + 1))/$count"
        local output
        output="$(bash -c "$block_content" 2>&1)" || {
          log_error "Boot: shell block $((i + 1)) failed: ${output:0:200}"
          errors=$((errors + 1))
        }
        ;;
      agent|message)
        log_info "Boot: sending agent message block $((i + 1))/$count"
        engine_run "main" "$block_content" "boot" "boot" >/dev/null 2>&1 || {
          log_error "Boot: agent block $((i + 1)) failed"
          errors=$((errors + 1))
        }
        ;;
      *)
        log_debug "Boot: skipping non-executable block type=$block_type"
        ;;
    esac

    i=$((i + 1))
  done

  if (( errors > 0 )); then
    _boot_set_status "completed_with_errors" "$boot_file" "$errors errors" "$workspace_dir"
    log_warn "Boot completed with $errors error(s)"
    return 1
  fi

  _boot_set_status "completed" "$boot_file" "" "$workspace_dir"
  log_info "Boot: completed successfully ($count blocks)"
}

# Parse a BOOT.md file and extract code blocks with their types
# Returns JSON array: [{type, content}, ...]
boot_parse_md() {
  local file="${1:?file required}"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 1
  fi

  require_command jq "boot_parse_md requires jq"

  local ndjson=""
  local in_block=false
  local block_type=""
  local block_content=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_block" == "true" ]]; then
      if [[ "$line" == '```' ]]; then
        # End of code block
        if [[ -n "$block_content" ]]; then
          ndjson="${ndjson}$(jq -nc \
            --arg t "$block_type" \
            --arg c "$block_content" \
            '{type: $t, content: $c}')"$'\n'
        fi
        in_block=false
        block_type=""
        block_content=""
      else
        if [[ -n "$block_content" ]]; then
          block_content="${block_content}
${line}"
        else
          block_content="$line"
        fi
      fi
    else
      # Check for code block start
      case "$line" in
        '```bash'*|'```sh'*|'```shell'*)
          in_block=true
          block_type="bash"
          block_content=""
          ;;
        '```agent'*|'```message'*)
          in_block=true
          block_type="agent"
          block_content=""
          ;;
        '```'*)
          in_block=true
          # Extract language identifier
          block_type="${line#\`\`\`}"
          block_type="$(printf '%s' "$block_type" | tr -d '[:space:]')"
          block_content=""
          ;;
      esac
    fi
  done < "$file"

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s '.'
  else
    printf '[]'
  fi
}

# Check current boot status
boot_status() {
  local agent_id="${1:-}"

  local status_file
  if [[ -n "$agent_id" ]]; then
    status_file="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}/boot_status.json"
  else
    status_file="${BASHCLAW_STATE_DIR:?}/boot_status.json"
  fi

  if [[ -f "$status_file" ]]; then
    cat "$status_file"
  else
    printf '{"status": "none"}'
  fi
}

# Clear boot state
boot_reset() {
  local agent_id="${1:-}"

  local status_file
  if [[ -n "$agent_id" ]]; then
    status_file="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}/boot_status.json"
  else
    status_file="${BASHCLAW_STATE_DIR:?}/boot_status.json"
  fi

  if [[ -f "$status_file" ]]; then
    rm -f "$status_file"
    log_info "Boot status reset"
  fi
}

# Internal: update boot status file
_boot_set_status() {
  local status="$1"
  local boot_file="${2:-}"
  local detail="${3:-}"
  local workspace_dir="${4:-}"

  require_command jq "_boot_set_status requires jq"

  # Determine status file location
  local status_file
  if [[ -n "$workspace_dir" && -d "$workspace_dir" ]]; then
    status_file="${workspace_dir}/boot_status.json"
  else
    status_file="${BASHCLAW_STATE_DIR:?}/boot_status.json"
  fi

  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  ensure_dir "$(dirname "$status_file")"

  jq -nc \
    --arg s "$status" \
    --arg f "$boot_file" \
    --arg d "$detail" \
    --arg t "$now" \
    '{status: $s, boot_file: $f, detail: $d, updated_at: $t}' \
    > "$status_file"
}
