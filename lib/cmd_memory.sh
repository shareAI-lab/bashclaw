#!/usr/bin/env bash
# Memory management command for bashclaw

cmd_memory() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    list)    _cmd_memory_list "$@" ;;
    search)  _cmd_memory_search "$@" ;;
    get)     _cmd_memory_get "$@" ;;
    set)     _cmd_memory_set "$@" ;;
    delete)  _cmd_memory_delete "$@" ;;
    export)  _cmd_memory_export "$@" ;;
    import)  _cmd_memory_import "$@" ;;
    compact) _cmd_memory_compact ;;
    stats)   _cmd_memory_stats ;;
    -h|--help|help|"") _cmd_memory_usage ;;
    *) log_error "Unknown memory subcommand: $subcommand"; _cmd_memory_usage; return 1 ;;
  esac
}

_cmd_memory_list() {
  local limit=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "memory list requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  if [[ ! -d "$mem_dir" ]]; then
    printf 'No memory entries found.\n'
    return 0
  fi

  local count=0
  local f
  for f in "${mem_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    if (( limit > 0 && count >= limit )); then
      break
    fi
    local key value updated_at
    key="$(jq -r '.key // "?"' < "$f" 2>/dev/null)"
    value="$(jq -r '.value // "" | .[0:80]' < "$f" 2>/dev/null)"
    updated_at="$(jq -r '.updated_at // "?"' < "$f" 2>/dev/null)"
    printf '  %-30s  %s  (%s)\n' "$key" "$value" "$updated_at"
    count=$((count + 1))
  done

  if (( count == 0 )); then
    printf 'No memory entries found.\n'
  else
    printf '\nTotal: %d entries\n' "$count"
  fi
}

_cmd_memory_search() {
  local query="${1:-}"

  if [[ -z "$query" ]]; then
    log_error "Search query is required"
    printf 'Usage: bashclaw memory search QUERY\n'
    return 1
  fi

  require_command jq "memory search requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  if [[ ! -d "$mem_dir" ]]; then
    printf 'No memory entries found.\n'
    return 0
  fi

  local count=0
  local f
  for f in "${mem_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    if grep -qi "$query" "$f" 2>/dev/null; then
      local key value
      key="$(jq -r '.key // "?"' < "$f" 2>/dev/null)"
      value="$(jq -r '.value // "" | .[0:80]' < "$f" 2>/dev/null)"
      printf '  %-30s  %s\n' "$key" "$value"
      count=$((count + 1))
    fi
  done

  if (( count == 0 )); then
    printf 'No matches found for: %s\n' "$query"
  else
    printf '\nFound: %d matches\n' "$count"
  fi
}

_cmd_memory_get() {
  local key="${1:-}"

  if [[ -z "$key" ]]; then
    log_error "Key is required"
    printf 'Usage: bashclaw memory get KEY\n'
    return 1
  fi

  require_command jq "memory get requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${mem_dir}/${safe_key}.json"

  if [[ ! -f "$file" ]]; then
    printf 'Key not found: %s\n' "$key"
    return 1
  fi

  jq '.' < "$file"
}

_cmd_memory_set() {
  local key="${1:-}"
  local value="${2:-}"
  local tags=""

  shift 2 2>/dev/null || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags) tags="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$key" || -z "$value" ]]; then
    log_error "Key and value are required"
    printf 'Usage: bashclaw memory set KEY VALUE [--tags tag1,tag2]\n'
    return 1
  fi

  require_command jq "memory set requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  ensure_dir "$mem_dir"

  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${mem_dir}/${safe_key}.json"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if [[ -n "$tags" ]]; then
    local tags_json
    tags_json="$(printf '%s' "$tags" | tr ',' '\n' | jq -R '.' | jq -s '.')"
    jq -nc --arg k "$key" --arg v "$value" --arg t "$ts" --argjson tags "$tags_json" \
      '{"key": $k, "value": $v, "tags": $tags, "updated_at": $t}' > "$file"
  else
    jq -nc --arg k "$key" --arg v "$value" --arg t "$ts" \
      '{"key": $k, "value": $v, "updated_at": $t}' > "$file"
  fi

  printf 'Stored: %s\n' "$key"
}

_cmd_memory_delete() {
  local key="${1:-}"

  if [[ -z "$key" ]]; then
    log_error "Key is required"
    printf 'Usage: bashclaw memory delete KEY\n'
    return 1
  fi

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  local safe_key
  safe_key="$(sanitize_key "$key")"
  local file="${mem_dir}/${safe_key}.json"

  if [[ -f "$file" ]]; then
    rm -f "$file"
    printf 'Deleted: %s\n' "$key"
  else
    printf 'Key not found: %s\n' "$key"
    return 1
  fi
}

_cmd_memory_export() {
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|-o) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "memory export requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  if [[ ! -d "$mem_dir" ]]; then
    printf '[]\n'
    return 0
  fi

  local ndjson=""
  local f
  for f in "${mem_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(cat "$f" 2>/dev/null)" || continue
    ndjson="${ndjson}${entry}"$'\n'
  done

  local result
  if [[ -n "$ndjson" ]]; then
    result="$(printf '%s' "$ndjson" | jq -s '.')"
  else
    result="[]"
  fi

  if [[ -n "$output" ]]; then
    printf '%s\n' "$result" | jq '.' > "$output"
    printf 'Exported %s entries to %s\n' "$(printf '%s' "$result" | jq 'length')" "$output"
  else
    printf '%s\n' "$result" | jq '.'
  fi
}

_cmd_memory_import() {
  local file="${1:-}"

  if [[ -z "$file" ]]; then
    log_error "File path is required"
    printf 'Usage: bashclaw memory import FILE\n'
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    return 1
  fi

  require_command jq "memory import requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  ensure_dir "$mem_dir"

  local count=0
  local entries
  entries="$(jq -c '.[]' < "$file" 2>/dev/null)" || {
    log_error "Invalid JSON file"
    return 1
  }

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local key
    key="$(printf '%s' "$entry" | jq -r '.key // empty')"
    if [[ -z "$key" ]]; then
      continue
    fi
    local safe_key
    safe_key="$(sanitize_key "$key")"
    printf '%s\n' "$entry" > "${mem_dir}/${safe_key}.json"
    count=$((count + 1))
  done <<< "$entries"

  printf 'Imported %d entries.\n' "$count"
}

_cmd_memory_compact() {
  require_command jq "memory compact requires jq"

  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  if [[ ! -d "$mem_dir" ]]; then
    printf 'No memory directory found.\n'
    return 0
  fi

  local removed=0
  local f
  for f in "${mem_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    if ! jq empty < "$f" 2>/dev/null; then
      rm -f "$f"
      removed=$((removed + 1))
    fi
  done

  printf 'Compacted: removed %d invalid entries.\n' "$removed"
}

_cmd_memory_stats() {
  local mem_dir="${BASHCLAW_STATE_DIR:?}/memory"
  if [[ ! -d "$mem_dir" ]]; then
    printf 'Count:      0\n'
    printf 'Total size: 0 bytes\n'
    return 0
  fi

  local count=0
  local total_size=0
  local f
  for f in "${mem_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    count=$((count + 1))
    local sz
    sz="$(file_size_bytes "$f")"
    total_size=$((total_size + sz))
  done

  printf 'Count:      %d\n' "$count"
  printf 'Total size: %d bytes\n' "$total_size"
  printf 'Directory:  %s\n' "$mem_dir"
}

_cmd_memory_usage() {
  cat <<'EOF'
Usage: bashclaw memory <subcommand> [options]

Subcommands:
  list [--limit N]             List memory entries
  search QUERY                 Search entries by keyword
  get KEY                      Get a memory entry
  set KEY VALUE [--tags t1,t2] Store a memory entry
  delete KEY                   Delete a memory entry
  export [--output FILE]       Export all entries as JSON
  import FILE                  Import entries from JSON file
  compact                      Remove invalid entries
  stats                        Show memory statistics

Examples:
  bashclaw memory set greeting "Hello World" --tags common,test
  bashclaw memory get greeting
  bashclaw memory list --limit 10
  bashclaw memory search hello
  bashclaw memory export --output backup.json
  bashclaw memory import backup.json
EOF
}
