#!/usr/bin/env bash
# Hook/middleware system for bashclaw
# Supports 14 event types, execution strategies, and priority ordering.
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

# All supported hook events:
#   pre_message        - before message is processed
#   post_message       - after message is processed
#   pre_tool           - before tool execution
#   post_tool          - after tool execution
#   on_error           - when an error occurs
#   on_session_reset   - when a session is reset
#   before_agent_start - before agent begins processing
#   agent_end          - after agent finishes processing
#   before_compaction  - before context compaction
#   after_compaction   - after context compaction
#   message_received   - when a message arrives at the gateway
#   message_sending    - before a reply is dispatched
#   message_sent       - after a reply is dispatched
#   session_start      - when a new session is created
#   session_end        - when session resets or idle timeout (OpenClaw compat)
#   gateway_start      - when gateway starts (OpenClaw compat)
#   gateway_stop       - when gateway stops (OpenClaw compat)
#   tool_result_persist - after tool result is saved to session (OpenClaw compat)
#
# Aliases (OpenClaw-style -> BashClaw-style):
#   before_tool_call   -> pre_tool
#   after_tool_call    -> post_tool

# Execution strategies:
#   void      - parallel fire-and-forget, return value ignored
#   modifying - serial pipeline, each hook can modify the input JSON
#   sync      - synchronous hot-path, blocks until complete

_HOOKS_DIR=""

# Initialize hooks directory
_hooks_dir() {
  if [[ -z "$_HOOKS_DIR" ]]; then
    _HOOKS_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/hooks"
  fi
  ensure_dir "$_HOOKS_DIR"
  printf '%s' "$_HOOKS_DIR"
}

# Resolve event name aliases (OpenClaw-style -> BashClaw-style).
# Returns the canonical event name.
_hooks_resolve_alias() {
  case "$1" in
    before_tool_call) echo "pre_tool" ;;
    after_tool_call)  echo "post_tool" ;;
    *)                echo "$1" ;;
  esac
}

# Validate that an event name is one of the supported events.
_hooks_valid_event() {
  case "$1" in
    pre_message|post_message|pre_tool|post_tool|on_error|on_session_reset|\
    before_agent_start|agent_end|before_compaction|after_compaction|\
    message_received|message_sending|message_sent|session_start|\
    session_end|gateway_start|gateway_stop|tool_result_persist|\
    before_tool_call|after_tool_call)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Default strategy for each event type
_hooks_default_strategy() {
  case "$1" in
    pre_message|pre_tool|message_sending|before_compaction|before_tool_call)
      echo "modifying" ;;
    post_message|post_tool|on_error|on_session_reset|\
    agent_end|after_compaction|message_received|message_sent|session_start|\
    session_end|gateway_start|gateway_stop|tool_result_persist|after_tool_call)
      echo "void" ;;
    before_agent_start)
      echo "sync" ;;
    *)
      echo "void" ;;
  esac
}

# Register a hook for an event.
# Usage: hooks_register NAME EVENT SCRIPT_PATH [--priority N] [--strategy STR] [--source SRC]
hooks_register() {
  local name="${1:?name required}"
  local event="${2:?event required}"
  local script_path="${3:?script_path required}"
  shift 3

  require_command jq "hooks_register requires jq"

  # Resolve event aliases
  event="$(_hooks_resolve_alias "$event")"

  local priority=100
  local strategy=""
  local source_tag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority)
        priority="${2:-100}"
        shift 2
        ;;
      --strategy)
        strategy="${2:-}"
        shift 2
        ;;
      --source)
        source_tag="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ ! -f "$script_path" ]]; then
    log_error "Hook script not found: $script_path"
    return 1
  fi

  if ! _hooks_valid_event "$event"; then
    log_error "Invalid hook event: $event"
    return 1
  fi

  # Default strategy based on event type if not specified
  if [[ -z "$strategy" ]]; then
    strategy="$(_hooks_default_strategy "$event")"
  fi

  case "$strategy" in
    void|modifying|sync) ;;
    *)
      log_error "Invalid hook strategy: $strategy (use void, modifying, or sync)"
      return 1
      ;;
  esac

  local dir
  dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${dir}/${safe_name}.json"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq -nc \
    --arg name "$name" \
    --arg event "$event" \
    --arg script "$script_path" \
    --arg strategy "$strategy" \
    --arg source "$source_tag" \
    --arg ca "$now" \
    --argjson pri "$priority" \
    '{name: $name, event: $event, script: $script, enabled: true, priority: $pri, strategy: $strategy, source: $source, created_at: $ca}' \
    > "$file"

  chmod 600 "$file" 2>/dev/null || true
  log_info "Hook registered: name=$name event=$event priority=$priority strategy=$strategy"
}

# Collect all enabled hooks for an event, sorted by priority (ascending).
# Returns a newline-separated list of hook JSON file paths.
# Also collects hooks registered under aliased event names.
_hooks_collect_sorted() {
  local event="$1"
  local dir
  dir="$(_hooks_dir)"

  # Determine alias counterpart for matching
  local alias_event=""
  case "$event" in
    pre_tool) alias_event="before_tool_call" ;;
    post_tool) alias_event="after_tool_call" ;;
  esac

  # Build a list of (priority, filepath) pairs, then sort by priority
  local pairs=""
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue

    local hook_event hook_enabled hook_pri
    hook_event="$(jq -r '.event // empty' < "$f" 2>/dev/null)"
    hook_enabled="$(jq -r '.enabled // false' < "$f" 2>/dev/null)"
    hook_pri="$(jq -r '.priority // 100' < "$f" 2>/dev/null)"

    if [[ "$hook_event" != "$event" ]]; then
      if [[ -n "$alias_event" && "$hook_event" == "$alias_event" ]]; then
        : # match via alias
      else
        continue
      fi
    fi
    if [[ "$hook_enabled" != "true" ]]; then
      continue
    fi

    if [[ -z "$pairs" ]]; then
      pairs="${hook_pri} ${f}"
    else
      pairs="${pairs}
${hook_pri} ${f}"
    fi
  done

  if [[ -z "$pairs" ]]; then
    return 0
  fi

  printf '%s\n' "$pairs" | sort -n -k1 | while IFS=' ' read -r _pri path; do
    printf '%s\n' "$path"
  done
}

# Run all enabled hooks matching an event.
# Behavior depends on the event's strategy:
#   void      - run each hook in background, discard output
#   modifying - pipe JSON through each hook serially (priority order)
#   sync      - run each hook serially, block until complete
# Usage: hooks_run EVENT [INPUT_JSON]
hooks_run() {
  local event="${1:?event required}"
  local input_json="${2:-{\}}"

  # Resolve event aliases
  event="$(_hooks_resolve_alias "$event")"

  local dir
  dir="$(_hooks_dir)"
  local event_strategy
  event_strategy="$(_hooks_default_strategy "$event")"
  local strategy="$event_strategy"
  local current="$input_json"

  # Collect sorted hooks into a temp file (bash 3.2 safe)
  local sorted_file
  sorted_file="$(tmpfile "hooks_sorted")"
  _hooks_collect_sorted "$event" > "$sorted_file"

  local hook_file
  while IFS= read -r hook_file; do
    [[ -n "$hook_file" ]] || continue
    [[ -f "$hook_file" ]] || continue

    # Reset strategy to event default at top of each hook iteration
    strategy="$event_strategy"

    local hook_script hook_name hook_strategy
    hook_script="$(jq -r '.script // empty' < "$hook_file" 2>/dev/null)"
    hook_name="$(jq -r '.name // "unknown"' < "$hook_file" 2>/dev/null)"
    hook_strategy="$(jq -r '.strategy // empty' < "$hook_file" 2>/dev/null)"

    # Per-hook strategy overrides the event default for this iteration
    if [[ -n "$hook_strategy" ]]; then
      strategy="$hook_strategy"
    fi

    if [[ ! -x "$hook_script" && ! -f "$hook_script" ]]; then
      log_warn "Hook script missing: $hook_script"
      continue
    fi

    log_debug "Running hook: $hook_name for event=$event strategy=$strategy"

    case "$strategy" in
      void)
        # Fire and forget in background
        printf '%s' "$current" | bash "$hook_script" >/dev/null 2>/dev/null &
        ;;
      modifying)
        # Serial pipeline: output replaces current
        local result
        result="$(printf '%s' "$current" | bash "$hook_script" 2>/dev/null)" || {
          log_warn "Hook script failed: $hook_script"
          continue
        }
        if [[ -n "$result" ]]; then
          current="$result"
        fi
        ;;
      sync)
        # Synchronous blocking execution
        printf '%s' "$current" | bash "$hook_script" 2>/dev/null || {
          log_warn "Hook script failed: $hook_script"
          continue
        }
        ;;
    esac
  done < "$sorted_file"

  rm -f "$sorted_file"

  # For modifying strategy, return the final transformed result
  if [[ "$event_strategy" == "modifying" ]]; then
    printf '%s' "$current"
  fi
}

# Scan a directory for *.sh hook scripts and register them.
# Files should contain comment headers:
#   # hook:EVENT_NAME
#   # priority:N       (optional, default 100)
#   # strategy:STR     (optional, defaults per event)
hooks_load_dir() {
  local search_dir="${1:?directory required}"

  if [[ ! -d "$search_dir" ]]; then
    log_warn "Hooks directory not found: $search_dir"
    return 1
  fi

  local f count=0
  for f in "${search_dir}"/*.sh; do
    [[ -f "$f" ]] || continue

    # Extract event from comment header
    local event_line
    event_line="$(grep -m1 '^# hook:' "$f" 2>/dev/null || true)"
    if [[ -z "$event_line" ]]; then
      continue
    fi

    local event="${event_line#\# hook:}"
    event="$(printf '%s' "$event" | tr -d '[:space:]')"

    # Extract optional priority
    local pri_line priority=100
    pri_line="$(grep -m1 '^# priority:' "$f" 2>/dev/null || true)"
    if [[ -n "$pri_line" ]]; then
      priority="${pri_line#\# priority:}"
      priority="$(printf '%s' "$priority" | tr -d '[:space:]')"
    fi

    # Extract optional strategy
    local strat_line strategy=""
    strat_line="$(grep -m1 '^# strategy:' "$f" 2>/dev/null || true)"
    if [[ -n "$strat_line" ]]; then
      strategy="${strat_line#\# strategy:}"
      strategy="$(printf '%s' "$strategy" | tr -d '[:space:]')"
    fi

    local name
    name="$(basename "$f" .sh)"

    local extra_args=""
    if [[ -n "$strategy" ]]; then
      hooks_register "$name" "$event" "$f" --priority "$priority" --strategy "$strategy" && count=$((count + 1))
    else
      hooks_register "$name" "$event" "$f" --priority "$priority" && count=$((count + 1))
    fi
  done

  log_info "Loaded $count hooks from $search_dir"
}

# List all registered hooks with their status.
hooks_list() {
  require_command jq "hooks_list requires jq"

  local dir
  dir="$(_hooks_dir)"
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

  # Sort by priority
  printf '%s' "$result" | jq 'sort_by(.priority)'
}

# List hooks filtered by event name.
hooks_list_by_event() {
  local event="${1:?event required}"

  require_command jq "hooks_list_by_event requires jq"

  local all
  all="$(hooks_list)"
  printf '%s' "$all" | jq --arg e "$event" '[.[] | select(.event == $e)]'
}

# Enable a hook by name.
hooks_enable() {
  local name="${1:?name required}"

  require_command jq "hooks_enable requires jq"

  local dir
  dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${dir}/${safe_name}.json"

  if [[ ! -f "$file" ]]; then
    log_error "Hook not found: $name"
    return 1
  fi

  local updated
  updated="$(jq '.enabled = true' < "$file")"
  printf '%s\n' "$updated" > "$file"
  log_info "Hook enabled: $name"
}

# Disable a hook by name.
hooks_disable() {
  local name="${1:?name required}"

  require_command jq "hooks_disable requires jq"

  local dir
  dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${dir}/${safe_name}.json"

  if [[ ! -f "$file" ]]; then
    log_error "Hook not found: $name"
    return 1
  fi

  local updated
  updated="$(jq '.enabled = false' < "$file")"
  printf '%s\n' "$updated" > "$file"
  log_info "Hook disabled: $name"
}

# Remove a hook by name entirely.
hooks_remove() {
  local name="${1:?name required}"

  local dir
  dir="$(_hooks_dir)"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${dir}/${safe_name}.json"

  if [[ ! -f "$file" ]]; then
    log_error "Hook not found: $name"
    return 1
  fi

  rm -f "$file"
  log_info "Hook removed: $name"
}

# Count hooks registered for a specific event.
hooks_count() {
  local event="${1:?event required}"

  local dir
  dir="$(_hooks_dir)"
  local count=0
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local hook_event
    hook_event="$(jq -r '.event // empty' < "$f" 2>/dev/null)"
    if [[ "$hook_event" == "$event" ]]; then
      count=$((count + 1))
    fi
  done

  printf '%d' "$count"
}
