#!/usr/bin/env bash
# Long-term memory module for bashclaw
# File-based key-value store with tags, sources, and access tracking
# Includes workspace memory, daily logs, BM25-style search

# Returns the memory storage directory
memory_dir() {
  local dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/memory"
  ensure_dir "$dir"
  printf '%s' "$dir"
}

# Sanitize a key for safe use as a filename
_memory_key_to_filename() {
  sanitize_key "$1"
}

# ---- Workspace Memory ----

# Ensure the agent workspace memory directory exists
memory_ensure_workspace() {
  local agent_id="${1:?agent_id required}"

  local workspace="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}/memory"
  ensure_dir "$workspace"

  # Initialize MEMORY.md if absent
  local memory_md="${BASHCLAW_STATE_DIR}/agents/${agent_id}/MEMORY.md"
  if [[ ! -f "$memory_md" ]]; then
    printf '# Memory\n\nCurated memory for agent: %s\n' "$agent_id" > "$memory_md"
    log_debug "Initialized MEMORY.md for agent=$agent_id"
  fi

  printf '%s' "$workspace"
}

# Append content to today's daily log
memory_append_daily() {
  local agent_id="${1:?agent_id required}"
  local content="${2:?content required}"

  local workspace
  workspace="$(memory_ensure_workspace "$agent_id")"

  local today
  today="$(date -u '+%Y-%m-%d')"
  local daily_file="${workspace}/${today}.md"

  # Create header if new file
  if [[ ! -f "$daily_file" ]]; then
    printf '# Daily Log: %s\n\n' "$today" > "$daily_file"
  fi

  # Append with timestamp
  local now
  now="$(date -u '+%H:%M:%S')"
  printf '\n## %s\n\n%s\n' "$now" "$content" >> "$daily_file"

  log_debug "Memory daily append: agent=$agent_id date=$today"
}

# ---- KV Store ----

# Store a value with optional tags and source
# Usage: memory_store KEY VALUE [--tags tag1,tag2] [--source SOURCE]
memory_store() {
  local key="${1:?key required}"
  local value="${2:?value required}"
  shift 2

  local tags=""
  local source=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags) tags="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "memory_store requires jq"

  local dir
  dir="$(memory_dir)"
  local safe_key
  safe_key="$(_memory_key_to_filename "$key")"
  local file="${dir}/${safe_key}.json"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Build tags JSON array from comma-separated string
  local tags_json="[]"
  if [[ -n "$tags" ]]; then
    tags_json="$(printf '%s' "$tags" | jq -Rs 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  fi

  # Check if entry already exists (update vs create)
  local created_at="$now"
  local access_count=0
  if [[ -f "$file" ]]; then
    created_at="$(jq -r '.created_at // empty' < "$file" 2>/dev/null)"
    access_count="$(jq -r '.access_count // 0' < "$file" 2>/dev/null)"
    created_at="${created_at:-$now}"
  fi

  jq -nc \
    --arg k "$key" \
    --arg v "$value" \
    --argjson tags "$tags_json" \
    --arg src "$source" \
    --arg ca "$created_at" \
    --arg ua "$now" \
    --argjson ac "$access_count" \
    '{key: $k, value: $v, tags: $tags, source: $src, created_at: $ca, updated_at: $ua, access_count: $ac}' \
    > "$file"

  chmod 600 "$file" 2>/dev/null || true
  log_debug "Memory stored: key=$key"
}

# Retrieve a value by key and increment access_count
memory_get() {
  local key="${1:?key required}"

  require_command jq "memory_get requires jq"

  local dir
  dir="$(memory_dir)"
  local safe_key
  safe_key="$(_memory_key_to_filename "$key")"
  local file="${dir}/${safe_key}.json"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  # Increment access_count in place
  local content
  content="$(cat "$file")"
  local updated
  updated="$(printf '%s' "$content" | jq '.access_count = (.access_count + 1)')"
  printf '%s\n' "$updated" > "$file"

  # Output the value
  printf '%s' "$content" | jq -r '.value'
}

# ---- BM25-Style Search ----

# Search across all memory files with relevance scoring
# Returns matching entries as JSON with scores
memory_search() {
  local query="${1:?query required}"
  local max_results="${2:-10}"

  require_command jq "memory_search requires jq"

  local dir
  dir="$(memory_dir)"
  local ndjson=""

  # Split query into terms for BM25-style scoring
  local query_lower
  query_lower="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"

  # Search JSON KV files
  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    if grep -qi "$query" "$f" 2>/dev/null; then
      local entry
      entry="$(cat "$f")"
      local score
      score="$(_memory_score_entry "$entry" "$query_lower")"
      ndjson="${ndjson}$(jq -nc --argjson e "$entry" --argjson s "$score" '$e + {score: $s}')"$'\n'
    fi
  done

  # Search markdown memory files (agent workspaces)
  local agents_dir="${BASHCLAW_STATE_DIR:?}/agents"
  if [[ -d "$agents_dir" ]]; then
    local agent_dir
    for agent_dir in "${agents_dir}"/*/; do
      [[ -d "$agent_dir" ]] || continue
      local agent_id
      agent_id="$(basename "$agent_dir")"

      # Search MEMORY.md
      local memory_md="${agent_dir}MEMORY.md"
      if [[ -f "$memory_md" ]] && grep -qi "$query" "$memory_md" 2>/dev/null; then
        local snippet
        snippet="$(grep -i "$query" "$memory_md" 2>/dev/null | head -5)"
        local md_score
        md_score="$(_memory_score_text "$snippet" "$query_lower")"
        ndjson="${ndjson}$(jq -nc \
          --arg k "md:${agent_id}:MEMORY" \
          --arg v "$snippet" \
          --arg src "$memory_md" \
          --argjson s "$md_score" \
          '{key: $k, value: $v, source: $src, score: $s, tags: ["markdown","curated"]}')"$'\n'
      fi

      # Search daily log files
      local md_file
      for md_file in "${agent_dir}memory/"*.md; do
        [[ -f "$md_file" ]] || continue
        if grep -qi "$query" "$md_file" 2>/dev/null; then
          local md_snippet
          md_snippet="$(grep -i "$query" "$md_file" 2>/dev/null | head -5)"
          local daily_score
          daily_score="$(_memory_score_text "$md_snippet" "$query_lower")"
          local md_basename
          md_basename="$(basename "$md_file")"
          ndjson="${ndjson}$(jq -nc \
            --arg k "md:${agent_id}:${md_basename}" \
            --arg v "$md_snippet" \
            --arg src "$md_file" \
            --argjson s "$daily_score" \
            '{key: $k, value: $v, source: $src, score: $s, tags: ["markdown","daily"]}')"$'\n'
        fi
      done
    done
  fi

  # Sort by score descending and limit results
  local results
  if [[ -n "$ndjson" ]]; then
    results="$(printf '%s' "$ndjson" | jq -s '.')"
  else
    results="[]"
  fi
  printf '%s' "$results" | jq --argjson limit "$max_results" \
    'sort_by(-.score) | .[:$limit]'
}

# BM25-style relevance scoring for a JSON entry
_memory_score_entry() {
  local entry="$1"
  local query_lower="$2"

  local text
  text="$(printf '%s' "$entry" | jq -r '(.key // "") + " " + (.value // "")' 2>/dev/null)"
  _memory_score_text "$text" "$query_lower"
}

# BM25-inspired term frequency scoring
_memory_score_text() {
  local text="$1"
  local query_lower="$2"

  local text_lower
  text_lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  local score=0
  local term
  for term in $query_lower; do
    [[ -z "$term" ]] && continue
    # Count occurrences (term frequency)
    local count=0
    local tmp="$text_lower"
    while [[ "$tmp" == *"$term"* ]]; do
      count=$((count + 1))
      tmp="${tmp#*"$term"}"
    done

    if [[ "$count" -gt 0 ]]; then
      # BM25-style saturation: tf / (tf + k1), k1=1.2
      # Using integer arithmetic: score += (count * 100) / (count + 1)
      local tf_score=$(( (count * 100) / (count + 1) ))
      score=$((score + tf_score))
    fi
  done

  # Bonus for exact phrase match
  if [[ "$text_lower" == *"$query_lower"* ]]; then
    score=$((score + 50))
  fi

  printf '%s' "$score"
}

# List memory entries with optional pagination
# Usage: memory_list [--limit N] [--offset O]
memory_list() {
  local limit=50
  local offset=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "memory_list requires jq"

  local dir
  dir="$(memory_dir)"
  local ndjson=""
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(cat "$f")"
    ndjson="${ndjson}${entry}"$'\n'
  done

  local all
  if [[ -n "$ndjson" ]]; then
    all="$(printf '%s' "$ndjson" | jq -s '.')"
  else
    all="[]"
  fi

  printf '%s' "$all" | jq --argjson off "$offset" --argjson lim "$limit" \
    '.[$off:$off + $lim]'
}

# Delete a memory entry by key
memory_delete() {
  local key="${1:?key required}"

  local dir
  dir="$(memory_dir)"
  local safe_key
  safe_key="$(_memory_key_to_filename "$key")"
  local file="${dir}/${safe_key}.json"

  if [[ -f "$file" ]]; then
    rm -f "$file"
    log_debug "Memory deleted: key=$key"
    return 0
  fi
  return 1
}

# Export all memory entries as a JSON array
memory_export() {
  require_command jq "memory_export requires jq"

  local dir
  dir="$(memory_dir)"
  local ndjson=""
  local f

  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local entry
    entry="$(cat "$f")"
    ndjson="${ndjson}${entry}"$'\n'
  done

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s '.'
  else
    printf '[]'
  fi
}

# Import memory entries from a JSON array file
memory_import() {
  local file="${1:?file path required}"

  if [[ ! -f "$file" ]]; then
    log_error "Import file not found: $file"
    return 1
  fi

  require_command jq "memory_import requires jq"

  local count
  count="$(jq 'length' < "$file")"
  local i=0

  while (( i < count )); do
    local entry
    entry="$(jq -c ".[$i]" < "$file")"
    local key value tags source
    key="$(printf '%s' "$entry" | jq -r '.key // empty')"
    value="$(printf '%s' "$entry" | jq -r '.value // empty')"
    tags="$(printf '%s' "$entry" | jq -r '.tags // [] | join(",")')"
    source="$(printf '%s' "$entry" | jq -r '.source // empty')"

    if [[ -n "$key" ]]; then
      local args=("$key" "$value")
      if [[ -n "$tags" ]]; then
        args+=(--tags "$tags")
      fi
      if [[ -n "$source" ]]; then
        args+=(--source "$source")
      fi
      memory_store "${args[@]}"
    fi
    i=$((i + 1))
  done

  log_info "Imported $count memory entries from $file"
}

# Deduplicate entries with the same key, keeping the newest
memory_compact() {
  require_command jq "memory_compact requires jq"

  local dir
  dir="$(memory_dir)"
  local removed=0

  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    local key
    key="$(jq -r '.key // empty' < "$f" 2>/dev/null)" || true
    if [[ -z "$key" ]]; then
      rm -f "$f"
      removed=$((removed + 1))
      continue
    fi

    # Validate JSON structure
    if ! jq empty < "$f" 2>/dev/null; then
      rm -f "$f"
      removed=$((removed + 1))
      continue
    fi
  done

  log_info "Memory compact: removed $removed invalid entries"
}

# ---- Enhanced Text Search (TF-IDF-like scoring) ----

# Search all memory KV files with TF-IDF-like scoring.
# For each query word: score = (word_count / total_words_in_value)
# Boost 2x if word appears in key, 1.5x if word appears in tags.
# Returns top N results as JSON array with {key, value, score, tags, source}.
memory_search_text() {
  local query="${1:-}"
  local limit="${2:-10}"

  require_command jq "memory_search_text requires jq"

  if [[ -z "$query" ]]; then
    printf '[]'
    return 0
  fi

  local dir
  dir="$(memory_dir)"
  local ndjson=""

  local query_lower
  query_lower="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"

  local f
  for f in "${dir}"/*.json; do
    [[ -f "$f" ]] || continue
    # Skip workspace index files
    local basename_f
    basename_f="$(basename "$f")"
    [[ "$basename_f" == .* ]] && continue

    local entry
    entry="$(cat "$f")" 2>/dev/null || continue
    if ! printf '%s' "$entry" | jq empty 2>/dev/null; then
      continue
    fi

    local value_text key_text tags_text
    value_text="$(printf '%s' "$entry" | jq -r '.value // ""' 2>/dev/null)"
    key_text="$(printf '%s' "$entry" | jq -r '.key // ""' 2>/dev/null)"
    tags_text="$(printf '%s' "$entry" | jq -r '(.tags // []) | join(" ")' 2>/dev/null)"

    local value_lower key_lower tags_lower
    value_lower="$(printf '%s' "$value_text" | tr '[:upper:]' '[:lower:]')"
    key_lower="$(printf '%s' "$key_text" | tr '[:upper:]' '[:lower:]')"
    tags_lower="$(printf '%s' "$tags_text" | tr '[:upper:]' '[:lower:]')"

    # Count total words in value
    local total_words=0
    local w
    for w in $value_lower; do
      total_words=$((total_words + 1))
    done
    if [[ "$total_words" -eq 0 ]]; then
      total_words=1
    fi

    local score=0
    local term
    for term in $query_lower; do
      [[ -z "$term" ]] && continue

      # Count occurrences in value text
      local count=0
      local tmp="$value_lower"
      while [[ "$tmp" == *"$term"* ]]; do
        count=$((count + 1))
        tmp="${tmp#*"$term"}"
      done

      if [[ "$count" -gt 0 ]]; then
        # TF-IDF-like: word_count / total_words (scaled by 1000 for integer math)
        local tf_score=$(( (count * 1000) / total_words ))
        score=$((score + tf_score))
      fi

      # Boost 2x if query word appears in key
      if [[ "$key_lower" == *"$term"* ]]; then
        local key_boost=$(( (count * 1000) / total_words ))
        score=$((score + key_boost))
      fi

      # Boost 1.5x if query word appears in tags
      if [[ "$tags_lower" == *"$term"* ]]; then
        local tag_boost=$(( ((count * 1000) / total_words) / 2 ))
        score=$((score + tag_boost))
      fi
    done

    if [[ "$score" -gt 0 ]]; then
      ndjson="${ndjson}$(printf '%s' "$entry" | jq -c --argjson s "$score" '{key: .key, value: .value, score: $s, tags: (.tags // []), source: (.source // "")}')"$'\n'
    fi
  done

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s --argjson limit "$limit" \
      'sort_by(-.score) | .[:$limit]'
  else
    printf '[]'
  fi
}

# Search workspace memory files: MEMORY.md + daily logs.
# Parse MEMORY.md into sections (split on ## headers), score each section.
# Search daily log files (most recent first).
# Returns combined results as JSON array.
memory_search_workspace() {
  local query="${1:-}"
  local agent_id="${2:-main}"

  require_command jq "memory_search_workspace requires jq"

  if [[ -z "$query" ]]; then
    printf '[]'
    return 0
  fi

  local query_lower
  query_lower="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"

  local ndjson=""
  local agent_dir="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}"

  # Search MEMORY.md sections
  local memory_md="${agent_dir}/MEMORY.md"
  if [[ -f "$memory_md" ]]; then
    local current_section=""
    local current_title=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "## "* ]]; then
        # Score previous section if non-empty
        if [[ -n "$current_section" ]]; then
          local section_score
          section_score="$(_memory_search_text_score "$current_section" "$query_lower")"
          if [[ "$section_score" -gt 0 ]]; then
            ndjson="${ndjson}$(jq -nc \
              --arg k "workspace:${agent_id}:${current_title}" \
              --arg v "$current_section" \
              --argjson s "$section_score" \
              --arg src "$memory_md" \
              '{key: $k, value: $v, score: $s, tags: ["workspace","curated"], source: $src}')"$'\n'
          fi
        fi
        current_title="${line#"## "}"
        current_section=""
      else
        current_section="${current_section}${line}"$'\n'
      fi
    done < "$memory_md"
    # Score final section
    if [[ -n "$current_section" ]]; then
      local section_score
      section_score="$(_memory_search_text_score "$current_section" "$query_lower")"
      if [[ "$section_score" -gt 0 ]]; then
        ndjson="${ndjson}$(jq -nc \
          --arg k "workspace:${agent_id}:${current_title}" \
          --arg v "$current_section" \
          --argjson s "$section_score" \
          --arg src "$memory_md" \
          '{key: $k, value: $v, score: $s, tags: ["workspace","curated"], source: $src}')"$'\n'
      fi
    fi
  fi

  # Search daily log files (most recent first)
  local workspace="${agent_dir}/memory"
  if [[ -d "$workspace" ]]; then
    local md_file
    for md_file in $(ls -t "${workspace}"/*.md 2>/dev/null); do
      [[ -f "$md_file" ]] || continue
      local content
      content="$(cat "$md_file" 2>/dev/null)" || continue
      local daily_score
      daily_score="$(_memory_search_text_score "$content" "$query_lower")"
      if [[ "$daily_score" -gt 0 ]]; then
        local md_basename
        md_basename="$(basename "$md_file")"
        # Truncate content for result display
        local snippet
        snippet="$(printf '%s' "$content" | head -20)"
        ndjson="${ndjson}$(jq -nc \
          --arg k "workspace:${agent_id}:daily:${md_basename}" \
          --arg v "$snippet" \
          --argjson s "$daily_score" \
          --arg src "$md_file" \
          '{key: $k, value: $v, score: $s, tags: ["workspace","daily"], source: $src}')"$'\n'
      fi
    done
  fi

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s 'sort_by(-.score)'
  else
    printf '[]'
  fi
}

# Score a text block against query terms (used by workspace search).
# Returns integer score.
_memory_search_text_score() {
  local text="$1"
  local query_lower="$2"

  local text_lower
  text_lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  local total_words=0
  local w
  for w in $text_lower; do
    total_words=$((total_words + 1))
  done
  if [[ "$total_words" -eq 0 ]]; then
    total_words=1
  fi

  local score=0
  local term
  for term in $query_lower; do
    [[ -z "$term" ]] && continue
    local count=0
    local tmp="$text_lower"
    while [[ "$tmp" == *"$term"* ]]; do
      count=$((count + 1))
      tmp="${tmp#*"$term"}"
    done
    if [[ "$count" -gt 0 ]]; then
      local tf_score=$(( (count * 1000) / total_words ))
      score=$((score + tf_score))
    fi
  done

  printf '%s' "$score"
}

# Sync workspace directory changes into memory index.
# Scans MEMORY.md content, tracks file hashes to detect changes.
# Stores index in ${BASHCLAW_STATE_DIR}/memory/.workspace_index.json
memory_sync_workspace() {
  local agent_id="${1:-main}"

  require_command jq "memory_sync_workspace requires jq"

  local agent_dir="${BASHCLAW_STATE_DIR:?}/agents/${agent_id}"
  local mem_dir
  mem_dir="$(memory_dir)"
  local index_file="${mem_dir}/.workspace_index.json"

  local old_index='{}'
  if [[ -f "$index_file" ]]; then
    old_index="$(cat "$index_file" 2>/dev/null)" || old_index='{}'
  fi

  local new_entries='{}'
  local updated=0

  # Scan MEMORY.md
  local memory_md="${agent_dir}/MEMORY.md"
  if [[ -f "$memory_md" ]]; then
    local file_hash
    file_hash="$(hash_string "$(cat "$memory_md")")"
    local old_hash
    old_hash="$(printf '%s' "$old_index" | jq -r --arg f "$memory_md" '.[$f] // ""' 2>/dev/null)"
    if [[ "$file_hash" != "$old_hash" ]]; then
      updated=$((updated + 1))
      # Parse sections and store as memory entries
      local current_section="" current_title=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "## "* ]]; then
          if [[ -n "$current_section" && -n "$current_title" ]]; then
            local safe_title
            safe_title="$(printf '%s' "$current_title" | tr -c '[:alnum:]._-' '_' | head -c 100)"
            memory_store "ws_${agent_id}_${safe_title}" "$current_section" \
              --tags "workspace,synced" --source "$memory_md"
          fi
          current_title="${line#"## "}"
          current_section=""
        else
          current_section="${current_section}${line}"$'\n'
        fi
      done < "$memory_md"
      if [[ -n "$current_section" && -n "$current_title" ]]; then
        local safe_title
        safe_title="$(printf '%s' "$current_title" | tr -c '[:alnum:]._-' '_' | head -c 100)"
        memory_store "ws_${agent_id}_${safe_title}" "$current_section" \
          --tags "workspace,synced" --source "$memory_md"
      fi
    fi
    new_entries="$(printf '%s' "$new_entries" | jq --arg f "$memory_md" --arg h "$file_hash" '. + {($f): $h}')"
  fi

  # Scan daily log files
  local workspace="${agent_dir}/memory"
  if [[ -d "$workspace" ]]; then
    local md_file
    for md_file in "${workspace}"/*.md; do
      [[ -f "$md_file" ]] || continue
      local file_hash
      file_hash="$(hash_string "$(cat "$md_file")")"
      local old_hash
      old_hash="$(printf '%s' "$old_index" | jq -r --arg f "$md_file" '.[$f] // ""' 2>/dev/null)"
      if [[ "$file_hash" != "$old_hash" ]]; then
        updated=$((updated + 1))
        local md_basename
        md_basename="$(basename "$md_file" .md)"
        local content
        content="$(cat "$md_file" 2>/dev/null)" || continue
        memory_store "ws_${agent_id}_daily_${md_basename}" "$content" \
          --tags "workspace,daily,synced" --source "$md_file"
      fi
      new_entries="$(printf '%s' "$new_entries" | jq --arg f "$md_file" --arg h "$file_hash" '. + {($f): $h}')"
    done
  fi

  # Write updated index
  printf '%s\n' "$new_entries" > "$index_file"
  chmod 600 "$index_file" 2>/dev/null || true

  log_debug "Workspace sync: agent=$agent_id updated=$updated files"
  jq -nc --arg agent "$agent_id" --argjson updated "$updated" \
    '{agent_id: $agent, files_updated: $updated}'
}

# Combined search across KV store, workspace, and text scoring.
# Returns merged JSON array with results from all sources.
memory_search_all() {
  local query="${1:-}"
  local agent_id="${2:-main}"
  local limit="${3:-10}"

  require_command jq "memory_search_all requires jq"

  if [[ -z "$query" ]]; then
    printf '[]'
    return 0
  fi

  local text_results workspace_results
  text_results="$(memory_search_text "$query" "$limit")"
  workspace_results="$(memory_search_workspace "$query" "$agent_id")"

  # Merge and deduplicate by key, sort by score descending
  printf '%s\n%s' "$text_results" "$workspace_results" | \
    jq -s --argjson limit "$limit" \
    '.[0] + .[1] | group_by(.key) | map(max_by(.score)) | sort_by(-.score) | .[:$limit]'
}
