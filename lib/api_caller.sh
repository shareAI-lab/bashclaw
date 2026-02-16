#!/usr/bin/env bash
# API calling functions with shared retry logic for all providers

# ---- Shared Retry Logic ----

_api_call_with_retry() {
  local max_retries="${1:-3}"
  local url="$2"
  local headers_file="$3"
  local body="$4"
  local response_file="$5"
  local provider_label="${6:-API}"

  local attempt=0
  local http_code
  while (( attempt < max_retries )); do
    attempt=$((attempt + 1))

    http_code="$(curl -sS --max-time 120 \
      -o "$response_file" -w '%{http_code}' \
      -H @"$headers_file" \
      -d "$body" \
      "$url" 2>/dev/null)" || http_code="000"

    case "$http_code" in
      200|201) printf '%s' "$http_code"; return 0 ;;
      429|500|502|503)
        if (( attempt < max_retries )); then
          local delay=$((2 * (1 << (attempt - 1)) + RANDOM % 3))
          log_warn "$provider_label HTTP $http_code, retry ${attempt}/${max_retries} in ${delay}s"
          sleep "$delay"
          continue
        fi
        ;;
    esac
    break
  done
  printf '%s' "$http_code"
  return 1
}

# Write headers to a temp file for use with curl -H @file
_api_write_headers() {
  local headers_file="$1"
  shift
  : > "$headers_file"
  local header
  for header in "$@"; do
    printf '%s\n' "$header" >> "$headers_file"
  done
}

# Common post-call error checking and response handling
_api_check_response() {
  local response="$1"
  local http_code="$2"
  local provider_label="$3"

  if [[ -z "$response" ]]; then
    log_error "$provider_label API request failed (HTTP $http_code)"
    printf '{"error": {"message": "API request failed", "status": "%s"}}' "$http_code"
    return 1
  fi

  local error_msg
  error_msg="$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)"
  if [[ -n "$error_msg" ]]; then
    log_error "$provider_label API error: $error_msg"
    printf '%s' "$response"
    return 1
  fi

  return 0
}

# ---- Anthropic API ----

agent_call_anthropic() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_anthropic requires curl"
  require_command jq "agent_call_anthropic requires jq"

  local api_key
  api_key="$(agent_resolve_api_key "anthropic")"

  local api_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}/v1/messages"

  local body
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    body="$(jq -nc \
      --arg model "$model" \
      --arg system "$system_prompt" \
      --argjson messages "$messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$tools_json" \
      '{
        model: $model,
        system: $system,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp,
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg model "$model" \
      --arg system "$system_prompt" \
      --argjson messages "$messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      '{
        model: $model,
        system: $system,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp
      }')"
  fi

  log_debug "Anthropic API call: model=$model url=$api_url"

  local response_file headers_file
  response_file="$(tmpfile "anthropic_resp")"
  headers_file="$(tmpfile "anthropic_headers")"

  _api_write_headers "$headers_file" \
    "x-api-key: ${api_key}" \
    "anthropic-version: 2023-06-01" \
    "content-type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "Anthropic")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "Anthropic"; then
    return 1
  fi

  printf '%s' "$response"
}

# ---- OpenAI-compatible API ----

agent_call_openai() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_openai requires curl"
  require_command jq "agent_call_openai requires jq"

  local api_key
  api_key="$(agent_resolve_api_key "openai")"

  local provider
  provider="$(agent_resolve_provider "$model")"
  local api_base
  api_base="$(_provider_api_url "$provider")"
  if [[ -z "$api_base" ]]; then
    api_base="${OPENAI_BASE_URL:-https://api.openai.com}"
  fi
  local api_key_resolved
  api_key_resolved="$(agent_resolve_api_key "$provider")"

  local api_url="${api_base}/v1/chat/completions"

  local max_tokens_field="max_tokens"
  local compat_field
  compat_field="$(_model_get_compat_field "$model" "max_tokens_field")"
  if [[ -n "$compat_field" ]]; then
    max_tokens_field="$compat_field"
  fi

  local oai_messages
  oai_messages="$(printf '%s' "$messages" | jq --arg sys "$system_prompt" \
    '[{role: "system", content: $sys}] + .')"

  local oai_tools=""
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    oai_tools="$(printf '%s' "$tools_json" | jq '[.[] | {
      type: "function",
      function: {
        name: .name,
        description: .description,
        parameters: .input_schema
      }
    }]')"
  fi

  local body
  if [[ -n "$oai_tools" && "$oai_tools" != "[]" ]]; then
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$oai_tools" \
      --arg mtf "$max_tokens_field" \
      '{
        model: $model,
        messages: $messages,
        ($mtf): $max_tokens,
        temperature: $temp,
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --arg mtf "$max_tokens_field" \
      '{
        model: $model,
        messages: $messages,
        ($mtf): $max_tokens,
        temperature: $temp
      }')"
  fi

  log_debug "OpenAI API call: model=$model"

  local response_file headers_file
  response_file="$(tmpfile "openai_resp")"
  headers_file="$(tmpfile "openai_headers")"

  _api_write_headers "$headers_file" \
    "Authorization: Bearer ${api_key_resolved}" \
    "Content-Type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "OpenAI")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "OpenAI"; then
    return 1
  fi

  _openai_normalize_response "$response"
}

_openai_normalize_response() {
  local response="$1"

  local stop_reason
  stop_reason="$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // "stop"')"

  local mapped_reason="end_turn"
  case "$stop_reason" in
    tool_calls) mapped_reason="tool_use" ;;
    length)     mapped_reason="max_tokens" ;;
    *)          mapped_reason="end_turn" ;;
  esac

  local has_tool_calls
  has_tool_calls="$(printf '%s' "$response" | jq '.choices[0].message.tool_calls | length > 0')"

  if [[ "$has_tool_calls" == "true" ]]; then
    printf '%s' "$response" | jq --arg sr "$mapped_reason" '{
      stop_reason: $sr,
      content: [
        (if .choices[0].message.content then {type: "text", text: .choices[0].message.content} else empty end),
        (.choices[0].message.tool_calls[]? | {
          type: "tool_use",
          id: .id,
          name: .function.name,
          input: (.function.arguments | fromjson? // {})
        })
      ],
      usage: .usage
    }'
  else
    local text
    text="$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""')"
    printf '%s' "$response" | jq --arg sr "$mapped_reason" --arg text "$text" '{
      stop_reason: $sr,
      content: [{type: "text", text: $text}],
      usage: .usage
    }'
  fi
}

# ---- Google Gemini API ----

agent_call_google() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_google requires curl"
  require_command jq "agent_call_google requires jq"

  local api_key
  api_key="$(agent_resolve_api_key "google")"

  local api_url="${GOOGLE_AI_BASE_URL:-https://generativelanguage.googleapis.com}/v1beta/models/${model}:generateContent?key=${api_key}"

  local gemini_contents
  gemini_contents="$(printf '%s' "$messages" | jq '[
    .[] |
    if .role == "user" then
      {role: "user", parts: [{text: .content}]}
    elif .role == "assistant" then
      {role: "model", parts: [{text: .content}]}
    else
      empty
    end
  ]')"

  local gemini_tools=""
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    gemini_tools="$(printf '%s' "$tools_json" | jq '[{
      function_declarations: [.[] | {
        name: .name,
        description: .description,
        parameters: .input_schema
      }]
    }]')"
  fi

  local body
  if [[ -n "$gemini_tools" && "$gemini_tools" != "[]" ]]; then
    body="$(jq -nc \
      --arg sys "$system_prompt" \
      --argjson contents "$gemini_contents" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$gemini_tools" \
      '{
        system_instruction: {parts: [{text: $sys}]},
        contents: $contents,
        generationConfig: {maxOutputTokens: $max_tokens, temperature: $temp},
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg sys "$system_prompt" \
      --argjson contents "$gemini_contents" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      '{
        system_instruction: {parts: [{text: $sys}]},
        contents: $contents,
        generationConfig: {maxOutputTokens: $max_tokens, temperature: $temp}
      }')"
  fi

  log_debug "Google API call: model=$model"

  local response_file headers_file
  response_file="$(tmpfile "google_resp")"
  headers_file="$(tmpfile "google_headers")"

  _api_write_headers "$headers_file" \
    "Content-Type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "Google")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "Google"; then
    return 1
  fi

  _google_normalize_response "$response"
}

_google_normalize_response() {
  local response="$1"

  local finish_reason
  finish_reason="$(printf '%s' "$response" | jq -r '.candidates[0].finishReason // "STOP"')"

  local mapped_reason="end_turn"
  case "$finish_reason" in
    STOP)           mapped_reason="end_turn" ;;
    MAX_TOKENS)     mapped_reason="max_tokens" ;;
    SAFETY)         mapped_reason="end_turn" ;;
    *)              mapped_reason="end_turn" ;;
  esac

  local has_function_calls
  has_function_calls="$(printf '%s' "$response" | jq '
    [.candidates[0].content.parts[]? | select(.functionCall)] | length > 0
  ')"

  if [[ "$has_function_calls" == "true" ]]; then
    printf '%s' "$response" | jq --arg sr "$mapped_reason" '{
      stop_reason: $sr,
      content: [
        (.candidates[0].content.parts[]? |
          if .text then {type: "text", text: .text}
          elif .functionCall then {
            type: "tool_use",
            id: ("gemini_" + .functionCall.name + "_" + (now | tostring)),
            name: .functionCall.name,
            input: (.functionCall.args // {})
          }
          else empty
          end
        )
      ],
      usage: {
        input_tokens: (.usageMetadata.promptTokenCount // 0),
        output_tokens: (.usageMetadata.candidatesTokenCount // 0)
      }
    }'
  else
    local text
    text="$(printf '%s' "$response" | jq -r '
      [.candidates[0].content.parts[]? | select(.text) | .text] | join("")
    ')"
    printf '%s' "$response" | jq --arg sr "$mapped_reason" --arg text "$text" '{
      stop_reason: $sr,
      content: [{type: "text", text: $text}],
      usage: {
        input_tokens: (.usageMetadata.promptTokenCount // 0),
        output_tokens: (.usageMetadata.candidatesTokenCount // 0)
      }
    }'
  fi
}

# ---- OpenRouter API (OpenAI-compatible) ----

agent_call_openrouter() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_openrouter requires curl"
  require_command jq "agent_call_openrouter requires jq"

  local api_key
  api_key="$(agent_resolve_api_key "openrouter")"

  local api_url="${OPENROUTER_BASE_URL:-https://openrouter.ai/api}/v1/chat/completions"

  local oai_messages
  oai_messages="$(printf '%s' "$messages" | jq --arg sys "$system_prompt" \
    '[{role: "system", content: $sys}] + .')"

  local oai_tools=""
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    oai_tools="$(printf '%s' "$tools_json" | jq '[.[] | {
      type: "function",
      function: {
        name: .name,
        description: .description,
        parameters: .input_schema
      }
    }]')"
  fi

  local body
  if [[ -n "$oai_tools" && "$oai_tools" != "[]" ]]; then
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$oai_tools" \
      '{
        model: $model,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp,
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      '{
        model: $model,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp
      }')"
  fi

  log_debug "OpenRouter API call: model=$model"

  local response_file headers_file
  response_file="$(tmpfile "openrouter_resp")"
  headers_file="$(tmpfile "openrouter_headers")"

  _api_write_headers "$headers_file" \
    "Authorization: Bearer ${api_key}" \
    "Content-Type: application/json" \
    "HTTP-Referer: https://github.com/bashclaw/bashclaw"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "OpenRouter")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "OpenRouter"; then
    return 1
  fi

  _openai_normalize_response "$response"
}
