#!/usr/bin/env bash
# Tool system for bashclaw
# Compatible with bash 3.2+ (no associative arrays)
# Supports file tools, session isolation, optional tools, and elevated checks.

TOOL_WEB_FETCH_MAX_CHARS="${TOOL_WEB_FETCH_MAX_CHARS:-102400}"
TOOL_SHELL_TIMEOUT="${TOOL_SHELL_TIMEOUT:-30}"
TOOL_READ_FILE_MAX_LINES="${TOOL_READ_FILE_MAX_LINES:-2000}"
TOOL_LIST_FILES_MAX="${TOOL_LIST_FILES_MAX:-500}"

# ---- Tool Profiles ----
# Named presets of tool sets. Profile is applied first, then allow/deny modify it.

tools_resolve_profile() {
  local profile_name="${1:-full}"
  case "$profile_name" in
    minimal)
      echo "web_fetch web_search memory session_status"
      ;;
    coding)
      echo "web_fetch web_search memory session_status shell read_file write_file list_files file_search"
      ;;
    messaging)
      echo "web_fetch web_search memory session_status message agent_message agents_list"
      ;;
    full|"")
      _tool_list
      ;;
    *)
      _tool_list
      ;;
  esac
}

# ---- Tool Registry (function-based for bash 3.2 compat) ----

_tool_handler() {
  case "$1" in
    web_fetch)      echo "tool_web_fetch" ;;
    web_search)     echo "tool_web_search" ;;
    shell)          echo "tool_shell" ;;
    memory)         echo "tool_memory" ;;
    cron)           echo "tool_cron" ;;
    message)        echo "tool_message" ;;
    agents_list)    echo "tool_agents_list" ;;
    session_status) echo "tool_session_status" ;;
    sessions_list)  echo "tool_sessions_list" ;;
    agent_message)  echo "tool_agent_message" ;;
    read_file)      echo "tool_read_file" ;;
    write_file)     echo "tool_write_file" ;;
    list_files)     echo "tool_list_files" ;;
    file_search)    echo "tool_file_search" ;;
    spawn)          echo "tool_spawn" ;;
    spawn_status)   echo "tool_spawn_status" ;;
    *)
      # Check plugin-registered tools as fallback
      local plugin_handler
      plugin_handler="$(plugin_tool_handler "$1" 2>/dev/null)"
      if [[ -n "$plugin_handler" ]]; then
        echo "$plugin_handler"
      fi
      ;;
  esac
}

_tool_list() {
  echo "web_fetch web_search shell memory cron message agents_list session_status sessions_list agent_message read_file write_file list_files file_search spawn spawn_status"
}

# Tool optional flag registry (tools that default to disabled unless explicitly allowed).
# Returns 0 if the tool is optional, 1 otherwise.
_tool_is_optional() {
  case "$1" in
    shell|write_file)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Elevated operations that require authorization.
# Returns the elevation level: "none", "elevated", "dangerous"
_tool_elevation_level() {
  case "$1" in
    shell)      echo "elevated" ;;
    write_file) echo "elevated" ;;
    *)          echo "none" ;;
  esac
}

# ---- SSRF private IP patterns ----

_ssrf_is_private_pattern() {
  local addr="$1"
  case "$addr" in
    10.*)            return 0 ;;
    172.1[6-9].*)    return 0 ;;
    172.2[0-9].*)    return 0 ;;
    172.3[01].*)     return 0 ;;
    192.168.*)       return 0 ;;
    127.*)           return 0 ;;
    0.*)             return 0 ;;
    169.254.*)       return 0 ;;
    localhost)       return 0 ;;
    metadata.google.internal) return 0 ;;
    ::1)             return 0 ;;
    fe80:*)          return 0 ;;
    fc*)             return 0 ;;
    fd*)             return 0 ;;
    *)               return 1 ;;
  esac
}

# ---- Dangerous shell patterns ----

_shell_is_dangerous() {
  local cmd="$1"
  case "$cmd" in
    *"rm -rf /"*)       return 0 ;;
    *"rm -rf /*"*)      return 0 ;;
    *"mkfs"*)           return 0 ;;
    *"dd if="*)         return 0 ;;
    *"> /dev/sd"*)      return 0 ;;
    *"chmod -R 777 /"*) return 0 ;;
    *":(){:|:&};:"*)    return 0 ;;
    *)                  return 1 ;;
  esac
}

# ---- Tool Dispatch ----

# Execute a tool with optional session isolation and security checks.
# Usage: tool_execute TOOL_NAME TOOL_INPUT [SESSION_KEY]
tool_execute() {
  local tool_name="$1"
  local tool_input="$2"
  local session_key="${3:-}"

  local handler
  handler="$(_tool_handler "$tool_name")"
  if [[ -z "$handler" ]]; then
    log_error "Unknown tool: $tool_name"
    printf '{"error": "unknown tool: %s"}' "$tool_name"
    return 1
  fi

  # Elevated check for dangerous tools
  local elevation
  elevation="$(_tool_elevation_level "$tool_name")"
  if [[ "$elevation" != "none" ]]; then
    if ! tools_elevated_check "$tool_name" "$session_key"; then
      log_warn "Elevated tool blocked: $tool_name session=$session_key"
      printf '{"error": "elevated tool requires authorization", "tool": "%s"}' "$tool_name"
      return 1
    fi
  fi

  # Export session context for tools that need isolation
  local prev_session_key="${BASHCLAW_TOOL_SESSION_KEY:-}"
  if [[ -n "$session_key" ]]; then
    BASHCLAW_TOOL_SESSION_KEY="$session_key"
  fi

  log_debug "Executing tool: $tool_name session=$session_key"
  local result
  result="$("$handler" "$tool_input")"
  local rc=$?

  # Restore previous session context
  BASHCLAW_TOOL_SESSION_KEY="$prev_session_key"

  printf '%s' "$result"
  return $rc
}

# Check if a tool should be included in the tool spec for a given context.
# Handles optional tools and allow/deny filtering.
# Usage: tools_is_available TOOL_NAME [ALLOW_LIST_JSON] [DENY_LIST_JSON]
tools_is_available() {
  local tool_name="${1:?tool name required}"
  local allow_json="${2:-[]}"
  local deny_json="${3:-[]}"

  require_command jq "tools_is_available requires jq"

  # Check deny list first
  if [[ "$deny_json" != "[]" ]]; then
    local in_deny
    in_deny="$(printf '%s' "$deny_json" | jq --arg t "$tool_name" '[.[] | select(. == $t)] | length')"
    if [[ "$in_deny" -gt 0 ]]; then
      return 1
    fi
  fi

  # If tool is optional, it must be explicitly in the allow list
  if _tool_is_optional "$tool_name"; then
    if [[ "$allow_json" == "[]" ]]; then
      return 1
    fi
    local in_allow
    in_allow="$(printf '%s' "$allow_json" | jq --arg t "$tool_name" '[.[] | select(. == $t)] | length')"
    if [[ "$in_allow" -eq 0 ]]; then
      return 1
    fi
  fi

  # If allow list is non-empty and tool is not optional, check it
  if [[ "$allow_json" != "[]" ]]; then
    local in_allow
    in_allow="$(printf '%s' "$allow_json" | jq --arg t "$tool_name" '[.[] | select(. == $t)] | length')"
    if [[ "$in_allow" -eq 0 ]]; then
      return 1
    fi
  fi

  return 0
}

# Check if a tool requiring elevated authorization is permitted.
# Returns 0 if allowed, 1 if blocked.
# Usage: tools_elevated_check TOOL_NAME [SESSION_KEY]
tools_elevated_check() {
  local tool_name="${1:?tool name required}"
  local session_key="${2:-}"

  local elevation
  elevation="$(_tool_elevation_level "$tool_name")"

  if [[ "$elevation" == "none" ]]; then
    return 0
  fi

  # Check if tool is explicitly allowed in config
  local elevated_allow
  elevated_allow="$(config_get_raw '.security.elevatedTools // []' 2>/dev/null)"
  if [[ -n "$elevated_allow" && "$elevated_allow" != "[]" ]]; then
    local in_allow
    in_allow="$(printf '%s' "$elevated_allow" | jq --arg t "$tool_name" '[.[] | select(. == $t)] | length' 2>/dev/null)"
    if [[ "$in_allow" -gt 0 ]]; then
      return 0
    fi
  fi

  # Check approval file for this session
  if [[ -n "$session_key" ]]; then
    local approval_dir="${BASHCLAW_STATE_DIR:?}/approvals"
    local safe_key
    safe_key="$(sanitize_key "$session_key")"
    local approval_file="${approval_dir}/${safe_key}_${tool_name}.approved"
    if [[ -f "$approval_file" ]]; then
      return 0
    fi
  fi

  # Default: elevated tools in "dangerous" category are blocked
  if [[ "$elevation" == "dangerous" ]]; then
    return 1
  fi

  # "elevated" tools are allowed by default but logged
  log_info "Elevated tool execution: $tool_name session=$session_key"
  return 0
}

# ---- Tool Descriptions ----

tools_describe_all() {
  cat <<'TOOLDESC'
Available tools:

1. web_fetch - Fetch and extract readable content from a URL.
   Parameters: url (string, required), maxChars (number, optional)

2. web_search - Search the web using Brave Search or Perplexity.
   Parameters: query (string, required), count (number, optional, 1-10)

3. shell - Execute a shell command with timeout and safety checks. [optional]
   Parameters: command (string, required), timeout (number, optional)

4. memory - File-based key-value store for persistent memory.
   Parameters: action (get|set|delete|list|search, required), key (string), value (string), query (string)

5. cron - Manage scheduled jobs.
   Parameters: action (add|remove|list, required), id (string), schedule (string), command (string)

6. message - Send a message via the configured channel handler.
   Parameters: action (send, required), channel (string), target (string), message (string, required)

7. agents_list - List all configured agents with their settings.
   Parameters: none

8. session_status - Query session info for the current agent.
   Parameters: agent_id (string), channel (string), sender (string)

9. sessions_list - List all active sessions across all agents.
   Parameters: none

10. agent_message - Send a message to another agent.
    Parameters: target_agent (string, required), message (string, required), from_agent (string, optional)

11. read_file - Read a file with optional line offset and limit.
    Parameters: path (string, required), offset (number, optional), limit (number, optional)

12. write_file - Create or overwrite a file. [optional, elevated]
    Parameters: path (string, required), content (string, required), append (boolean, optional)

13. list_files - List files in a directory with optional pattern filtering.
    Parameters: path (string, required), pattern (string, optional), recursive (boolean, optional)

14. file_search - Search for files matching a name or content pattern.
    Parameters: path (string, required), name (string, optional), content (string, optional), maxResults (number, optional)

15. spawn - Spawn a background subagent for long-running tasks.
    Parameters: task (string, required), label (string, optional)

16. spawn_status - Check status of a spawned background task.
    Parameters: task_id (string, required)
TOOLDESC
}

# ---- Tool Spec Builder (Anthropic format) ----

tools_build_spec() {
  local profile_name="${1:-}"
  require_command jq "tools_build_spec requires jq"

  # If a profile is specified, filter the full spec to only include profile tools
  local profile_tools=""
  if [[ -n "$profile_name" && "$profile_name" != "full" ]]; then
    profile_tools="$(tools_resolve_profile "$profile_name")"
  fi

  local full_spec
  full_spec="$(_tools_build_full_spec)"

  if [[ -n "$profile_tools" ]]; then
    local profile_json="[]"
    local t
    for t in $profile_tools; do
      profile_json="$(printf '%s' "$profile_json" | jq --arg t "$t" '. + [$t]')"
    done
    printf '%s' "$full_spec" | jq --argjson p "$profile_json" '[.[] | select(.name as $n | $p | index($n))]'
  else
    printf '%s' "$full_spec"
  fi
}

_tools_build_full_spec() {
  jq -nc '[
    {
      "name": "web_fetch",
      "description": "Fetch and extract readable content from a URL. Use for lightweight page access.",
      "input_schema": {
        "type": "object",
        "properties": {
          "url": {"type": "string", "description": "HTTP or HTTPS URL to fetch."},
          "maxChars": {"type": "number", "description": "Maximum characters to return."}
        },
        "required": ["url"]
      }
    },
    {
      "name": "web_search",
      "description": "Search the web. Returns titles, URLs, and snippets.",
      "input_schema": {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "Search query string."},
          "count": {"type": "number", "description": "Number of results to return (1-10)."}
        },
        "required": ["query"]
      }
    },
    {
      "name": "shell",
      "description": "Execute a shell command with timeout and safety checks.",
      "input_schema": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "The shell command to execute."},
          "timeout": {"type": "number", "description": "Timeout in seconds (default 30)."}
        },
        "required": ["command"]
      }
    },
    {
      "name": "memory",
      "description": "File-based key-value store for persistent agent memory. Supports get, set, delete, list, and search actions.",
      "input_schema": {
        "type": "object",
        "properties": {
          "action": {"type": "string", "enum": ["get", "set", "delete", "list", "search"], "description": "The memory operation to perform."},
          "key": {"type": "string", "description": "The key to get, set, or delete."},
          "value": {"type": "string", "description": "The value to store (for set action)."},
          "query": {"type": "string", "description": "Search query (for search action)."}
        },
        "required": ["action"]
      }
    },
    {
      "name": "cron",
      "description": "Manage scheduled cron jobs. Supports add, remove, and list actions.",
      "input_schema": {
        "type": "object",
        "properties": {
          "action": {"type": "string", "enum": ["add", "remove", "list"], "description": "The cron operation to perform."},
          "id": {"type": "string", "description": "Job ID (for remove)."},
          "schedule": {"type": "string", "description": "Cron schedule expression (for add)."},
          "command": {"type": "string", "description": "Command to execute (for add)."},
          "agent_id": {"type": "string", "description": "Agent ID for the job."}
        },
        "required": ["action"]
      }
    },
    {
      "name": "message",
      "description": "Send a message via channel handler.",
      "input_schema": {
        "type": "object",
        "properties": {
          "action": {"type": "string", "enum": ["send"], "description": "Message action."},
          "channel": {"type": "string", "description": "Target channel (telegram, discord, slack, etc)."},
          "target": {"type": "string", "description": "Target chat/user ID."},
          "message": {"type": "string", "description": "The message text to send."}
        },
        "required": ["action", "message"]
      }
    },
    {
      "name": "agents_list",
      "description": "List all configured agents with their settings.",
      "input_schema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "name": "session_status",
      "description": "Query session info for a specific agent, channel, and sender.",
      "input_schema": {
        "type": "object",
        "properties": {
          "agent_id": {"type": "string", "description": "Agent ID to query."},
          "channel": {"type": "string", "description": "Channel name."},
          "sender": {"type": "string", "description": "Sender identifier."}
        },
        "required": []
      }
    },
    {
      "name": "sessions_list",
      "description": "List all active sessions across all agents.",
      "input_schema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "name": "agent_message",
      "description": "Send a message to another agent and get their response.",
      "input_schema": {
        "type": "object",
        "properties": {
          "target_agent": {"type": "string", "description": "The agent ID to send the message to."},
          "message": {"type": "string", "description": "The message to send."},
          "from_agent": {"type": "string", "description": "The sending agent ID (optional)."}
        },
        "required": ["target_agent", "message"]
      }
    },
    {
      "name": "read_file",
      "description": "Read a file from the filesystem with optional line offset and limit.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Absolute or relative file path to read."},
          "offset": {"type": "number", "description": "Line number to start reading from (1-based, default 1)."},
          "limit": {"type": "number", "description": "Maximum number of lines to return."}
        },
        "required": ["path"]
      }
    },
    {
      "name": "write_file",
      "description": "Create or overwrite a file on the filesystem. Requires elevated authorization.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Absolute or relative file path to write."},
          "content": {"type": "string", "description": "The content to write to the file."},
          "append": {"type": "boolean", "description": "If true, append to the file instead of overwriting."}
        },
        "required": ["path", "content"]
      }
    },
    {
      "name": "list_files",
      "description": "List files and directories at a given path.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Directory path to list."},
          "pattern": {"type": "string", "description": "Glob pattern to filter results (e.g. *.sh)."},
          "recursive": {"type": "boolean", "description": "If true, list recursively."}
        },
        "required": ["path"]
      }
    },
    {
      "name": "file_search",
      "description": "Search for files by name pattern or content match.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Directory to search in."},
          "name": {"type": "string", "description": "Filename pattern to match (glob)."},
          "content": {"type": "string", "description": "Search for files containing this text."},
          "maxResults": {"type": "number", "description": "Maximum number of results to return."}
        },
        "required": ["path"]
      }
    },
    {
      "name": "spawn",
      "description": "Spawn a background subagent for long-running tasks. Returns immediately with a task ID.",
      "input_schema": {
        "type": "object",
        "properties": {
          "task": {"type": "string", "description": "Task description for the subagent."},
          "label": {"type": "string", "description": "Short label for the task."}
        },
        "required": ["task"]
      }
    },
    {
      "name": "spawn_status",
      "description": "Check status of a spawned background task.",
      "input_schema": {
        "type": "object",
        "properties": {
          "task_id": {"type": "string", "description": "Task ID from spawn."}
        },
        "required": ["task_id"]
      }
    }
  ]'
}

# ---- Tool: web_fetch ----

tool_web_fetch() {
  local input="$1"
  require_command curl "web_fetch requires curl"
  require_command jq "web_fetch requires jq"

  local url max_chars
  url="$(printf '%s' "$input" | jq -r '.url // empty')"
  max_chars="$(printf '%s' "$input" | jq -r '.maxChars // empty')"
  max_chars="${max_chars:-$TOOL_WEB_FETCH_MAX_CHARS}"

  if [[ -z "$url" ]]; then
    printf '{"error": "url parameter is required"}'
    return 1
  fi

  if [[ "$url" != http://* && "$url" != https://* ]]; then
    printf '{"error": "URL must use http or https protocol"}'
    return 1
  fi

  # SSRF protection: extract hostname
  local hostname
  hostname="$(printf '%s' "$url" | sed -E 's|^https?://||' | sed -E 's|[:/].*||' | tr '[:upper:]' '[:lower:]')"

  if _ssrf_is_blocked "$hostname"; then
    printf '{"error": "SSRF blocked: request to private/internal address denied"}'
    return 1
  fi

  local response_file
  response_file="$(tmpfile "web_fetch")"

  local http_code
  http_code="$(curl -sS -L --max-redirs 5 --max-time 30 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Accept: text/markdown, text/html;q=0.9, */*;q=0.1' \
    -H 'User-Agent: Mozilla/5.0 (compatible; bashclaw/1.0)' \
    "$url" 2>/dev/null)" || {
    printf '{"error": "fetch failed", "url": "%s"}' "$url"
    return 1
  }

  if [[ "$http_code" -ge 400 ]]; then
    local error_body
    error_body="$(head -c 4000 "$response_file" 2>/dev/null || true)"
    jq -nc --arg url "$url" --arg code "$http_code" --arg body "$error_body" \
      '{error: "HTTP error", status: ($code | tonumber), url: $url, detail: $body}'
    return 1
  fi

  local body
  body="$(head -c "$max_chars" "$response_file" 2>/dev/null || true)"
  local body_len
  body_len="$(file_size_bytes "$response_file")"
  local truncated="false"
  if [ "$body_len" -gt "$max_chars" ]; then
    truncated="true"
  fi

  jq -nc \
    --arg url "$url" \
    --arg status "$http_code" \
    --arg text "$body" \
    --arg trunc "$truncated" \
    --arg len "$body_len" \
    '{url: $url, status: ($status | tonumber), text: $text, truncated: ($trunc == "true"), length: ($len | tonumber)}'
}

# ---- Tool: web_search ----

tool_web_search() {
  local input="$1"
  require_command curl "web_search requires curl"
  require_command jq "web_search requires jq"

  local query count
  query="$(printf '%s' "$input" | jq -r '.query // empty')"
  count="$(printf '%s' "$input" | jq -r '.count // empty')"
  count="${count:-5}"

  if [[ -z "$query" ]]; then
    printf '{"error": "query parameter is required"}'
    return 1
  fi

  if [ "$count" -lt 1 ] 2>/dev/null; then count=1; fi
  if [ "$count" -gt 10 ] 2>/dev/null; then count=10; fi

  local api_key="${BRAVE_SEARCH_API_KEY:-}"
  if [[ -n "$api_key" ]]; then
    _web_search_brave "$query" "$count" "$api_key"
    return $?
  fi

  local perplexity_key="${PERPLEXITY_API_KEY:-}"
  if [[ -n "$perplexity_key" ]]; then
    _web_search_perplexity "$query" "$perplexity_key"
    return $?
  fi

  printf '{"error": "No search API key configured. Set BRAVE_SEARCH_API_KEY or PERPLEXITY_API_KEY."}'
  return 1
}

_web_search_brave() {
  local query="$1"
  local count="$2"
  local api_key="$3"

  local encoded_query
  encoded_query="$(url_encode "$query")"

  local response
  response="$(curl -sS --max-time 15 \
    -H "Accept: application/json" \
    -H "X-Subscription-Token: ${api_key}" \
    "https://api.search.brave.com/res/v1/web/search?q=${encoded_query}&count=${count}" 2>/dev/null)"

  if [[ $? -ne 0 || -z "$response" ]]; then
    printf '{"error": "Brave Search API request failed"}'
    return 1
  fi

  printf '%s' "$response" | jq '{
    query: .query.original,
    provider: "brave",
    results: [(.web.results // [])[:10][] | {
      title: .title,
      url: .url,
      description: .description,
      published: .age
    }]
  }'
}

_web_search_perplexity() {
  local query="$1"
  local api_key="$2"

  local base_url="${PERPLEXITY_BASE_URL:-https://api.perplexity.ai}"
  local model="${PERPLEXITY_MODEL:-sonar-pro}"

  local body
  body="$(jq -nc --arg q "$query" --arg m "$model" '{
    model: $m,
    messages: [{role: "user", content: $q}]
  }')"

  local response
  response="$(curl -sS --max-time 30 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d "$body" \
    "${base_url}/chat/completions" 2>/dev/null)"

  if [[ $? -ne 0 || -z "$response" ]]; then
    printf '{"error": "Perplexity API request failed"}'
    return 1
  fi

  local safe_query
  safe_query="$(printf '%s' "$query" | jq -Rs '.')"
  printf '%s' "$response" | jq --arg q "$query" '{
    query: $q,
    provider: "perplexity",
    content: (.choices[0].message.content // "No response"),
    citations: (.citations // [])
  }'
}

# ---- Tool: shell ----

tool_shell() {
  local input="$1"
  require_command jq "shell tool requires jq"

  local cmd timeout_val
  cmd="$(printf '%s' "$input" | jq -r '.command // empty')"
  timeout_val="$(printf '%s' "$input" | jq -r '.timeout // empty')"
  timeout_val="${timeout_val:-$TOOL_SHELL_TIMEOUT}"

  if [[ -z "$cmd" ]]; then
    printf '{"error": "command parameter is required"}'
    return 1
  fi

  if _shell_is_dangerous "$cmd"; then
    log_warn "Shell tool blocked dangerous command: $cmd"
    printf '{"error": "blocked", "reason": "dangerous command pattern detected"}'
    return 1
  fi

  local output exit_code
  local had_errexit=0
  if [[ "$-" == *e* ]]; then
    had_errexit=1
    set +e
  fi

  if is_command_available timeout; then
    output="$(timeout "$timeout_val" bash -c "$cmd" 2>&1)"
    exit_code=$?
  elif is_command_available gtimeout; then
    output="$(gtimeout "$timeout_val" bash -c "$cmd" 2>&1)"
    exit_code=$?
  else
    # Pure-bash timeout fallback (macOS/Termux)
    local _tmpout
    _tmpout="$(mktemp -t bashclaw_sh.XXXXXX 2>/dev/null || mktemp /tmp/bashclaw_sh.XXXXXX)"
    bash -c "$cmd" > "$_tmpout" 2>&1 &
    local _pid=$!
    local _waited=0
    while kill -0 "$_pid" 2>/dev/null && (( _waited < timeout_val )); do
      sleep 1
      _waited=$((_waited + 1))
    done
    if kill -0 "$_pid" 2>/dev/null; then
      kill -9 "$_pid" 2>/dev/null
      wait "$_pid" 2>/dev/null
      output="[command timed out after ${timeout_val}s]"
      exit_code=124
    else
      wait "$_pid" 2>/dev/null
      exit_code=$?
      output="$(cat "$_tmpout")"
    fi
    rm -f "$_tmpout"
  fi

  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi

  # Truncate output to 100KB
  if [ "${#output}" -gt 102400 ]; then
    output="${output:0:102400}... [truncated]"
  fi

  jq -nc --arg out "$output" --arg code "$exit_code" \
    '{output: $out, exitCode: ($code | tonumber)}'
}

# ---- Tool: memory ----

tool_memory() {
  local input="$1"
  require_command jq "memory tool requires jq"

  local action key value query_str
  action="$(printf '%s' "$input" | jq -r '.action // empty')"
  key="$(printf '%s' "$input" | jq -r '.key // empty')"
  value="$(printf '%s' "$input" | jq -r '.value // empty')"
  query_str="$(printf '%s' "$input" | jq -r '.query // empty')"

  local mem_dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/memory"
  ensure_dir "$mem_dir"

  case "$action" in
    get)
      if [[ -z "$key" ]]; then
        printf '{"error": "key is required for get"}'
        return 1
      fi
      local safe_key
      safe_key="$(_memory_safe_key "$key")"
      local file="${mem_dir}/${safe_key}.json"
      if [[ ! -f "$file" ]]; then
        jq -nc --arg k "$key" '{"key": $k, "found": false}'
        return 0
      fi
      cat "$file"
      ;;
    set)
      if [[ -z "$key" ]]; then
        printf '{"error": "key is required for set"}'
        return 1
      fi
      local safe_key
      safe_key="$(_memory_safe_key "$key")"
      local file="${mem_dir}/${safe_key}.json"
      local ts
      ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      jq -nc --arg k "$key" --arg v "$value" --arg t "$ts" \
        '{"key": $k, "value": $v, "updated_at": $t}' > "$file"
      jq -nc --arg k "$key" '{"key": $k, "stored": true}'
      ;;
    delete)
      if [[ -z "$key" ]]; then
        printf '{"error": "key is required for delete"}'
        return 1
      fi
      local safe_key
      safe_key="$(_memory_safe_key "$key")"
      local file="${mem_dir}/${safe_key}.json"
      if [[ -f "$file" ]]; then
        rm -f "$file"
        jq -nc --arg k "$key" '{"key": $k, "deleted": true}'
      else
        jq -nc --arg k "$key" '{"key": $k, "deleted": false, "reason": "not found"}'
      fi
      ;;
    list)
      local keys_ndjson=""
      local f
      for f in "${mem_dir}"/*.json; do
        [[ -f "$f" ]] || continue
        local k
        k="$(jq -r '.key // empty' < "$f" 2>/dev/null)"
        if [[ -n "$k" ]]; then
          keys_ndjson="${keys_ndjson}$(jq -nc --arg k "$k" '$k')"$'\n'
        fi
      done
      local keys
      if [[ -n "$keys_ndjson" ]]; then
        keys="$(printf '%s' "$keys_ndjson" | jq -s '.')"
      else
        keys="[]"
      fi
      jq -nc --argjson ks "$keys" '{"keys": $ks, "count": ($ks | length)}'
      ;;
    search)
      if [[ -z "$query_str" ]]; then
        printf '{"error": "query is required for search"}'
        return 1
      fi
      local results
      results="$(memory_search_text "$query_str" 20)"
      jq -nc --argjson r "$results" '{"results": $r, "count": ($r | length)}'
      ;;
    *)
      printf '{"error": "unknown memory action: %s. Use get, set, delete, list, or search"}' "$action"
      return 1
      ;;
  esac
}

_memory_safe_key() {
  sanitize_key "$1"
}

# ---- Tool: cron ----

tool_cron() {
  local input="$1"
  require_command jq "cron tool requires jq"

  local action id schedule command agent_id
  action="$(printf '%s' "$input" | jq -r '.action // empty')"
  id="$(printf '%s' "$input" | jq -r '.id // empty')"
  schedule="$(printf '%s' "$input" | jq -r '.schedule // empty')"
  command="$(printf '%s' "$input" | jq -r '.command // empty')"
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty')"

  local cron_dir="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/cron"
  ensure_dir "$cron_dir"

  case "$action" in
    add)
      if [[ -z "$schedule" || -z "$command" ]]; then
        printf '{"error": "schedule and command are required for add"}'
        return 1
      fi
      if [[ -z "$id" ]]; then
        id="$(uuid_generate)"
      fi
      local ts
      ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      local safe_id
      safe_id="$(_memory_safe_key "$id")"
      jq -nc \
        --arg id "$id" \
        --arg sched "$schedule" \
        --arg cmd "$command" \
        --arg aid "$agent_id" \
        --arg ts "$ts" \
        '{id: $id, schedule: $sched, command: $cmd, agent_id: $aid, created_at: $ts, enabled: true}' \
        > "${cron_dir}/${safe_id}.json"
      jq -nc --arg id "$id" '{"id": $id, "created": true}'
      ;;
    remove)
      if [[ -z "$id" ]]; then
        printf '{"error": "id is required for remove"}'
        return 1
      fi
      local safe_id
      safe_id="$(_memory_safe_key "$id")"
      local file="${cron_dir}/${safe_id}.json"
      if [[ -f "$file" ]]; then
        rm -f "$file"
        jq -nc --arg id "$id" '{"id": $id, "removed": true}'
      else
        jq -nc --arg id "$id" '{"id": $id, "removed": false, "reason": "not found"}'
      fi
      ;;
    list)
      local jobs_ndjson=""
      local f
      for f in "${cron_dir}"/*.json; do
        [[ -f "$f" ]] || continue
        local entry
        entry="$(cat "$f")"
        jobs_ndjson="${jobs_ndjson}${entry}"$'\n'
      done
      local jobs
      if [[ -n "$jobs_ndjson" ]]; then
        jobs="$(printf '%s' "$jobs_ndjson" | jq -s '.')"
      else
        jobs="[]"
      fi
      jq -nc --argjson j "$jobs" '{"jobs": $j, "count": ($j | length)}'
      ;;
    *)
      printf '{"error": "unknown cron action: %s. Use add, remove, or list"}' "$action"
      return 1
      ;;
  esac
}

# ---- Tool: message ----

tool_message() {
  local input="$1"
  require_command jq "message tool requires jq"

  local action channel target message_text
  action="$(printf '%s' "$input" | jq -r '.action // empty')"
  channel="$(printf '%s' "$input" | jq -r '.channel // empty')"
  target="$(printf '%s' "$input" | jq -r '.target // empty')"
  message_text="$(printf '%s' "$input" | jq -r '.message // empty')"

  if [[ "$action" != "send" ]]; then
    printf '{"error": "only send action is supported"}'
    return 1
  fi

  if [[ -z "$message_text" ]]; then
    printf '{"error": "message parameter is required"}'
    return 1
  fi

  local handler_func="_channel_send_${channel}"
  if declare -f "$handler_func" &>/dev/null; then
    "$handler_func" "$target" "$message_text"
  else
    log_warn "No channel handler for: ${channel:-<none>}, message logged only"
    jq -nc --arg ch "$channel" --arg tgt "$target" --arg msg "$message_text" \
      '{"sent": false, "channel": $ch, "target": $tgt, "message": $msg, "reason": "no handler configured"}'
  fi
}

# ---- Tool: agents_list ----

# List all configured agents from the config
tool_agents_list() {
  require_command jq "agents_list tool requires jq"

  local agents_raw
  agents_raw="$(config_get_raw '.agents.list // []')"
  local defaults
  defaults="$(config_get_raw '.agents.defaults // {}')"

  jq -nc --argjson agents "$agents_raw" --argjson defaults "$defaults" \
    '{agents: $agents, defaults: $defaults, count: ($agents | length)}'
}

# ---- Tool: session_status ----

# Query session info for a specific agent/channel/sender
tool_session_status() {
  local input="$1"
  require_command jq "session_status tool requires jq"

  local agent_id channel sender
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // "main"')"
  channel="$(printf '%s' "$input" | jq -r '.channel // "default"')"
  sender="$(printf '%s' "$input" | jq -r '.sender // empty')"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  local msg_count=0
  local last_role=""
  if [[ -f "$sess_file" ]]; then
    msg_count="$(session_count "$sess_file")"
    last_role="$(session_last_role "$sess_file")"
  fi

  local model
  model="$(agent_resolve_model "$agent_id")"
  local provider
  provider="$(agent_resolve_provider "$model")"

  jq -nc \
    --arg aid "$agent_id" \
    --arg ch "$channel" \
    --arg snd "$sender" \
    --arg sf "$sess_file" \
    --argjson mc "$msg_count" \
    --arg lr "$last_role" \
    --arg m "$model" \
    --arg p "$provider" \
    '{agent_id: $aid, channel: $ch, sender: $snd, session_file: $sf, message_count: $mc, last_role: $lr, model: $m, provider: $p}'
}

# ---- Tool: sessions_list ----

# List all active sessions across all agents
tool_sessions_list() {
  require_command jq "sessions_list tool requires jq"
  session_list
}

# ---- Tool: read_file ----

tool_read_file() {
  local input="$1"
  require_command jq "read_file tool requires jq"

  local path offset limit
  path="$(printf '%s' "$input" | jq -r '.path // empty')"
  offset="$(printf '%s' "$input" | jq -r '.offset // empty')"
  limit="$(printf '%s' "$input" | jq -r '.limit // empty')"

  if [[ -z "$path" ]]; then
    printf '{"error": "path parameter is required"}'
    return 1
  fi

  # Resolve relative to session workspace if set
  if [[ "$path" != /* ]]; then
    local workspace="${BASHCLAW_TOOL_WORKSPACE:-$(pwd)}"
    path="${workspace}/${path}"
  fi

  if [[ ! -f "$path" ]]; then
    jq -nc --arg p "$path" '{"error": "file not found", "path": $p}'
    return 1
  fi

  offset="${offset:-1}"
  limit="${limit:-$TOOL_READ_FILE_MAX_LINES}"

  if [ "$offset" -lt 1 ] 2>/dev/null; then
    offset=1
  fi
  if [ "$limit" -gt "$TOOL_READ_FILE_MAX_LINES" ] 2>/dev/null; then
    limit="$TOOL_READ_FILE_MAX_LINES"
  fi

  local total_lines
  total_lines="$(wc -l < "$path" | tr -d '[:space:]')"

  local content
  content="$(tail -n "+${offset}" "$path" | head -n "$limit")"

  local truncated="false"
  local end_line=$((offset + limit - 1))
  if [ "$end_line" -lt "$total_lines" ] 2>/dev/null; then
    truncated="true"
  fi

  jq -nc \
    --arg path "$path" \
    --arg content "$content" \
    --argjson offset "$offset" \
    --argjson limit "$limit" \
    --argjson total "$total_lines" \
    --arg trunc "$truncated" \
    '{path: $path, content: $content, offset: $offset, limit: $limit, totalLines: $total, truncated: ($trunc == "true")}'
}

# ---- Tool: write_file ----

tool_write_file() {
  local input="$1"
  require_command jq "write_file tool requires jq"

  local path content append_flag
  path="$(printf '%s' "$input" | jq -r '.path // empty')"
  content="$(printf '%s' "$input" | jq -r '.content // empty')"
  append_flag="$(printf '%s' "$input" | jq -r '.append // false')"

  if [[ -z "$path" ]]; then
    printf '{"error": "path parameter is required"}'
    return 1
  fi

  if [[ -z "$content" ]]; then
    printf '{"error": "content parameter is required"}'
    return 1
  fi

  # Resolve relative to session workspace if set
  if [[ "$path" != /* ]]; then
    local workspace="${BASHCLAW_TOOL_WORKSPACE:-$(pwd)}"
    path="${workspace}/${path}"
  fi

  # Path traversal protection
  case "$path" in
    */../*|*/..)
      printf '{"error": "path traversal not allowed"}'
      return 1
      ;;
  esac

  local dir
  dir="$(dirname "$path")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || {
      jq -nc --arg p "$path" '{"error": "cannot create parent directory", "path": $p}'
      return 1
    }
  fi

  if [[ "$append_flag" == "true" ]]; then
    printf '%s' "$content" >> "$path" || {
      jq -nc --arg p "$path" '{"error": "write failed", "path": $p}'
      return 1
    }
  else
    printf '%s' "$content" > "$path" || {
      jq -nc --arg p "$path" '{"error": "write failed", "path": $p}'
      return 1
    }
  fi

  local size
  size="$(file_size_bytes "$path")"

  jq -nc --arg p "$path" --argjson s "$size" --arg a "$append_flag" \
    '{path: $p, written: true, size: $s, appended: ($a == "true")}'
}

# ---- Tool: list_files ----

tool_list_files() {
  local input="$1"
  require_command jq "list_files tool requires jq"

  local path pattern recursive
  path="$(printf '%s' "$input" | jq -r '.path // empty')"
  pattern="$(printf '%s' "$input" | jq -r '.pattern // empty')"
  recursive="$(printf '%s' "$input" | jq -r '.recursive // false')"

  if [[ -z "$path" ]]; then
    printf '{"error": "path parameter is required"}'
    return 1
  fi

  # Resolve relative paths
  if [[ "$path" != /* ]]; then
    local workspace="${BASHCLAW_TOOL_WORKSPACE:-$(pwd)}"
    path="${workspace}/${path}"
  fi

  if [[ ! -d "$path" ]]; then
    jq -nc --arg p "$path" '{"error": "directory not found", "path": $p}'
    return 1
  fi

  local entries="[]"
  local count=0

  if [[ "$recursive" == "true" ]]; then
    local find_args=()
    if [[ -n "$pattern" ]]; then
      find_args=(-name "$pattern")
    fi
    local f
    local entries_ndjson=""
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [ "$count" -ge "$TOOL_LIST_FILES_MAX" ]; then
        break
      fi
      local ftype="file"
      if [[ -d "$f" ]]; then
        ftype="directory"
      fi
      local rel
      rel="${f#${path}/}"
      entries_ndjson="${entries_ndjson}$(jq -nc --arg n "$rel" --arg t "$ftype" '{name: $n, type: $t}')"$'\n'
      count=$((count + 1))
    done <<EOF
$(find "$path" -maxdepth 10 "${find_args[@]}" 2>/dev/null | head -n "$TOOL_LIST_FILES_MAX")
EOF
    if [[ -n "$entries_ndjson" ]]; then
      entries="$(printf '%s' "$entries_ndjson" | jq -s '.')"
    fi
  else
    local f
    local entries_ndjson=""
    for f in "${path}"/*; do
      [[ -e "$f" ]] || continue
      if [ "$count" -ge "$TOOL_LIST_FILES_MAX" ]; then
        break
      fi
      local name
      name="$(basename "$f")"
      # Apply pattern filter if specified
      if [[ -n "$pattern" ]]; then
        case "$name" in
          $pattern) ;;
          *) continue ;;
        esac
      fi
      local ftype="file"
      if [[ -d "$f" ]]; then
        ftype="directory"
      elif [[ -L "$f" ]]; then
        ftype="symlink"
      fi
      entries_ndjson="${entries_ndjson}$(jq -nc --arg n "$name" --arg t "$ftype" '{name: $n, type: $t}')"$'\n'
      count=$((count + 1))
    done
    if [[ -n "$entries_ndjson" ]]; then
      entries="$(printf '%s' "$entries_ndjson" | jq -s '.')"
    fi
  fi

  jq -nc --arg p "$path" --argjson e "$entries" --argjson c "$count" \
    '{path: $p, entries: $e, count: $c, truncated: ($c >= '"$TOOL_LIST_FILES_MAX"')}'
}

# ---- Tool: file_search ----

tool_file_search() {
  local input="$1"
  require_command jq "file_search tool requires jq"

  local path name_pattern content_pattern max_results
  path="$(printf '%s' "$input" | jq -r '.path // empty')"
  name_pattern="$(printf '%s' "$input" | jq -r '.name // empty')"
  content_pattern="$(printf '%s' "$input" | jq -r '.content // empty')"
  max_results="$(printf '%s' "$input" | jq -r '.maxResults // empty')"
  max_results="${max_results:-50}"

  if [[ -z "$path" ]]; then
    printf '{"error": "path parameter is required"}'
    return 1
  fi

  # Resolve relative paths
  if [[ "$path" != /* ]]; then
    local workspace="${BASHCLAW_TOOL_WORKSPACE:-$(pwd)}"
    path="${workspace}/${path}"
  fi

  if [[ ! -d "$path" ]]; then
    jq -nc --arg p "$path" '{"error": "directory not found", "path": $p}'
    return 1
  fi

  if [[ -z "$name_pattern" && -z "$content_pattern" ]]; then
    printf '{"error": "at least one of name or content parameter is required"}'
    return 1
  fi

  local results_ndjson=""
  local count=0

  if [[ -n "$name_pattern" && -z "$content_pattern" ]]; then
    # Name-only search
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [ "$count" -ge "$max_results" ]; then
        break
      fi
      local rel="${f#${path}/}"
      results_ndjson="${results_ndjson}$(jq -nc --arg p "$rel" '{path: $p}')"$'\n'
      count=$((count + 1))
    done <<EOF
$(find "$path" -name "$name_pattern" -type f 2>/dev/null | head -n "$max_results")
EOF
  elif [[ -z "$name_pattern" && -n "$content_pattern" ]]; then
    # Content-only search using grep
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [ "$count" -ge "$max_results" ]; then
        break
      fi
      local rel="${f#${path}/}"
      local match_line
      match_line="$(grep -n -m1 "$content_pattern" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
      results_ndjson="${results_ndjson}$(jq -nc --arg p "$rel" --arg l "${match_line:-0}" \
        '{path: $p, line: ($l | tonumber)}')"$'\n'
      count=$((count + 1))
    done <<EOF
$(grep -rl "$content_pattern" "$path" 2>/dev/null | head -n "$max_results")
EOF
  else
    # Combined name + content search
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if grep -q "$content_pattern" "$f" 2>/dev/null; then
        if [ "$count" -ge "$max_results" ]; then
          break
        fi
        local rel="${f#${path}/}"
        local match_line
        match_line="$(grep -n -m1 "$content_pattern" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
        results_ndjson="${results_ndjson}$(jq -nc --arg p "$rel" --arg l "${match_line:-0}" \
          '{path: $p, line: ($l | tonumber)}')"$'\n'
        count=$((count + 1))
      fi
    done <<EOF
$(find "$path" -name "$name_pattern" -type f 2>/dev/null | head -n 500)
EOF
  fi

  local results
  if [[ -n "$results_ndjson" ]]; then
    results="$(printf '%s' "$results_ndjson" | jq -s '.')"
  else
    results="[]"
  fi
  jq -nc --arg p "$path" --argjson r "$results" --argjson c "$count" \
    '{path: $p, results: $r, count: $c}'
}

# ---- Tool: spawn ----

tool_spawn() {
  local input="$1"
  require_command jq "spawn tool requires jq"

  local task label
  task="$(printf '%s' "$input" | jq -r '.task // empty')"
  label="$(printf '%s' "$input" | jq -r '.label // empty')"
  label="${label:-background}"

  if [[ -z "$task" ]]; then
    printf '{"error": "task parameter is required"}'
    return 1
  fi

  local spawn_id
  spawn_id="$(uuid_generate | cut -c1-8)"
  local spawn_dir="${BASHCLAW_STATE_DIR:?}/spawn"
  mkdir -p "$spawn_dir"

  local started_at
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  printf '{"id":"%s","label":"%s","status":"running","started_at":"%s"}\n' \
    "$spawn_id" "$label" "$started_at" > "${spawn_dir}/${spawn_id}.json"

  (
    local result
    result="$(engine_run "main" "$task" "spawn" "subagent" "true" 2>/dev/null)" || result="error: subagent failed"
    jq -nc \
      --arg id "$spawn_id" \
      --arg label "$label" \
      --arg result "$result" \
      --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      '{id: $id, label: $label, status: "completed", result: $result, completed_at: $ts}' \
      > "${spawn_dir}/${spawn_id}.json"
  ) &

  printf 'Subagent "%s" started (id: %s). Use spawn_status to check progress.' "$label" "$spawn_id"
}

# ---- Tool: spawn_status ----

tool_spawn_status() {
  local input="$1"
  require_command jq "spawn_status tool requires jq"

  local task_id
  task_id="$(printf '%s' "$input" | jq -r '.task_id // empty')"

  if [[ -z "$task_id" ]]; then
    printf '{"error": "task_id parameter is required"}'
    return 1
  fi

  local status_file="${BASHCLAW_STATE_DIR:?}/spawn/${task_id}.json"
  if [[ -f "$status_file" ]]; then
    cat "$status_file"
  else
    printf '{"error":"task not found","id":"%s"}' "$task_id"
  fi
}

# ---- SSRF helper ----

_ssrf_is_blocked() {
  local hostname="$1"

  if _ssrf_is_private_pattern "$hostname"; then
    return 0
  fi

  # DNS resolution check
  if is_command_available dig; then
    local resolved
    resolved="$(dig +short "$hostname" 2>/dev/null | head -1)"
    if [[ -n "$resolved" ]] && _ssrf_is_private_pattern "$resolved"; then
      log_warn "SSRF blocked: $hostname resolves to private IP $resolved"
      return 0
    fi
  elif is_command_available host; then
    local resolved
    resolved="$(host "$hostname" 2>/dev/null | grep 'has address' | head -1 | awk '{print $NF}')"
    if [[ -n "$resolved" ]] && _ssrf_is_private_pattern "$resolved"; then
      log_warn "SSRF blocked: $hostname resolves to private IP $resolved"
      return 0
    fi
  fi

  return 1
}
