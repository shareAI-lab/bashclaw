#!/usr/bin/env bash
# Configuration management for bashclaw (jq-based)
# Manages heartbeat, dmScope, tools policy, channel policies

_CONFIG_CACHE=""
_CONFIG_PATH=""
_CONFIG_MTIME=""

config_path() {
  if [[ -n "${BASHCLAW_CONFIG:-}" ]]; then
    printf '%s' "$BASHCLAW_CONFIG"
    return
  fi
  printf '%s/bashclaw.json' "${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}"
}

config_set_path() {
  _CONFIG_PATH="$1"
}

config_load() {
  local path
  path="$(_config_resolve_path)"
  if [[ ! -f "$path" ]]; then
    _CONFIG_CACHE="{}"
    _CONFIG_MTIME=""
    return 0
  fi
  _CONFIG_CACHE="$(cat "$path")"
  if ! printf '%s' "$_CONFIG_CACHE" | jq empty 2>/dev/null; then
    log_error "Invalid JSON in config: $path"
    _CONFIG_CACHE="{}"
    _CONFIG_MTIME=""
    return 1
  fi
  # Track mtime for staleness check
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _CONFIG_MTIME="$(stat -f%m "$path" 2>/dev/null)" || _CONFIG_MTIME=""
  else
    _CONFIG_MTIME="$(stat -c%Y "$path" 2>/dev/null)" || _CONFIG_MTIME=""
  fi
}

config_env_substitute() {
  local input="$1"
  local result="$input"
  local var_pattern='\$\{([A-Za-z_][A-Za-z_0-9]*)\}'
  while [[ "$result" =~ $var_pattern ]]; do
    local var_name="${BASH_REMATCH[1]}"
    local var_value="${!var_name:-}"
    result="${result/\$\{${var_name}\}/${var_value}}"
  done
  printf '%s' "$result"
}

config_get() {
  local filter="$1"
  local default="${2:-}"
  _config_ensure_loaded
  local value
  value="$(printf '%s' "$_CONFIG_CACHE" | jq -r "$filter // empty" 2>/dev/null)"
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$(config_env_substitute "$value")"
  fi
}

config_get_raw() {
  local filter="$1"
  _config_ensure_loaded
  printf '%s' "$_CONFIG_CACHE" | jq "$filter" 2>/dev/null
}

config_set() {
  local filter="$1"
  local value="$2"
  _config_ensure_loaded
  local path
  path="$(_config_resolve_path)"
  _CONFIG_CACHE="$(printf '%s' "$_CONFIG_CACHE" | jq "$filter = $value")"
  ensure_dir "$(dirname "$path")"
  printf '%s\n' "$_CONFIG_CACHE" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

config_validate() {
  local path
  path="$(_config_resolve_path)"
  if [[ ! -f "$path" ]]; then
    log_warn "Config file not found: $path"
    return 1
  fi

  local content
  content="$(cat "$path")"
  if ! printf '%s' "$content" | jq empty 2>/dev/null; then
    log_error "Config is not valid JSON: $path"
    return 1
  fi

  local errors=0

  # Validate gateway.port
  local port
  port="$(printf '%s' "$content" | jq -r '.gateway.port // empty' 2>/dev/null)"
  if [[ -n "$port" ]]; then
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      log_error "Invalid gateway port: $port (must be 1-65535)"
      errors=$((errors + 1))
    fi
  fi

  # Validate agents structure
  local agents_type
  agents_type="$(printf '%s' "$content" | jq -r '.agents | type' 2>/dev/null)"
  if [[ "$agents_type" == "object" ]]; then
    local list_type
    list_type="$(printf '%s' "$content" | jq -r '.agents.list | type' 2>/dev/null)"
    if [[ "$list_type" != "null" && "$list_type" != "array" ]]; then
      log_error "agents.list must be an array"
      errors=$((errors + 1))
    fi

    # Validate each agent in list has required 'id' field
    local agent_errors
    agent_errors="$(printf '%s' "$content" | jq -r '
      [(.agents.list // [])[] | select(.id == null or .id == "")] | length
    ' 2>/dev/null)"
    if [[ "$agent_errors" != "0" && -n "$agent_errors" ]]; then
      log_error "agents.list contains entries without 'id' field"
      errors=$((errors + 1))
    fi

    # Validate agent model references
    local invalid_models
    invalid_models="$(printf '%s' "$content" | jq -r '
      [(.agents.list // [])[] | select(.model != null and (.model | type) != "string")] | length
    ' 2>/dev/null)"
    if [[ "$invalid_models" != "0" && -n "$invalid_models" ]]; then
      log_error "agents.list contains entries with non-string 'model' field"
      errors=$((errors + 1))
    fi
  fi

  # Validate channels structure
  local channels_type
  channels_type="$(printf '%s' "$content" | jq -r '.channels | type' 2>/dev/null)"
  if [[ "$channels_type" != "null" && "$channels_type" != "object" ]]; then
    log_error "channels must be an object"
    errors=$((errors + 1))
  fi

  # Validate session config
  local idle_reset
  idle_reset="$(printf '%s' "$content" | jq -r '.session.idleResetMinutes // empty' 2>/dev/null)"
  if [[ -n "$idle_reset" ]]; then
    if ! [[ "$idle_reset" =~ ^[0-9]+$ ]]; then
      log_error "session.idleResetMinutes must be an integer"
      errors=$((errors + 1))
    fi
  fi

  local max_history
  max_history="$(printf '%s' "$content" | jq -r '.session.maxHistory // empty' 2>/dev/null)"
  if [[ -n "$max_history" ]]; then
    if ! [[ "$max_history" =~ ^[0-9]+$ ]]; then
      log_error "session.maxHistory must be an integer"
      errors=$((errors + 1))
    fi
  fi

  # Validate dmScope enum
  local dm_scope
  dm_scope="$(printf '%s' "$content" | jq -r '.session.dmScope // empty' 2>/dev/null)"
  if [[ -n "$dm_scope" ]]; then
    case "$dm_scope" in
      per-sender|per-channel-peer|per-peer|per-account-channel-peer|per-channel|main|global) ;;
      *)
        log_error "Invalid session.dmScope: $dm_scope (valid: per-sender, per-channel-peer, per-peer, per-account-channel-peer, per-channel, main, global)"
        errors=$((errors + 1))
        ;;
    esac
  fi

  # Validate bindings is an array
  local bindings_type
  bindings_type="$(printf '%s' "$content" | jq -r '.bindings | type' 2>/dev/null)"
  if [[ "$bindings_type" != "null" && "$bindings_type" != "array" ]]; then
    log_error "bindings must be an array"
    errors=$((errors + 1))
  fi

  # Validate identityLinks is an array
  local links_type
  links_type="$(printf '%s' "$content" | jq -r '.identityLinks | type' 2>/dev/null)"
  if [[ "$links_type" != "null" && "$links_type" != "array" ]]; then
    log_error "identityLinks must be an array"
    errors=$((errors + 1))
  fi

  # Validate security structure
  local security_type
  security_type="$(printf '%s' "$content" | jq -r '.security | type' 2>/dev/null)"
  if [[ "$security_type" != "null" && "$security_type" != "object" ]]; then
    log_error "security must be an object"
    errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    log_error "Config validation failed with $errors error(s): $path"
    return 1
  fi

  log_debug "Config validation passed: $path"
  return 0
}

config_init_default() {
  local path
  path="$(_config_resolve_path)"
  if [[ -f "$path" ]]; then
    log_warn "Config already exists: $path"
    return 1
  fi

  local model="${MODEL_ID:-claude-opus-4-6}"
  ensure_dir "$(dirname "$path")"

  cat > "$path" <<ENDJSON
{
  "agents": {
    "defaultId": "main",
    "defaults": {
      "model": "${model}",
      "maxTurns": 50,
      "contextTokens": 200000,
      "dmScope": "per-channel-peer",
      "queueMode": "followup",
      "queueDebounceMs": 0,
      "fallbackModels": [],
      "engine": "auto",
      "tools": {
        "allow": [],
        "deny": []
      },
      "compaction": {
        "mode": "summary",
        "threshold": 0.8,
        "reserveTokens": 50000,
        "maxHistoryShare": 0.5
      },
      "heartbeat": {
        "enabled": false,
        "interval": "30m",
        "activeHours": {
          "start": "08:00",
          "end": "22:00"
        },
        "timezone": "local",
        "showAlerts": true
      }
    },
    "list": []
  },
  "channels": {
    "defaults": {
      "dmPolicy": {
        "policy": "open",
        "allowFrom": []
      },
      "groupPolicy": {
        "policy": "open"
      },
      "debounceMs": 0,
      "threadAware": false,
      "capabilities": {
        "polls": false,
        "reactions": false,
        "edit": false
      },
      "outbound": {
        "textChunkLimit": 4096
      }
    }
  },
  "bindings": [],
  "identityLinks": [],
  "gateway": {
    "port": 18789,
    "auth": {}
  },
  "session": {
    "dmScope": "per-channel-peer",
    "idleResetMinutes": 30,
    "maxHistory": 200
  },
  "security": {
    "elevatedUsers": [],
    "commands": {},
    "userRoles": {}
  },
  "meta": {
    "lastTouchedVersion": "${BASHCLAW_VERSION:-1.0.0}",
    "lastTouchedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  }
}
ENDJSON

  chmod 600 "$path" 2>/dev/null || true
  log_info "Created default config: $path"

  # Initialize workspace with template bootstrap files
  if declare -f workspace_init &>/dev/null; then
    workspace_init
  fi
}

config_backup() {
  local path
  path="$(_config_resolve_path)"
  if [[ ! -f "$path" ]]; then
    return 0
  fi

  local dir
  dir="$(dirname "$path")"
  local base
  base="$(basename "$path")"

  local i
  for i in 4 3 2 1; do
    local src="${dir}/${base}.bak.${i}"
    local dst="${dir}/${base}.bak.$((i + 1))"
    [[ -f "$src" ]] && mv "$src" "$dst"
  done

  cp "$path" "${dir}/${base}.bak.1"
  log_debug "Config backup created"
}

config_agent_get() {
  local agent_id="$1"
  local field="$2"
  local default="${3:-}"
  _config_ensure_loaded

  local value
  value="$(printf '%s' "$_CONFIG_CACHE" | jq -r \
    --arg id "$agent_id" --arg f "$field" \
    '(.agents.list // [] | map(select(.id == $id)) | .[0] | .[$f] // empty) // (.agents.defaults[$f] // empty)' \
    2>/dev/null)"

  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$(config_env_substitute "$value")"
  fi
}

# Get a nested agent config field using a jq path expression
config_agent_get_raw() {
  local agent_id="$1"
  local jq_path="$2"
  _config_ensure_loaded

  local value
  value="$(printf '%s' "$_CONFIG_CACHE" | jq -r \
    --arg id "$agent_id" \
    "(.agents.list // [] | map(select(.id == \$id)) | .[0] | ${jq_path} // null) // (.agents.defaults | ${jq_path} // null)" \
    2>/dev/null)"

  printf '%s' "$value"
}

config_channel_get() {
  local channel_id="$1"
  local field="$2"
  local default="${3:-}"
  _config_ensure_loaded

  local value
  value="$(printf '%s' "$_CONFIG_CACHE" | jq -r \
    --arg ch "$channel_id" --arg f "$field" \
    '.channels[$ch][$f] // .channels.defaults[$f] // empty' \
    2>/dev/null)"

  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$(config_env_substitute "$value")"
  fi
}

# Get raw channel config (for nested objects)
config_channel_get_raw() {
  local channel_id="$1"
  local jq_path="$2"
  _config_ensure_loaded

  local value
  value="$(printf '%s' "$_CONFIG_CACHE" | jq \
    --arg ch "$channel_id" \
    ".channels[\$ch] | ${jq_path} // (.channels.defaults | ${jq_path} // null)" \
    2>/dev/null)"

  printf '%s' "$value"
}

config_reload() {
  _CONFIG_CACHE=""
  _CONFIG_MTIME=""
  config_load
}

# -- internal helpers --

_config_resolve_path() {
  if [[ -n "$_CONFIG_PATH" ]]; then
    printf '%s' "$_CONFIG_PATH"
  else
    config_path
  fi
}

_config_ensure_loaded() {
  if [[ -z "$_CONFIG_CACHE" ]]; then
    config_load
    return
  fi
  # Check if config file has been modified
  local path
  path="$(_config_resolve_path)"
  if [[ -f "$path" ]]; then
    local current_mtime
    if [[ "$(uname -s)" == "Darwin" ]]; then
      current_mtime="$(stat -f%m "$path" 2>/dev/null)" || current_mtime=""
    else
      current_mtime="$(stat -c%Y "$path" 2>/dev/null)" || current_mtime=""
    fi
    if [[ -n "$current_mtime" && "$current_mtime" != "$_CONFIG_MTIME" ]]; then
      config_load
    fi
  fi
}
