#!/usr/bin/env bash
# Idempotency / deduplication cache for bashclaw
# File-based cache stored in ${BASHCLAW_STATE_DIR}/dedup/
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

_DEDUP_DIR=""

_dedup_dir() {
  if [[ -z "$_DEDUP_DIR" ]]; then
    _DEDUP_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/dedup"
  fi
  ensure_dir "$_DEDUP_DIR"
  printf '%s' "$_DEDUP_DIR"
}

# Check if a key was recently processed within the given TTL.
# Returns 0 if the key exists and is still valid (duplicate), 1 otherwise.
# Usage: dedup_check KEY TTL_SECONDS
dedup_check() {
  local key="${1:?key required}"
  local ttl="${2:-300}"

  local dir
  dir="$(_dedup_dir)"

  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${dir}/${safe_key}.json"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  require_command jq "dedup_check requires jq"

  local recorded_ts
  recorded_ts="$(jq -r '.timestamp // "0"' < "$file" 2>/dev/null)"
  if [[ -z "$recorded_ts" || "$recorded_ts" == "0" ]]; then
    return 1
  fi

  local now
  now="$(date +%s)"
  local age=$((now - recorded_ts))

  if [ "$age" -lt "$ttl" ]; then
    return 0
  fi

  # Expired entry
  rm -f "$file"
  return 1
}

# Record a key with its result in the dedup cache.
# Usage: dedup_record KEY [RESULT]
dedup_record() {
  local key="${1:?key required}"
  local result="${2:-}"

  require_command jq "dedup_record requires jq"

  local dir
  dir="$(_dedup_dir)"

  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${dir}/${safe_key}.json"

  local now
  now="$(date +%s)"

  jq -nc \
    --arg key "$key" \
    --arg result "$result" \
    --arg ts "$now" \
    '{key: $key, result: $result, timestamp: ($ts | tonumber)}' \
    > "$file"

  chmod 600 "$file" 2>/dev/null || true
}

# Retrieve the cached result for a key.
# Prints the result value, or empty if not found / expired.
# Usage: dedup_get KEY [TTL_SECONDS]
dedup_get() {
  local key="${1:?key required}"
  local ttl="${2:-300}"

  if ! dedup_check "$key" "$ttl"; then
    return 1
  fi

  local dir
  dir="$(_dedup_dir)"
  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${dir}/${safe_key}.json"

  jq -r '.result // empty' < "$file" 2>/dev/null
}

# Clean up expired entries from the dedup cache.
# Usage: dedup_cleanup [MAX_AGE_SECONDS]
dedup_cleanup() {
  local max_age="${1:-3600}"

  local dir
  dir="$(_dedup_dir)"
  local now
  now="$(date +%s)"
  local cleaned=0

  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue

    local recorded_ts
    recorded_ts="$(jq -r '.timestamp // "0"' < "$f" 2>/dev/null)" || recorded_ts=""
    if [[ -z "$recorded_ts" || "$recorded_ts" == "0" ]]; then
      rm -f "$f"
      cleaned=$((cleaned + 1))
      continue
    fi

    local age=$((now - recorded_ts))
    if [ "$age" -ge "$max_age" ]; then
      rm -f "$f"
      cleaned=$((cleaned + 1))
    fi
  done

  if [ "$cleaned" -gt 0 ]; then
    log_debug "Dedup cleanup: removed $cleaned expired entries"
  fi
}

# Generate a dedup key from message parameters.
# Combines channel, sender, and a content hash for uniqueness.
# Usage: dedup_message_key CHANNEL SENDER CONTENT
dedup_message_key() {
  local channel="${1:-}"
  local sender="${2:-}"
  local content="${3:-}"

  local content_hash
  content_hash="$(hash_string "$content")"
  printf 'msg_%s_%s_%s' "$channel" "$sender" "$content_hash"
}
