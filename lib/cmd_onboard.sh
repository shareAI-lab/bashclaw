#!/usr/bin/env bash
# Onboarding setup wizard for bashclaw

cmd_onboard() {
  printf 'Bashclaw Setup Wizard\n'
  printf '=====================\n\n'

  local step=1
  local total_steps=6

  # Step 1: Config initialization
  printf 'Step %d/%d: Configuration\n' "$step" "$total_steps"
  printf '------------------------\n'
  _onboard_config
  step=$((step + 1))
  printf '\n'

  # Step 2: API key setup
  printf 'Step %d/%d: API Key\n' "$step" "$total_steps"
  printf '-----------------\n'
  _onboard_api_key
  step=$((step + 1))
  printf '\n'

  # Step 3: Channel setup
  printf 'Step %d/%d: Channel Setup\n' "$step" "$total_steps"
  printf '----------------------\n'
  _onboard_channel
  step=$((step + 1))
  printf '\n'

  # Step 4: Gateway token
  printf 'Step %d/%d: Gateway\n' "$step" "$total_steps"
  printf '-----------------\n'
  _onboard_gateway
  step=$((step + 1))
  printf '\n'

  # Step 5: Engine selection
  printf 'Step %d/%d: Engine Selection\n' "$step" "$total_steps"
  printf '--------------------------\n'
  _onboard_engine
  step=$((step + 1))
  printf '\n'

  # Step 6: Daemon installation
  printf 'Step %d/%d: Daemon Setup\n' "$step" "$total_steps"
  printf '---------------------\n'
  _onboard_daemon
  printf '\n'

  printf 'Setup complete!\n'
  printf 'Run "bashclaw gateway" to start the server and open http://localhost:18789\n'
  printf 'Run "bashclaw agent -i" for interactive CLI mode.\n'
  printf 'Run "bashclaw daemon status" to check the service.\n'
}

_onboard_config() {
  local cfg_path
  cfg_path="$(config_path)"

  if [[ -f "$cfg_path" ]]; then
    printf 'Config already exists: %s\n' "$cfg_path"
    printf 'Overwrite? [y/N]: '
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      printf 'Keeping existing config.\n'
      return 0
    fi
    config_backup
    rm -f "$cfg_path"
  fi

  config_init_default
  workspace_init
  printf 'Workspace initialized: %s\n' "${BASHCLAW_STATE_DIR}/workspace"
}

_onboard_api_key() {
  local env_file="${BASHCLAW_STATE_DIR:?}/.env"

  # Check existing
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    printf 'ANTHROPIC_API_KEY is already set in environment.\n'
    _onboard_verify_api_key "anthropic" "$ANTHROPIC_API_KEY"
    return 0
  fi

  if [[ -f "$env_file" ]] && grep -q 'ANTHROPIC_API_KEY' "$env_file" 2>/dev/null; then
    printf 'API key already configured in %s\n' "$env_file"
    return 0
  fi

  printf 'Choose provider:\n'
  printf '  1) Anthropic (Claude)\n'
  printf '  2) OpenAI (GPT)\n'
  printf '  3) DeepSeek\n'
  printf 'Choice [1]: '
  local choice
  read -r choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      printf 'Enter your Anthropic API key: '
      local api_key
      read -r -s api_key
      printf '\n'
      if [[ -z "$api_key" ]]; then
        log_warn "No API key provided, skipping"
        return 0
      fi
      _onboard_validate_key_format "anthropic" "$api_key"
      if ! _onboard_verify_api_key "anthropic" "$api_key"; then
        printf 'Save this key anyway? [y/N]: '
        local save_anyway
        read -r save_anyway
        if [[ "$save_anyway" != "y" && "$save_anyway" != "Y" ]]; then
          printf 'API key not saved.\n'
          return 0
        fi
      fi
      printf 'ANTHROPIC_API_KEY=%s\n' "$api_key" >> "$env_file"
      chmod 600 "$env_file" 2>/dev/null || true
      printf 'API key saved to %s\n' "$env_file"
      ;;
    2)
      printf 'Enter your OpenAI API key: '
      local api_key
      read -r -s api_key
      printf '\n'
      if [[ -z "$api_key" ]]; then
        log_warn "No API key provided, skipping"
        return 0
      fi
      _onboard_validate_key_format "openai" "$api_key"
      if ! _onboard_verify_api_key "openai" "$api_key"; then
        printf 'Save this key anyway? [y/N]: '
        local save_anyway
        read -r save_anyway
        if [[ "$save_anyway" != "y" && "$save_anyway" != "Y" ]]; then
          printf 'API key not saved.\n'
          return 0
        fi
      fi
      printf 'OPENAI_API_KEY=%s\n' "$api_key" >> "$env_file"
      chmod 600 "$env_file" 2>/dev/null || true
      config_set '.agents.defaults.model' '"gpt-4o"'
      printf 'API key saved to %s\n' "$env_file"
      ;;
    3)
      printf 'Enter your DeepSeek API key: '
      local api_key
      read -r -s api_key
      printf '\n'
      if [[ -z "$api_key" ]]; then
        log_warn "No API key provided, skipping"
        return 0
      fi
      printf 'DEEPSEEK_API_KEY=%s\n' "$api_key" >> "$env_file"
      chmod 600 "$env_file" 2>/dev/null || true
      config_set '.agents.defaults.model' '"deepseek-chat"'
      printf 'API key saved to %s\n' "$env_file"
      ;;
    *)
      log_warn "Invalid choice, skipping API key setup"
      ;;
  esac
}

_onboard_validate_key_format() {
  local provider="$1"
  local api_key="$2"

  case "$provider" in
    anthropic)
      if [[ "$api_key" != sk-ant-* ]]; then
        log_warn "Key does not start with 'sk-ant-' (expected for Anthropic keys)"
        printf 'Warning: this does not look like a standard Anthropic API key.\n'
        printf 'Anthropic keys typically start with "sk-ant-".\n'
      fi
      ;;
    openai)
      if [[ "$api_key" != sk-* ]]; then
        log_warn "Key does not start with 'sk-' (expected for OpenAI keys)"
        printf 'Warning: this does not look like a standard OpenAI API key.\n'
        printf 'OpenAI keys typically start with "sk-".\n'
      fi
      ;;
    *)
      # No format check for other providers (e.g. deepseek)
      ;;
  esac
}

_onboard_verify_api_key() {
  local provider="$1"
  local api_key="$2"

  if ! is_command_available curl; then
    printf 'Cannot verify API key (curl not available).\n'
    return 0
  fi

  printf 'Verifying API key...'

  case "$provider" in
    anthropic)
      local response
      response="$(curl -sS --max-time 10 \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-haiku-3-20250307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "https://api.anthropic.com/v1/messages" 2>/dev/null)" || {
        printf ' failed (network error)\n'
        return 1
      }
      local error_type
      error_type="$(printf '%s' "$response" | jq -r '.error.type // empty' 2>/dev/null)"
      if [[ -n "$error_type" && "$error_type" != "null" ]]; then
        local error_msg
        error_msg="$(printf '%s' "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)"
        printf ' FAILED\n'
        printf 'Error: %s\n' "$error_msg"
        return 1
      fi
      printf ' OK\n'
      return 0
      ;;
    openai)
      local response
      response="$(curl -sS --max-time 10 \
        -H "Authorization: Bearer ${api_key}" \
        "https://api.openai.com/v1/models" 2>/dev/null)" || {
        printf ' failed (network error)\n'
        return 1
      }
      local error_msg
      error_msg="$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)"
      if [[ -n "$error_msg" && "$error_msg" != "null" ]]; then
        printf ' FAILED\n'
        printf 'Error: %s\n' "$error_msg"
        return 1
      fi
      printf ' OK\n'
      return 0
      ;;
    *)
      printf ' skipped (unknown provider)\n'
      return 0
      ;;
  esac
}

_onboard_channel() {
  printf 'Configure a messaging channel?\n'
  printf '  1) Telegram\n'
  printf '  2) Discord\n'
  printf '  3) Slack\n'
  printf '  4) Skip\n'
  printf 'Choice [4]: '
  local choice
  read -r choice
  choice="${choice:-4}"

  case "$choice" in
    1) onboard_channel "telegram" ;;
    2) onboard_channel "discord" ;;
    3) onboard_channel "slack" ;;
    4) printf 'Skipping channel setup.\n' ;;
    *) printf 'Skipping channel setup.\n' ;;
  esac
}

onboard_channel() {
  local channel="$1"

  case "$channel" in
    telegram)
      printf 'Enter Telegram Bot Token (from @BotFather): '
      local token
      read -r token
      if [[ -z "$token" ]]; then
        log_warn "No token provided"
        return 0
      fi
      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      printf 'BASHCLAW_TELEGRAM_TOKEN=%s\n' "$token" >> "$env_file"
      chmod 600 "$env_file" 2>/dev/null || true
      config_set '.channels.telegram' '{"enabled": true}'
      printf 'Telegram configured.\n'
      ;;
    discord)
      printf 'Enter Discord Bot Token: '
      local token
      read -r token
      if [[ -z "$token" ]]; then
        log_warn "No token provided"
        return 0
      fi
      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      printf 'BASHCLAW_DISCORD_TOKEN=%s\n' "$token" >> "$env_file"
      chmod 600 "$env_file" 2>/dev/null || true

      printf 'Enter Discord channel IDs to monitor (comma-separated): '
      local channel_ids
      read -r channel_ids
      if [[ -n "$channel_ids" ]]; then
        local json_array
        json_array="$(printf '%s' "$channel_ids" | tr ',' '\n' | jq -R '.' | jq -s '.')"
        config_set '.channels.discord' "$(jq -nc --argjson ids "$json_array" \
          '{enabled: true, monitorChannels: $ids}')"
      else
        config_set '.channels.discord' '{"enabled": true, "monitorChannels": []}'
      fi
      printf 'Discord configured.\n'
      ;;
    slack)
      printf 'Choose Slack mode:\n'
      printf '  1) Bot Token (recommended)\n'
      printf '  2) Webhook URL\n'
      printf 'Choice [1]: '
      local mode
      read -r mode
      mode="${mode:-1}"

      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      case "$mode" in
        1)
          printf 'Enter Slack Bot Token (xoxb-...): '
          local token
          read -r token
          if [[ -z "$token" ]]; then
            log_warn "No token provided"
            return 0
          fi
          printf 'BASHCLAW_SLACK_TOKEN=%s\n' "$token" >> "$env_file"
          chmod 600 "$env_file" 2>/dev/null || true

          printf 'Enter Slack channel IDs to monitor (comma-separated): '
          local channel_ids
          read -r channel_ids
          if [[ -n "$channel_ids" ]]; then
            local json_array
            json_array="$(printf '%s' "$channel_ids" | tr ',' '\n' | jq -R '.' | jq -s '.')"
            config_set '.channels.slack' "$(jq -nc --argjson ids "$json_array" \
              '{enabled: true, monitorChannels: $ids}')"
          else
            config_set '.channels.slack' '{"enabled": true, "monitorChannels": []}'
          fi
          ;;
        2)
          printf 'Enter Slack Webhook URL: '
          local url
          read -r url
          if [[ -z "$url" ]]; then
            log_warn "No URL provided"
            return 0
          fi
          printf 'BASHCLAW_SLACK_WEBHOOK_URL=%s\n' "$url" >> "$env_file"
          chmod 600 "$env_file" 2>/dev/null || true
          config_set '.channels.slack' '{"enabled": true}'
          ;;
      esac
      printf 'Slack configured.\n'
      ;;
    *)
      log_warn "Unknown channel: $channel"
      return 1
      ;;
  esac
}

_onboard_engine() {
  printf 'Select agent execution engine:\n'

  local has_claude="false"
  local has_codex="false"
  if is_command_available claude; then
    has_claude="true"
    local claude_ver
    claude_ver="$(claude --version 2>/dev/null || printf 'unknown')"
    printf '  Claude Code CLI detected: %s\n' "$claude_ver"
  fi
  if is_command_available codex; then
    has_codex="true"
    local codex_ver
    codex_ver="$(codex --version 2>/dev/null || printf 'unknown')"
    printf '  Codex CLI detected: %s\n' "$codex_ver"
  fi

  printf '\n'
  printf '  1) auto - detect best available CLI, fallback to builtin (recommended)\n'
  printf '  2) builtin - use BashClaw native API-calling agent loop\n'
  if [[ "$has_claude" == "true" ]]; then
    printf '  3) claude - always delegate to Claude Code CLI\n'
  fi
  printf 'Choice [1]: '
  local choice
  read -r choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      config_set '.agents.defaults.engine' '"auto"'
      printf 'Engine set to: auto\n'
      ;;
    2)
      config_set '.agents.defaults.engine' '"builtin"'
      printf 'Engine set to: builtin\n'
      ;;
    3)
      if [[ "$has_claude" != "true" ]]; then
        printf 'Claude Code CLI not found. Falling back to auto.\n'
        config_set '.agents.defaults.engine' '"auto"'
      else
        config_set '.agents.defaults.engine' '"claude"'
        printf 'Engine set to: claude\n'
      fi
      ;;
    *)
      printf 'Invalid choice, defaulting to auto.\n'
      config_set '.agents.defaults.engine' '"auto"'
      ;;
  esac
}

_onboard_gateway() {
  printf 'Configure gateway authentication token? [y/N]: '
  local answer
  read -r answer

  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    printf 'Skipping gateway auth.\n'
    return 0
  fi

  local token
  token="$(uuid_generate)"
  config_set '.gateway.auth.token' "\"${token}\""
  printf 'Gateway auth token generated: %s\n' "$token"
  printf 'Use this token in the Authorization header for API requests.\n'
}

_onboard_daemon() {
  printf 'Install bashclaw as a system service?\n'
  printf 'This will start the gateway automatically on boot.\n\n'

  local init_sys
  init_sys="$(_detect_init_system)"
  printf 'Detected init system: %s\n' "$init_sys"

  if [[ "$init_sys" == "none" ]]; then
    printf 'No supported init system found.\n'
    printf 'Use "bashclaw gateway -d" to run as a background daemon.\n'
    return 0
  fi

  printf 'Install and enable? [y/N]: '
  local answer
  read -r answer

  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    printf 'Skipping daemon setup.\n'
    printf 'You can install later with: bashclaw daemon install --enable\n'
    return 0
  fi

  daemon_install "" "true"
}
