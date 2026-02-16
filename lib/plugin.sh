#!/usr/bin/env bash
# Plugin system for bashclaw
# Discovers, loads, and registers extension plugins from multiple sources.
# Compatible with bash 3.2+ (no associative arrays, no global declares, no mapfile)

# Plugin registry storage (flat-file based for bash 3.2 compat)
_PLUGIN_REGISTRY_DIR=""

_plugin_registry_dir() {
  if [[ -z "$_PLUGIN_REGISTRY_DIR" ]]; then
    _PLUGIN_REGISTRY_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/plugins"
  fi
  ensure_dir "$_PLUGIN_REGISTRY_DIR"
  ensure_dir "$_PLUGIN_REGISTRY_DIR/registry"
  ensure_dir "$_PLUGIN_REGISTRY_DIR/tools"
  ensure_dir "$_PLUGIN_REGISTRY_DIR/hooks"
  ensure_dir "$_PLUGIN_REGISTRY_DIR/commands"
  ensure_dir "$_PLUGIN_REGISTRY_DIR/providers"
  printf '%s' "$_PLUGIN_REGISTRY_DIR"
}

# Discover plugins from 4 source directories:
#   1. Bundled: ${BASHCLAW_ROOT}/extensions/
#   2. Global: ~/.bashclaw/extensions/
#   3. Workspace: .bashclaw/extensions/ (relative to cwd)
#   4. Config: plugins.load.paths (array of custom paths)
# Outputs JSON array of discovered plugin manifests.
plugin_discover() {
  require_command jq "plugin_discover requires jq"

  local ndjson=""
  local search_dirs=""
  local bashclaw_root="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  # Source 1: bundled
  search_dirs="${bashclaw_root}/extensions"
  # Source 2: global user directory
  search_dirs="${search_dirs} ${HOME}/.bashclaw/extensions"
  # Source 3: workspace-local
  search_dirs="${search_dirs} $(pwd)/.bashclaw/extensions"

  # Source 4: config-defined paths
  local extra_paths
  extra_paths="$(config_get_raw '.plugins.load.paths // []' 2>/dev/null)"
  if [[ -n "$extra_paths" && "$extra_paths" != "null" && "$extra_paths" != "[]" ]]; then
    local path_count
    path_count="$(printf '%s' "$extra_paths" | jq 'length')"
    local idx=0
    while [ "$idx" -lt "$path_count" ]; do
      local p
      p="$(printf '%s' "$extra_paths" | jq -r ".[$idx]")"
      search_dirs="${search_dirs} ${p}"
      idx=$((idx + 1))
    done
  fi

  local d
  for d in $search_dirs; do
    [[ -d "$d" ]] || continue

    local manifest_file
    for manifest_file in "${d}"/*/bashclaw.plugin.json; do
      [[ -f "$manifest_file" ]] || continue

      if ! jq empty < "$manifest_file" 2>/dev/null; then
        log_warn "Invalid plugin manifest: $manifest_file"
        continue
      fi

      local plugin_dir
      plugin_dir="$(dirname "$manifest_file")"
      ndjson="${ndjson}$(jq -nc \
        --arg dir "$plugin_dir" \
        --slurpfile manifest "$manifest_file" \
        '$manifest[0] + {_dir: $dir}')"$'\n'
    done
  done

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s '.'
  else
    printf '[]'
  fi
}

# Load a plugin by sourcing its entry script.
# The entry script is expected to call plugin_register_*() functions.
# Usage: plugin_load PLUGIN_DIR
plugin_load() {
  local plugin_dir="${1:?plugin directory required}"

  local manifest="${plugin_dir}/bashclaw.plugin.json"
  if [[ ! -f "$manifest" ]]; then
    log_error "Plugin manifest not found: $manifest"
    return 1
  fi

  require_command jq "plugin_load requires jq"

  local plugin_id
  plugin_id="$(jq -r '.id // empty' < "$manifest")"
  if [[ -z "$plugin_id" ]]; then
    log_error "Plugin manifest missing 'id' field: $manifest"
    return 1
  fi

  if ! plugin_is_enabled "$plugin_id"; then
    log_debug "Plugin disabled, skipping: $plugin_id"
    return 0
  fi

  # Find entry script: look for init.sh or <id>.sh
  local entry_script=""
  if [[ -f "${plugin_dir}/init.sh" ]]; then
    entry_script="${plugin_dir}/init.sh"
  elif [[ -f "${plugin_dir}/${plugin_id}.sh" ]]; then
    entry_script="${plugin_dir}/${plugin_id}.sh"
  fi

  if [[ -z "$entry_script" ]]; then
    log_warn "No entry script found for plugin: $plugin_id"
    return 1
  fi

  # Record plugin as loaded
  local reg_dir
  reg_dir="$(_plugin_registry_dir)/registry"
  jq -nc \
    --arg id "$plugin_id" \
    --arg dir "$plugin_dir" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --slurpfile m "$manifest" \
    '{id: $id, dir: $dir, loaded_at: $ts, manifest: $m[0]}' \
    > "${reg_dir}/${plugin_id}.json"

  # Export current plugin id for register calls inside the entry script
  BASHCLAW_CURRENT_PLUGIN="$plugin_id"
  # shellcheck disable=SC1090
  source "$entry_script"
  BASHCLAW_CURRENT_PLUGIN=""

  log_info "Plugin loaded: $plugin_id"
}

# Register a plugin component in the registry.
# Usage: plugin_register PLUGIN_ID TYPE HANDLER
# TYPE: tool, hook, channel, command, provider
plugin_register() {
  local plugin_id="${1:?plugin_id required}"
  local type="${2:?type required}"
  local handler="${3:?handler required}"

  require_command jq "plugin_register requires jq"

  case "$type" in
    tool|hook|channel|command|provider) ;;
    *)
      log_error "Invalid plugin type: $type"
      return 1
      ;;
  esac

  local reg_dir
  reg_dir="$(_plugin_registry_dir)/registry"
  local reg_file="${reg_dir}/${plugin_id}.json"
  if [[ -f "$reg_file" ]]; then
    local updated
    updated="$(jq --arg t "$type" --arg h "$handler" \
      '.registrations = (.registrations // []) + [{type: $t, handler: $h}]' \
      < "$reg_file")"
    printf '%s\n' "$updated" > "$reg_file"
  fi

  log_debug "Plugin registered: id=$plugin_id type=$type"
}

# Check if a plugin is enabled based on allow/deny lists.
# Returns 0 if enabled, 1 if disabled.
plugin_is_enabled() {
  local plugin_id="${1:?plugin_id required}"

  require_command jq "plugin_is_enabled requires jq"

  # Check explicit disable in entries
  local explicit
  explicit="$(config_get ".plugins.entries.${plugin_id}.enabled" "")"
  if [[ "$explicit" == "false" ]]; then
    return 1
  fi

  # Check deny list
  local deny_list
  deny_list="$(config_get_raw '.plugins.deny // []' 2>/dev/null)"
  if [[ -n "$deny_list" && "$deny_list" != "[]" ]]; then
    local in_deny
    in_deny="$(printf '%s' "$deny_list" | jq --arg id "$plugin_id" 'map(select(. == $id)) | length')"
    if [[ "$in_deny" -gt 0 ]]; then
      return 1
    fi
  fi

  # Check allow list (if non-empty, only listed plugins are enabled)
  local allow_list
  allow_list="$(config_get_raw '.plugins.allow // []' 2>/dev/null)"
  if [[ -n "$allow_list" && "$allow_list" != "[]" ]]; then
    local in_allow
    in_allow="$(printf '%s' "$allow_list" | jq --arg id "$plugin_id" 'map(select(. == $id)) | length')"
    if [[ "$in_allow" -eq 0 ]]; then
      return 1
    fi
  fi

  return 0
}

# List all discovered/loaded plugins with status.
# Returns JSON array.
plugin_list() {
  require_command jq "plugin_list requires jq"

  local reg_dir
  reg_dir="$(_plugin_registry_dir)/registry"
  local ndjson=""
  local f

  for f in "${reg_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(jq '{id: .id, dir: .dir, loaded_at: .loaded_at, registrations: (.registrations // [])}' < "$f" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
      ndjson="${ndjson}${entry}"$'\n'
    fi
  done

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s '.'
  else
    printf '[]'
  fi
}

# Register a tool provided by a plugin.
# Usage: plugin_register_tool NAME DESCRIPTION PARAMETERS_JSON HANDLER_SCRIPT
plugin_register_tool() {
  local name="${1:?tool name required}"
  local description="${2:?description required}"
  local parameters_json="${3:?parameters JSON required}"
  local handler_script="${4:?handler script required}"

  require_command jq "plugin_register_tool requires jq"

  local plugin_id="${BASHCLAW_CURRENT_PLUGIN:-unknown}"
  local tools_dir
  tools_dir="$(_plugin_registry_dir)/tools"

  local safe_name
  safe_name="$(sanitize_key "$name")"

  jq -nc \
    --arg name "$name" \
    --arg desc "$description" \
    --argjson params "$parameters_json" \
    --arg handler "$handler_script" \
    --arg plugin "$plugin_id" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{name: $name, description: $desc, parameters: $params, handler: $handler, plugin: $plugin, registered_at: $ts}' \
    > "${tools_dir}/${safe_name}.json"

  plugin_register "$plugin_id" "tool" "$handler_script"
  log_debug "Plugin tool registered: $name (plugin=$plugin_id)"
}

# Register a hook provided by a plugin.
# Usage: plugin_register_hook EVENT HANDLER_SCRIPT [PRIORITY]
plugin_register_hook() {
  local event="${1:?event required}"
  local handler_script="${2:?handler script required}"
  local priority="${3:-100}"

  local plugin_id="${BASHCLAW_CURRENT_PLUGIN:-unknown}"

  # Delegate to the hooks system with plugin source tagging
  hooks_register "plugin_${plugin_id}_${event}" "$event" "$handler_script" \
    --priority "$priority" --source "plugin:${plugin_id}"

  plugin_register "$plugin_id" "hook" "$handler_script"
  log_debug "Plugin hook registered: event=$event priority=$priority (plugin=$plugin_id)"
}

# Register a bypass-LLM command provided by a plugin.
# Usage: plugin_register_command NAME DESCRIPTION HANDLER_SCRIPT
plugin_register_command() {
  local name="${1:?command name required}"
  local description="${2:?description required}"
  local handler_script="${3:?handler script required}"

  require_command jq "plugin_register_command requires jq"

  local plugin_id="${BASHCLAW_CURRENT_PLUGIN:-unknown}"
  local cmds_dir
  cmds_dir="$(_plugin_registry_dir)/commands"

  local safe_name
  safe_name="$(sanitize_key "$name")"

  jq -nc \
    --arg name "$name" \
    --arg desc "$description" \
    --arg handler "$handler_script" \
    --arg plugin "$plugin_id" \
    '{name: $name, description: $desc, handler: $handler, plugin: $plugin}' \
    > "${cmds_dir}/${safe_name}.json"

  plugin_register "$plugin_id" "command" "$handler_script"
  log_debug "Plugin command registered: $name (plugin=$plugin_id)"
}

# Register an LLM provider plugin.
# Usage: plugin_register_provider ID LABEL MODELS_JSON AUTH_JSON
plugin_register_provider() {
  local id="${1:?provider id required}"
  local label="${2:?label required}"
  local models_json="${3:?models JSON required}"
  local auth_json="${4:-{\}}"

  require_command jq "plugin_register_provider requires jq"

  local plugin_id="${BASHCLAW_CURRENT_PLUGIN:-unknown}"
  local providers_dir
  providers_dir="$(_plugin_registry_dir)/providers"

  local safe_id
  safe_id="$(sanitize_key "$id")"

  jq -nc \
    --arg id "$id" \
    --arg label "$label" \
    --argjson models "$models_json" \
    --argjson auth "$auth_json" \
    --arg plugin "$plugin_id" \
    '{id: $id, label: $label, models: $models, auth: $auth, plugin: $plugin}' \
    > "${providers_dir}/${safe_id}.json"

  plugin_register "$plugin_id" "provider" "$id"
  log_debug "Plugin provider registered: $id (plugin=$plugin_id)"
}

# Load all discovered and enabled plugins.
plugin_load_all() {
  local plugins_json
  plugins_json="$(plugin_discover)"

  local count
  count="$(printf '%s' "$plugins_json" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    log_debug "No plugins discovered"
    return 0
  fi

  local loaded=0 idx=0
  while [ "$idx" -lt "$count" ]; do
    local plugin_dir
    plugin_dir="$(printf '%s' "$plugins_json" | jq -r ".[$idx]._dir")"
    if plugin_load "$plugin_dir"; then
      loaded=$((loaded + 1))
    fi
    idx=$((idx + 1))
  done

  log_info "Plugins loaded: $loaded of $count discovered"
}

# Look up a plugin-registered tool handler by name.
# Returns the handler script path, or empty if not found.
plugin_tool_handler() {
  local name="${1:?tool name required}"

  local tools_dir
  tools_dir="$(_plugin_registry_dir)/tools"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${tools_dir}/${safe_name}.json"

  if [[ -f "$file" ]]; then
    jq -r '.handler // empty' < "$file" 2>/dev/null
  fi
}

# Look up a plugin-registered command handler by name.
# Returns the handler script path, or empty if not found.
plugin_command_handler() {
  local name="${1:?command name required}"

  local cmds_dir
  cmds_dir="$(_plugin_registry_dir)/commands"
  local safe_name
  safe_name="$(sanitize_key "$name")"
  local file="${cmds_dir}/${safe_name}.json"

  if [[ -f "$file" ]]; then
    jq -r '.handler // empty' < "$file" 2>/dev/null
  fi
}
