#!/usr/bin/env bash
# Security module for bashclaw
# Audit logging, pairing codes, rate limiting, exec approval,
# tool policy, elevated policy, command auth (Gaps 9.1, 9.2, 9.3)

# Timing-safe string comparison using HMAC.
# Compares two strings in constant time to prevent timing side-channel attacks.
# Both inputs are hashed with an ephemeral HMAC key so the final comparison
# operates on fixed-length digests regardless of input lengths.
# Returns 0 if equal, 1 otherwise.
_security_safe_equal() {
  local a="$1"
  local b="$2"

  local hmac_key
  hmac_key="bashclaw_$$_$(date +%s)"

  local hash_a hash_b
  if command -v openssl >/dev/null 2>&1; then
    hash_a="$(printf '%s' "$a" | openssl dgst -sha256 -hmac "$hmac_key" 2>/dev/null | awk '{print $NF}')"
    hash_b="$(printf '%s' "$b" | openssl dgst -sha256 -hmac "$hmac_key" 2>/dev/null | awk '{print $NF}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash_a="$(printf '%s%s' "$hmac_key" "$a" | shasum -a 256 2>/dev/null | awk '{print $1}')"
    hash_b="$(printf '%s%s' "$hmac_key" "$b" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash_a="$(printf '%s%s' "$hmac_key" "$a" | sha256sum 2>/dev/null | awk '{print $1}')"
    hash_b="$(printf '%s%s' "$hmac_key" "$b" | sha256sum 2>/dev/null | awk '{print $1}')"
  else
    [[ "$a" == "$b" ]]
    return $?
  fi

  [[ "$hash_a" == "$hash_b" ]]
}

# Append an audit event to the audit log (JSONL format)
security_audit_log() {
  local event="${1:?event required}"
  local details="${2:-}"

  require_command jq "security_audit_log requires jq"

  local log_dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/logs"
  ensure_dir "$log_dir"
  local audit_file="${log_dir}/audit.jsonl"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local line
  line="$(jq -nc \
    --arg ev "$event" \
    --arg dt "$details" \
    --arg ts "$now" \
    --arg pid "$$" \
    '{event: $ev, details: $dt, timestamp: $ts, pid: ($pid | tonumber)}')"

  printf '%s\n' "$line" >> "$audit_file"
}

# Generate a 6-digit pairing code for a channel+sender combination
# Saves the code with an expiry (default 5 minutes)
security_pairing_code_generate() {
  local channel="${1:?channel required}"
  local sender="${2:?sender required}"

  require_command jq "security_pairing_code_generate requires jq"

  local pair_dir="${BASHCLAW_STATE_DIR:?}/pairing"
  ensure_dir "$pair_dir"

  # Generate 6-digit numeric code from /dev/urandom
  local code
  if [[ -r /dev/urandom ]]; then
    local raw_bytes
    raw_bytes="$(od -A n -t u4 -N 4 /dev/urandom 2>/dev/null | tr -d ' ')"
    code="$(printf '%06d' "$((raw_bytes % 1000000))")"
  else
    code="$(printf '%06d' "$((RANDOM * 32768 + RANDOM))")"
  fi
  local now
  now="$(date +%s)"
  local expiry=$((now + 300))

  local safe_key
  safe_key="$(sanitize_key "${channel}_${sender}")"
  local file="${pair_dir}/${safe_key}.json"

  jq -nc \
    --arg ch "$channel" \
    --arg snd "$sender" \
    --arg code "$code" \
    --argjson exp "$expiry" \
    --argjson ts "$now" \
    '{channel: $ch, sender: $snd, code: $code, expires_at: $exp, created_at: $ts}' \
    > "$file"

  chmod 600 "$file" 2>/dev/null || true
  security_audit_log "pairing_code_generated" "channel=$channel sender=$sender"

  printf '%s' "$code"
}

# Verify a pairing code for a channel+sender combination
# Returns 0 on success, 1 on failure
security_pairing_code_verify() {
  local channel="${1:?channel required}"
  local sender="${2:?sender required}"
  local code="${3:?code required}"

  require_command jq "security_pairing_code_verify requires jq"

  local pair_dir="${BASHCLAW_STATE_DIR:?}/pairing"
  local safe_key
  safe_key="$(sanitize_key "${channel}_${sender}")"
  local file="${pair_dir}/${safe_key}.json"

  if [[ ! -f "$file" ]]; then
    security_audit_log "pairing_code_verify_failed" "channel=$channel sender=$sender reason=no_code"
    return 1
  fi

  local stored_code expiry
  local parsed
  parsed="$(jq -r '[(.code // ""), (.expires_at // 0 | tostring)] | join("\n")' < "$file")"
  {
    IFS= read -r stored_code
    IFS= read -r expiry
  } <<< "$parsed"

  local now
  now="$(date +%s)"

  # Check expiry
  if (( now > expiry )); then
    rm -f "$file"
    security_audit_log "pairing_code_verify_failed" "channel=$channel sender=$sender reason=expired"
    return 1
  fi

  # Check code match (timing-safe)
  if ! _security_safe_equal "$code" "$stored_code"; then
    security_audit_log "pairing_code_verify_failed" "channel=$channel sender=$sender reason=mismatch"
    return 1
  fi

  # Code is valid, remove it (single use) and mark as verified
  rm -f "$file"

  local verified_dir="${pair_dir}/verified"
  ensure_dir "$verified_dir"
  printf '%s' "$(date +%s)" > "${verified_dir}/${safe_key}"

  security_audit_log "pairing_code_verified" "channel=$channel sender=$sender"
  return 0
}

# Token bucket rate limiter using files
# Returns 0 if request is allowed, 1 if rate limited
security_rate_limit() {
  local sender="${1:?sender required}"
  local max_per_min="${2:-30}"

  local rl_dir="${BASHCLAW_STATE_DIR:?}/ratelimit"
  ensure_dir "$rl_dir"

  local safe_sender
  safe_sender="$(sanitize_key "$sender")"
  local file="${rl_dir}/${safe_sender}.dat"

  local now
  now="$(date +%s)"
  local window_start=$((now - 60))

  # Read existing timestamps, filter to current window
  local count=0
  if [[ -f "$file" ]]; then
    local tmp
    tmp="$(mktemp -t bashclaw_rl.XXXXXX 2>/dev/null || mktemp /tmp/bashclaw_rl.XXXXXX)"
    while IFS= read -r ts; do
      if (( ts > window_start )); then
        printf '%s\n' "$ts" >> "$tmp"
        count=$((count + 1))
      fi
    done < "$file"
    mv "$tmp" "$file"
  fi

  if (( count >= max_per_min )); then
    security_audit_log "rate_limited" "sender=$sender count=$count max=$max_per_min"
    return 1
  fi

  # Record this request
  printf '%s\n' "$now" >> "$file"
  return 0
}

# Check if a command needs execution approval
# Returns "approved" for safe commands, "needs_approval" for dangerous ones
security_exec_approval() {
  local cmd="${1:?command required}"

  # Check against dangerous patterns
  case "$cmd" in
    *"rm -rf"*|*"mkfs"*|*"dd if="*|*"chmod -R 777 /"*|*":(){:"*)
      security_audit_log "exec_blocked" "command=$cmd"
      printf 'blocked'
      return 1
      ;;
    *sudo*|*"> /dev/"*|*"curl "*"|"*sh*|*"wget "*"|"*sh*)
      security_audit_log "exec_needs_approval" "command=$cmd"
      printf 'needs_approval'
      return 0
      ;;
    *)
      printf 'approved'
      return 0
      ;;
  esac
}

# ---- Tool Policy Check (Gap 9.1) ----
# Check if a tool is allowed for the given agent and session type
# Returns 0 if allowed, 1 if denied
security_tool_policy_check() {
  local agent_id="${1:?agent_id required}"
  local tool_name="${2:?tool_name required}"
  local session_type="${3:-main}"

  require_command jq "security_tool_policy_check requires jq"

  # Get agent-specific tool policy
  local tools_allow
  tools_allow="$(config_get_raw "(.agents.list // [] | map(select(.id == \"${agent_id}\")) | .[0].tools.allow // null)" 2>/dev/null)"
  local tools_deny
  tools_deny="$(config_get_raw "(.agents.list // [] | map(select(.id == \"${agent_id}\")) | .[0].tools.deny // null)" 2>/dev/null)"

  # Fall back to defaults
  if [[ "$tools_allow" == "null" || -z "$tools_allow" ]]; then
    tools_allow="$(config_get_raw '.agents.defaults.tools.allow // null' 2>/dev/null)"
  fi
  if [[ "$tools_deny" == "null" || -z "$tools_deny" ]]; then
    tools_deny="$(config_get_raw '.agents.defaults.tools.deny // null' 2>/dev/null)"
  fi

  # Check deny list first (deny takes precedence)
  if [[ "$tools_deny" != "null" && -n "$tools_deny" ]]; then
    local is_denied
    is_denied="$(printf '%s' "$tools_deny" | jq --arg t "$tool_name" 'any(. == $t)' 2>/dev/null)"
    if [[ "$is_denied" == "true" ]]; then
      security_audit_log "tool_denied" "agent=$agent_id tool=$tool_name reason=deny_list"
      return 1
    fi
  fi

  # Check allow list (if set, only listed tools are allowed)
  if [[ "$tools_allow" != "null" && -n "$tools_allow" ]]; then
    local is_allowed
    is_allowed="$(printf '%s' "$tools_allow" | jq --arg t "$tool_name" 'any(. == $t)' 2>/dev/null)"
    if [[ "$is_allowed" != "true" ]]; then
      security_audit_log "tool_denied" "agent=$agent_id tool=$tool_name reason=not_in_allow_list"
      return 1
    fi
  fi

  # Session-type restrictions for subagents
  if [[ "$session_type" == "subagent" ]]; then
    # Subagents get a restricted tool set
    case "$tool_name" in
      memory_store|memory_delete|cron_add|cron_remove|exec|shell)
        security_audit_log "tool_denied" "agent=$agent_id tool=$tool_name reason=subagent_restricted"
        return 1
        ;;
    esac
  fi

  # Cron sessions also have restrictions
  if [[ "$session_type" == "cron" ]]; then
    case "$tool_name" in
      cron_add|cron_remove)
        security_audit_log "tool_denied" "agent=$agent_id tool=$tool_name reason=cron_restricted"
        return 1
        ;;
    esac
  fi

  return 0
}

# ---- Elevated Policy Check (Gap 9.1) ----
# For tools/operations requiring elevated authorization
# Returns "approved", "needs_approval", or "blocked"
security_elevated_check() {
  local tool_name="${1:?tool_name required}"
  local sender="${2:-}"
  local channel="${3:-}"

  require_command jq "security_elevated_check requires jq"

  # Elevated tools that always require approval
  case "$tool_name" in
    exec|shell|write_file)
      # Check if sender is in the elevated users list
      local elevated_users
      elevated_users="$(config_get_raw '.security.elevatedUsers // []' 2>/dev/null)"
      if [[ "$elevated_users" != "null" && "$elevated_users" != "[]" && -n "$elevated_users" ]]; then
        local is_elevated
        is_elevated="$(printf '%s' "$elevated_users" | jq --arg s "$sender" 'any(. == $s)' 2>/dev/null)"
        if [[ "$is_elevated" == "true" ]]; then
          security_audit_log "elevated_approved" "tool=$tool_name sender=$sender"
          printf 'approved'
          return 0
        fi
      fi
      security_audit_log "elevated_needs_approval" "tool=$tool_name sender=$sender"
      printf 'needs_approval'
      return 0
      ;;
    # Tools that are always blocked in non-elevated contexts
    system_reset|config_write)
      security_audit_log "elevated_blocked" "tool=$tool_name sender=$sender"
      printf 'blocked'
      return 1
      ;;
    *)
      printf 'approved'
      return 0
      ;;
  esac
}

# ---- Command Authorization Check (Gap 9.3) ----
# Check if a sender is authorized to execute a named command
# Returns 0 if authorized, 1 if not
security_command_auth_check() {
  local command_name="${1:?command_name required}"
  local sender="${2:-}"

  require_command jq "security_command_auth_check requires jq"

  # Check command-specific authorization
  local cmd_auth
  cmd_auth="$(config_get_raw ".security.commands.\"${command_name}\" // null" 2>/dev/null)"

  if [[ "$cmd_auth" == "null" || -z "$cmd_auth" ]]; then
    # No specific auth required for this command
    return 0
  fi

  # Check if command requires specific role or user
  local required_role
  required_role="$(printf '%s' "$cmd_auth" | jq -r '.requiredRole // empty' 2>/dev/null)"
  local allowed_users
  allowed_users="$(printf '%s' "$cmd_auth" | jq '.allowedUsers // []' 2>/dev/null)"

  # Check allowed users
  if [[ "$allowed_users" != "[]" && -n "$allowed_users" ]]; then
    local user_match
    user_match="$(printf '%s' "$allowed_users" | jq --arg s "$sender" 'any(. == $s)' 2>/dev/null)"
    if [[ "$user_match" == "true" ]]; then
      return 0
    fi
  fi

  # Check role-based access
  if [[ -n "$required_role" ]]; then
    local user_roles
    user_roles="$(config_get_raw ".security.userRoles.\"${sender}\" // []" 2>/dev/null)"
    if [[ "$user_roles" != "[]" && -n "$user_roles" ]]; then
      local has_role
      has_role="$(printf '%s' "$user_roles" | jq --arg r "$required_role" 'any(. == $r)' 2>/dev/null)"
      if [[ "$has_role" == "true" ]]; then
        return 0
      fi
    fi
  fi

  security_audit_log "command_auth_denied" "command=$command_name sender=$sender"
  return 1
}
