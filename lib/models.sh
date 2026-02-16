#!/usr/bin/env bash
# Model catalog, resolution, aliases, and provider detection

# ---- Model Catalog (data-driven from models.json) ----

_MODELS_CATALOG_CACHE=""
_MODELS_CATALOG_PATH=""

_models_catalog_path() {
  if [[ -z "$_MODELS_CATALOG_PATH" ]]; then
    _MODELS_CATALOG_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/models.json"
  fi
  printf '%s' "$_MODELS_CATALOG_PATH"
}

_models_catalog_load() {
  if [[ -n "$_MODELS_CATALOG_CACHE" ]]; then
    printf '%s' "$_MODELS_CATALOG_CACHE"
    return
  fi
  local path
  path="$(_models_catalog_path)"
  if [[ -f "$path" ]]; then
    _MODELS_CATALOG_CACHE="$(cat "$path")"
  else
    _MODELS_CATALOG_CACHE='{}'
  fi
  printf '%s' "$_MODELS_CATALOG_CACHE"
}

# Resolve model alias to actual model ref (may include provider/ prefix)
_model_resolve_alias() {
  local model="$1"
  local catalog
  catalog="$(_models_catalog_load)"
  local resolved
  resolved="$(printf '%s' "$catalog" | jq -r --arg m "$model" '.aliases[$m] // empty' 2>/dev/null)"
  if [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$model"
  fi
}

# Parse "provider/model" reference format.
# If input contains "/", split into provider and model.
# Otherwise resolve alias first, then look up provider from catalog.
# Sets two variables: _PARSED_PROVIDER and _PARSED_MODEL
_parse_model_ref() {
  local raw="$1"
  _PARSED_PROVIDER=""
  _PARSED_MODEL=""

  local resolved
  resolved="$(_model_resolve_alias "$raw")"

  if [[ "$resolved" == *"/"* ]]; then
    _PARSED_PROVIDER="${resolved%%/*}"
    _PARSED_MODEL="${resolved#*/}"
  else
    _PARSED_MODEL="$resolved"
  fi
}

# Look up which provider owns a model ID by searching all providers
_model_provider() {
  local model="$1"
  local catalog
  catalog="$(_models_catalog_load)"
  local provider
  provider="$(printf '%s' "$catalog" | jq -r --arg m "$model" '
    .providers | to_entries[] | select(.value.models[]?.id == $m) | .key
  ' 2>/dev/null | head -1)"
  printf '%s' "$provider"
}

# Get a field from a model definition across all providers
_model_get_field() {
  local model="$1"
  local field="$2"
  local catalog
  catalog="$(_models_catalog_load)"
  local val
  val="$(printf '%s' "$catalog" | jq -r --arg m "$model" --arg f "$field" '
    [.providers[].models[] | select(.id == $m)] | .[0][$f] // empty
  ' 2>/dev/null)"
  printf '%s' "$val"
}

# Get a compat flag from a model definition
_model_get_compat_field() {
  local model="$1"
  local field="$2"
  local catalog
  catalog="$(_models_catalog_load)"
  local val
  val="$(printf '%s' "$catalog" | jq -r --arg m "$model" --arg f "$field" '
    [.providers[].models[] | select(.id == $m)] | .[0].compat[$f] // empty
  ' 2>/dev/null)"
  printf '%s' "$val"
}

_model_max_tokens() {
  local model="$1"
  local tokens
  tokens="$(_model_get_field "$model" "max_tokens")"
  if [[ -z "$tokens" ]]; then
    printf '4096'
  else
    printf '%s' "$tokens"
  fi
}

_model_context_window() {
  local model="$1"
  local window
  window="$(_model_get_field "$model" "context_window")"
  if [[ -z "$window" ]]; then
    printf '128000'
  else
    printf '%s' "$window"
  fi
}

# ---- Model Resolution ----

agent_resolve_model() {
  local agent_id="${1:-main}"

  local model
  model="$(config_agent_get "$agent_id" "model" "")"
  if [[ -z "$model" ]]; then
    model="${MODEL_ID:-claude-opus-4-6}"
  fi

  _parse_model_ref "$model"
  printf '%s' "$_PARSED_MODEL"
}

agent_resolve_provider() {
  local model="$1"

  if [[ -n "${_PARSED_PROVIDER:-}" ]]; then
    printf '%s' "$_PARSED_PROVIDER"
    _PARSED_PROVIDER=""
    return
  fi

  local provider
  provider="$(_model_provider "$model")"
  if [[ -n "$provider" ]]; then
    printf '%s' "$provider"
    return
  fi

  case "$model" in
    claude-*)                    printf 'anthropic'; return ;;
    gpt-*|o1*|o3*|o4*)          printf 'openai'; return ;;
    gemini-*)                    printf 'google'; return ;;
    deepseek-*)                  printf 'deepseek'; return ;;
    qwen-*|qwq-*)               printf 'qwen'; return ;;
    glm-*)                       printf 'zhipu'; return ;;
    moonshot-*|kimi-*)           printf 'moonshot'; return ;;
    MiniMax-*|minimax-*|abab*)   printf 'minimax'; return ;;
    mimo-*)                      printf 'xiaomi'; return ;;
    ernie-*)                     printf 'qianfan'; return ;;
    nvidia/*)                    printf 'nvidia'; return ;;
    llama-*|meta/*)              printf 'groq'; return ;;
    grok-*)                      printf 'xai'; return ;;
    mistral-*)                   printf 'mistral'; return ;;
  esac

  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf 'openrouter'
    return
  fi

  printf 'anthropic'
}

# Data-driven API key resolution from models.json providers section
agent_resolve_api_key() {
  local provider="$1"

  require_command jq "agent_resolve_api_key requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  local key_env
  key_env="$(printf '%s' "$catalog" | jq -r --arg p "$provider" \
    '.providers[$p].api_key_env // empty' 2>/dev/null)"

  if [[ -z "$key_env" ]]; then
    log_fatal "Unknown provider: $provider (not found in models.json)"
  fi

  local key
  eval "key=\"\${${key_env}:-}\""

  if [[ -z "$key" ]]; then
    case "$provider" in
      google)  key="${GOOGLE_API_KEY:-}" ;;
      zhipu)   key="${ZHIPU_API_KEY:-}" ;;
    esac
  fi

  if [[ -z "$key" ]]; then
    case "$provider" in
      ollama|vllm) key="no-key-required"; return 0 ;;
    esac
  fi

  if [[ -z "$key" ]]; then
    log_fatal "${key_env} is required for ${provider} provider"
  fi
  printf '%s' "$key"
}

# Data-driven API base URL resolution from models.json
_provider_api_url() {
  local provider="$1"

  local catalog
  catalog="$(_models_catalog_load)"

  local url_default
  url_default="$(printf '%s' "$catalog" | jq -r --arg p "$provider" \
    '.providers[$p].base_url // empty' 2>/dev/null)"

  local env_key
  case "$provider" in
    anthropic)  env_key="ANTHROPIC_BASE_URL" ;;
    openai)     env_key="OPENAI_BASE_URL" ;;
    google)     env_key="GOOGLE_AI_BASE_URL" ;;
    openrouter) env_key="OPENROUTER_BASE_URL" ;;
    ollama)     env_key="OLLAMA_BASE_URL" ;;
    vllm)       env_key="VLLM_BASE_URL" ;;
    *)          env_key="" ;;
  esac

  if [[ -n "$env_key" ]]; then
    local url_override
    eval "url_override=\"\${${env_key}:-}\""
    if [[ -n "$url_override" ]]; then
      printf '%s' "$url_override"
      return
    fi
  fi

  printf '%s' "$url_default"
}

# Resolve the API format for a provider (anthropic, openai, google)
_provider_api_format() {
  local provider="$1"

  local catalog
  catalog="$(_models_catalog_load)"
  local fmt
  fmt="$(printf '%s' "$catalog" | jq -r --arg p "$provider" \
    '.providers[$p].api // empty' 2>/dev/null)"

  if [[ -z "$fmt" ]]; then
    printf 'openai'
  else
    printf '%s' "$fmt"
  fi
}

# Get the API version header value for a provider (e.g. anthropic)
_provider_api_version() {
  local provider="$1"
  local catalog
  catalog="$(_models_catalog_load)"
  printf '%s' "$(printf '%s' "$catalog" | jq -r --arg p "$provider" \
    '.providers[$p].api_version // empty' 2>/dev/null)"
}

# Resolve the next fallback model from the configured fallback chain.
agent_resolve_fallback_model() {
  local current_model="$1"

  require_command jq "agent_resolve_fallback_model requires jq"

  local fallbacks
  fallbacks="$(config_get_raw '.agents.defaults.fallbackModels // []' 2>/dev/null)"
  if [[ -z "$fallbacks" || "$fallbacks" == "null" || "$fallbacks" == "[]" ]]; then
    printf ''
    return
  fi

  local next
  next="$(printf '%s' "$fallbacks" | jq -r --arg cur "$current_model" '
    . as $list |
    (to_entries | map(select(.value == $cur)) | .[0].key // -1) as $idx |
    if $idx == -1 then .[0]
    elif ($idx + 1) < length then .[$idx + 1]
    else empty
    end
  ' 2>/dev/null)"

  printf '%s' "$next"
}

# ---- Provider Registry Enhancement ----

# List all supported providers with their status (available/missing key/unknown).
provider_registry_list() {
  require_command jq "provider_registry_list requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  local providers
  providers="$(printf '%s' "$catalog" | jq -r '.providers | keys[]' 2>/dev/null)"

  local ndjson=""
  local p
  for p in $providers; do
    local key_env
    key_env="$(printf '%s' "$catalog" | jq -r --arg p "$p" '.providers[$p].api_key_env // empty' 2>/dev/null)"

    local status="unknown"
    if [[ -n "$key_env" ]]; then
      local key_val
      eval "key_val=\"\${${key_env}:-}\""
      if [[ -n "$key_val" ]]; then
        status="available"
      else
        # Some providers don't require a key
        case "$p" in
          ollama|vllm) status="available" ;;
          *) status="missing_key" ;;
        esac
      fi
    fi

    local base_url
    base_url="$(printf '%s' "$catalog" | jq -r --arg p "$p" '.providers[$p].base_url // empty' 2>/dev/null)"
    local api_format
    api_format="$(printf '%s' "$catalog" | jq -r --arg p "$p" '.providers[$p].api // "openai"' 2>/dev/null)"
    local model_count
    model_count="$(printf '%s' "$catalog" | jq --arg p "$p" '.providers[$p].models | length' 2>/dev/null)"

    ndjson="${ndjson}$(jq -nc \
      --arg name "$p" \
      --arg status "$status" \
      --arg key_env "$key_env" \
      --arg base_url "$base_url" \
      --arg api "$api_format" \
      --argjson models "$model_count" \
      '{name: $name, status: $status, key_env: $key_env, base_url: $base_url, api: $api, model_count: $models}')"$'\n'
  done

  if [[ -n "$ndjson" ]]; then
    printf '%s' "$ndjson" | jq -s '.'
  else
    printf '[]'
  fi
}

# Auto-detect the provider from a model name pattern.
# Returns the provider name or empty string if unknown.
provider_detect_from_model() {
  local model_string="${1:?model_string required}"

  # First try the catalog lookup
  local provider
  provider="$(_model_provider "$model_string")"
  if [[ -n "$provider" ]]; then
    printf '%s' "$provider"
    return
  fi

  # Fall back to pattern matching
  case "$model_string" in
    claude-*)                    printf 'anthropic' ;;
    gpt-*|o1*|o3*|o4*)          printf 'openai' ;;
    gemini-*)                    printf 'google' ;;
    deepseek-*)                  printf 'deepseek' ;;
    qwen-*|qwq-*)               printf 'qwen' ;;
    glm-*)                       printf 'zhipu' ;;
    moonshot-*|kimi-*)           printf 'moonshot' ;;
    MiniMax-*|minimax-*|abab*)   printf 'minimax' ;;
    mimo-*)                      printf 'xiaomi' ;;
    ernie-*)                     printf 'qianfan' ;;
    nvidia/*)                    printf 'nvidia' ;;
    llama-*|meta/*)              printf 'groq' ;;
    grok-*)                      printf 'xai' ;;
    mistral-*)                   printf 'mistral' ;;
    *)                           printf '' ;;
  esac
}

# Verify API connectivity for a provider (lightweight check).
# Returns 0 if healthy, 1 if not.
provider_health_check() {
  local provider_name="${1:?provider_name required}"

  require_command curl "provider_health_check requires curl"
  require_command jq "provider_health_check requires jq"

  local api_key
  api_key="$(agent_resolve_api_key "$provider_name" 2>/dev/null)" || {
    printf '{"provider":"%s","healthy":false,"error":"no API key"}' "$provider_name"
    return 1
  }

  local base_url
  base_url="$(_provider_api_url "$provider_name")"
  if [[ -z "$base_url" ]]; then
    printf '{"provider":"%s","healthy":false,"error":"no base URL"}' "$provider_name"
    return 1
  fi

  local api_format
  api_format="$(_provider_api_format "$provider_name")"

  local http_code
  case "$api_format" in
    anthropic)
      local api_version
      api_version="$(_provider_api_version "$provider_name")"
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: ${api_version:-2023-06-01}" \
        "${base_url}/v1/messages" 2>/dev/null)" || http_code="000"
      ;;
    google)
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        "${base_url}/v1beta/models?key=${api_key}" 2>/dev/null)" || http_code="000"
      ;;
    *)
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer $api_key" \
        "${base_url}/v1/models" 2>/dev/null)" || http_code="000"
      ;;
  esac

  local healthy="false"
  if [[ "$http_code" =~ ^[23] ]]; then
    healthy="true"
  fi

  jq -nc --arg p "$provider_name" --arg h "$healthy" --arg c "$http_code" \
    '{provider: $p, healthy: ($h == "true"), http_code: ($c | tonumber)}'

  if [[ "$healthy" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

# ---- Model Capabilities ----

# Check if a model supports vision (image input).
# Uses the capabilities.vision field from the catalog.
# Falls back to checking the input array for "image".
# Returns 0 (true) or 1 (false).
model_supports_vision() {
  local model_id="${1:?model_id required}"

  require_command jq "model_supports_vision requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  # Check capabilities.vision field first
  local vision
  vision="$(printf '%s' "$catalog" | jq -r --arg m "$model_id" '
    [.providers[].models[] | select(.id == $m)] | .[0].capabilities.vision // empty
  ' 2>/dev/null)"

  if [[ "$vision" == "true" ]]; then
    return 0
  elif [[ "$vision" == "false" ]]; then
    return 1
  fi

  # Fall back to checking input array for "image"
  local has_image
  has_image="$(printf '%s' "$catalog" | jq -r --arg m "$model_id" '
    [.providers[].models[] | select(.id == $m)] | .[0].input // [] | if (. | index("image")) then "true" else "false" end
  ' 2>/dev/null)"

  if [[ "$has_image" == "true" ]]; then
    return 0
  fi

  # Pattern-based fallback for models not in catalog
  case "$model_id" in
    claude-opus-4-6|claude-sonnet-4-*|claude-3-5-sonnet-*|claude-3-opus-*|claude-3-5-haiku-*)
      return 0 ;;
    gpt-4o|gpt-4o-mini|gpt-4-turbo|gpt-4-vision-*)
      return 0 ;;
    gemini-1.5-pro|gemini-1.5-flash|gemini-2.0-*)
      return 0 ;;
  esac

  return 1
}

# Return JSON with model capabilities.
# {vision, streaming, tools, context_window, max_output}
model_get_capabilities() {
  local model_id="${1:?model_id required}"

  require_command jq "model_get_capabilities requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  local caps
  caps="$(printf '%s' "$catalog" | jq --arg m "$model_id" '
    [.providers[].models[] | select(.id == $m)] | .[0] // null
    | if . == null then null
      else {
        vision: (.capabilities.vision // (if (.input // [] | index("image")) then true else false end)),
        streaming: (.capabilities.streaming // true),
        tools: (.capabilities.tools // true),
        context_window: (.context_window // 128000),
        max_output: (.max_tokens // 4096)
      }
      end
  ' 2>/dev/null)"

  if [[ -z "$caps" || "$caps" == "null" ]]; then
    # Return sensible defaults for unknown models
    jq -nc '{vision: false, streaming: true, tools: true, context_window: 128000, max_output: 4096}'
  else
    printf '%s' "$caps"
  fi
}

# Resolve provider from the catalog data instead of case-statement pattern matching.
# Falls back to pattern matching only if not found in catalog.
provider_resolve_from_catalog() {
  local model_id="${1:?model_id required}"

  require_command jq "provider_resolve_from_catalog requires jq"

  # Catalog lookup first
  local provider
  provider="$(_model_provider "$model_id")"
  if [[ -n "$provider" ]]; then
    printf '%s' "$provider"
    return 0
  fi

  # Pattern matching fallback
  case "$model_id" in
    claude-*)                    printf 'anthropic' ;;
    gpt-*|o1*|o3*|o4*)          printf 'openai' ;;
    gemini-*)                    printf 'google' ;;
    deepseek-*)                  printf 'deepseek' ;;
    qwen-*|qwq-*)               printf 'qwen' ;;
    glm-*)                       printf 'zhipu' ;;
    moonshot-*|kimi-*)           printf 'moonshot' ;;
    MiniMax-*|minimax-*|abab*)   printf 'minimax' ;;
    mimo-*)                      printf 'xiaomi' ;;
    ernie-*)                     printf 'qianfan' ;;
    nvidia/*)                    printf 'nvidia' ;;
    llama-*|meta/*)              printf 'groq' ;;
    grok-*)                      printf 'xai' ;;
    mistral-*)                   printf 'mistral' ;;
    *)                           printf '' ; return 1 ;;
  esac
}
