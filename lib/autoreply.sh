#!/usr/bin/env bash
# Auto-reply rules module for bashclaw
# Pattern-based automatic responses with channel filtering

_AUTOREPLY_DIR=""

# Initialize autoreply directory
_autoreply_dir() {
  if [[ -z "$_AUTOREPLY_DIR" ]]; then
    _AUTOREPLY_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/autoreplies"
  fi
  ensure_dir "$_AUTOREPLY_DIR"
  printf '%s' "$_AUTOREPLY_DIR"
}

# Add a new auto-reply rule
# Usage: autoreply_add PATTERN RESPONSE [--channel CH] [--priority N]
autoreply_add() {
  local pattern="${1:?pattern required}"
  local response="${2:?response required}"
  shift 2

  local channel_filter=""
  local priority=100
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel) channel_filter="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "autoreply_add requires jq"

  local dir
  dir="$(_autoreply_dir)"
  local id
  id="$(uuid_generate)"
  local safe_id
  safe_id="$(sanitize_key "$id")"
  local file="${dir}/${safe_id}.json"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq -nc \
    --arg id "$id" \
    --arg pat "$pattern" \
    --arg resp "$response" \
    --arg ch "$channel_filter" \
    --argjson pri "$priority" \
    --arg ca "$now" \
    '{id: $id, pattern: $pat, response: $resp, channel_filter: $ch, enabled: true, priority: $pri, created_at: $ca}' \
    > "$file"

  chmod 600 "$file" 2>/dev/null || true
  log_info "Autoreply added: id=$id pattern=$pattern"
  printf '%s' "$id"
}

# Check a message against all rules, return first matching response
# Returns empty string if no match
# Usage: autoreply_check MESSAGE CHANNEL
autoreply_check() {
  local message="${1:?message required}"
  local channel="${2:-}"

  require_command jq "autoreply_check requires jq"

  local dir
  dir="$(_autoreply_dir)"

  # Load all enabled rules and sort by priority (lower = higher priority)
  local ndjson=""
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(cat "$f")"
    local enabled
    enabled="$(printf '%s' "$entry" | jq -r '.enabled // false')"
    if [[ "$enabled" == "true" ]]; then
      ndjson="${ndjson}${entry}"$'\n'
    fi
  done

  # Sort by priority ascending
  local rules
  if [[ -n "$ndjson" ]]; then
    rules="$(printf '%s' "$ndjson" | jq -s 'sort_by(.priority)')"
  else
    rules="[]"
  fi

  local count
  count="$(printf '%s' "$rules" | jq 'length')"
  local i=0

  while (( i < count )); do
    local rule_pattern rule_response rule_channel
    rule_pattern="$(printf '%s' "$rules" | jq -r ".[$i].pattern // \"\"")"
    rule_response="$(printf '%s' "$rules" | jq -r ".[$i].response // \"\"")"
    rule_channel="$(printf '%s' "$rules" | jq -r ".[$i].channel_filter // \"\"")"

    # Check channel filter
    if [[ -n "$rule_channel" && -n "$channel" && "$rule_channel" != "$channel" ]]; then
      i=$((i + 1))
      continue
    fi

    # Check pattern match: split pipe-separated alternatives and use
    # fixed-string matching for each to prevent regex injection.
    local _matched=false
    local _saved_ifs="$IFS"
    IFS='|'
    local _alt
    for _alt in $rule_pattern; do
      IFS="$_saved_ifs"
      if [[ -n "$_alt" ]] && printf '%s' "$message" | grep -qiF "$_alt" 2>/dev/null; then
        _matched=true
        break
      fi
    done
    IFS="$_saved_ifs"

    if [[ "$_matched" == "true" ]]; then
      printf '%s' "$rule_response"
      return 0
    fi

    i=$((i + 1))
  done

  return 1
}

# Remove an auto-reply rule by ID
autoreply_remove() {
  local id="${1:?id required}"

  local dir
  dir="$(_autoreply_dir)"

  # Search by ID in all files
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local file_id
    file_id="$(jq -r '.id // empty' < "$f" 2>/dev/null)"
    if [[ "$file_id" == "$id" ]]; then
      rm -f "$f"
      log_info "Autoreply removed: id=$id"
      return 0
    fi
  done

  log_warn "Autoreply not found: id=$id"
  return 1
}

# List all auto-reply rules
autoreply_list() {
  require_command jq "autoreply_list requires jq"

  local dir
  dir="$(_autoreply_dir)"
  local ndjson=""
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(cat "$f")"
    ndjson="${ndjson}${entry}"$'\n'
  done

  local result
  if [[ -n "$ndjson" ]]; then
    result="$(printf '%s' "$ndjson" | jq -s '.')"
  else
    result="[]"
  fi
  printf '%s' "$result" | jq 'sort_by(.priority)'
}
