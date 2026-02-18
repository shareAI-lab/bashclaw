#!/usr/bin/env bash
# System events queue for bashclaw
# Background processes enqueue events; agent drains them on next turn.
# File-based FIFO queue with dedup and max capacity.
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

EVENTS_MAX_PER_SESSION=20

# Directory for event queue files
events_dir() {
  local dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/events"
  ensure_dir "$dir"
  printf '%s' "$dir"
}

# Sanitize a session key for use as a filename
_events_safe_key() {
  sanitize_key "$1"
}

# Enqueue a system event for a session.
# Deduplicates consecutive identical text. Enforces FIFO max of EVENTS_MAX_PER_SESSION.
# Arguments: session_key, text, source
events_enqueue() {
  local session_key="${1:?session_key required}"
  local text="${2:?text required}"
  local source="${3:-system}"

  require_command jq "events_enqueue requires jq"

  local dir
  dir="$(events_dir)"
  local safe_key
  safe_key="$(_events_safe_key "$session_key")"
  local file="${dir}/${safe_key}.jsonl"
  local lockfile="${dir}/${safe_key}.lock"

  # Acquire lockfile (spin with timeout)
  local waited=0
  while ! (set -o noclobber; printf '%s' "$$" > "$lockfile") 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 10 )); then
      rm -f "$lockfile"
      log_warn "events_enqueue: stale lock removed for $session_key"
    fi
  done

  # Deduplicate consecutive identical text
  if [[ -f "$file" ]]; then
    local last_text
    last_text="$(tail -n 1 "$file" 2>/dev/null | jq -r '.text // empty' 2>/dev/null)"
    if [[ "$last_text" == "$text" ]]; then
      rm -f "$lockfile"
      log_debug "events_enqueue: dedup skip for $session_key"
      return 0
    fi
  fi

  # Append the event
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc --arg t "$text" --arg s "$source" --argjson ts "$ts" \
    '{text: $t, source: $s, ts: $ts}')"
  printf '%s\n' "$line" >> "$file"

  # Enforce max capacity (FIFO: drop oldest)
  if [[ -f "$file" ]]; then
    local total
    total="$(wc -l < "$file" )"
    if (( total > EVENTS_MAX_PER_SESSION )); then
      local tmp
      tmp="$(tmpfile "events_trim")"
      tail -n "$EVENTS_MAX_PER_SESSION" "$file" > "$tmp"
      mv "$tmp" "$file"
    fi
  fi

  rm -f "$lockfile"
  log_debug "events_enqueue: added event for $session_key from $source"
}

# Drain all queued events for a session.
# Returns them as a JSON array and clears the queue.
events_drain() {
  local session_key="${1:?session_key required}"

  require_command jq "events_drain requires jq"

  local dir
  dir="$(events_dir)"
  local safe_key
  safe_key="$(_events_safe_key "$session_key")"
  local file="${dir}/${safe_key}.jsonl"
  local lockfile="${dir}/${safe_key}.lock"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 0
  fi

  # Acquire lockfile
  local waited=0
  while ! (set -o noclobber; printf '%s' "$$" > "$lockfile") 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 10 )); then
      rm -f "$lockfile"
    fi
  done

  local events
  events="$(jq -s '.' < "$file" 2>/dev/null)"
  if [[ -z "$events" || "$events" == "null" ]]; then
    events="[]"
  fi

  # Clear the queue
  rm -f "$file"
  rm -f "$lockfile"

  printf '%s' "$events"
}

# Inject drained events as system messages into a messages JSON array.
# Arguments: session_key, messages_json (existing messages array)
# Returns: updated messages JSON with events prepended as system messages.
events_inject() {
  local session_key="${1:?session_key required}"
  local messages_json="${2:-[]}"

  require_command jq "events_inject requires jq"

  local events
  events="$(events_drain "$session_key")"

  local count
  count="$(printf '%s' "$events" | jq 'length')"
  if (( count == 0 )); then
    printf '%s' "$messages_json"
    return 0
  fi

  # Build system messages from events
  local event_text
  event_text="$(printf '%s' "$events" | jq -r '
    "System events:\n" + ([.[] | "- [\(.source)]: \(.text)"] | join("\n"))
  ')"

  # Prepend as a system-role user message (since Anthropic API does not allow
  # system role in messages array, we use a user message with [SYSTEM EVENT] prefix)
  printf '%s' "$messages_json" | jq --arg et "$event_text" \
    '[{role: "user", content: ("[SYSTEM EVENT]\n" + $et)}] + .'
}

# Count pending events for a session without draining
events_count() {
  local session_key="${1:?session_key required}"

  local dir
  dir="$(events_dir)"
  local safe_key
  safe_key="$(_events_safe_key "$session_key")"
  local file="${dir}/${safe_key}.jsonl"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return 0
  fi

  wc -l < "$file" | tr -d ' '
}
