#!/usr/bin/env bash
# Cross-platform daemon management for bashclaw
# Compatible with bash 3.2+

_DAEMON_LABEL="com.bashclaw.gateway"
_DAEMON_PID_FILE=""

_daemon_pid_file() {
  printf '%s/gateway.pid' "${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}"
}

_daemon_log_file() {
  printf '%s/logs/gateway.log' "${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}"
}

_detect_init_system() {
  if [[ -d "/data/data/com.termux" ]]; then
    if [[ -d "$HOME/.termux/boot" ]] || is_command_available termux-reload-settings; then
      printf 'termux-boot'
      return
    fi
    printf 'crontab'
    return
  fi

  case "$(uname -s)" in
    Darwin)
      printf 'launchd'
      ;;
    Linux)
      if is_command_available systemctl && systemctl --user status >/dev/null 2>&1; then
        printf 'systemd'
      elif is_command_available crontab; then
        printf 'crontab'
      else
        printf 'none'
      fi
      ;;
    *)
      if is_command_available crontab; then
        printf 'crontab'
      else
        printf 'none'
      fi
      ;;
  esac
}

daemon_install() {
  local port="${1:-}"
  local enable="${2:-true}"

  local bashclaw_bin="${BASHCLAW_ROOT:?}/bashclaw"
  local log_file
  log_file="$(_daemon_log_file)"
  ensure_dir "$(dirname "$log_file")"

  if [[ -n "$port" ]]; then
    config_set '.gateway.port' "$port"
  fi

  local init_sys
  init_sys="$(_detect_init_system)"
  log_info "Detected init system: $init_sys"

  case "$init_sys" in
    launchd)    _daemon_install_launchd "$bashclaw_bin" "$log_file" "$enable" ;;
    systemd)    _daemon_install_systemd "$bashclaw_bin" "$log_file" "$enable" ;;
    crontab)    _daemon_install_crontab "$bashclaw_bin" "$log_file" ;;
    termux-boot) _daemon_install_termux "$bashclaw_bin" "$log_file" ;;
    *)
      log_error "No supported init system found"
      printf 'No supported init system found. Use "bashclaw gateway -d" instead.\n'
      return 1
      ;;
  esac
}

_daemon_install_launchd() {
  local bashclaw_bin="$1"
  local log_file="$2"
  local enable="$3"

  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_file="${plist_dir}/${_DAEMON_LABEL}.plist"

  ensure_dir "$plist_dir"

  cat > "$plist_file" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${_DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>bash</string>
        <string>-c</string>
        <string>source "${BASHCLAW_STATE_DIR}/.env" 2>/dev/null; exec bash "${bashclaw_bin}" gateway</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BASHCLAW_STATE_DIR</key>
        <string>${BASHCLAW_STATE_DIR}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_file}</string>
    <key>StandardErrorPath</key>
    <string>${log_file}</string>
</dict>
</plist>
PLISTEOF

  printf 'LaunchAgent installed: %s\n' "$plist_file"

  if [[ "$enable" == "true" ]]; then
    launchctl load "$plist_file" 2>/dev/null || true
    printf 'LaunchAgent loaded.\n'
  fi
}

_daemon_install_systemd() {
  local bashclaw_bin="$1"
  local log_file="$2"
  local enable="$3"

  local unit_dir="$HOME/.config/systemd/user"
  local unit_file="${unit_dir}/bashclaw.service"

  ensure_dir "$unit_dir"

  cat > "$unit_file" <<UNITEOF
[Unit]
Description=Bashclaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=bash ${bashclaw_bin} gateway
Environment=BASHCLAW_STATE_DIR=${BASHCLAW_STATE_DIR}
EnvironmentFile=-${BASHCLAW_STATE_DIR}/.env
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNITEOF

  printf 'Systemd unit installed: %s\n' "$unit_file"

  if [[ "$enable" == "true" ]]; then
    systemctl --user daemon-reload
    systemctl --user enable bashclaw.service
    systemctl --user start bashclaw.service
    printf 'Systemd service enabled and started.\n'
  fi
}

_daemon_install_crontab() {
  local bashclaw_bin="$1"
  local log_file="$2"

  local entry="@reboot bash ${bashclaw_bin} gateway >> ${log_file} 2>&1"

  local existing
  existing="$(crontab -l 2>/dev/null || true)"
  if printf '%s' "$existing" | grep -qF "bashclaw gateway"; then
    printf 'Crontab entry already exists.\n'
    return 0
  fi

  printf '%s\n%s\n' "$existing" "$entry" | crontab -
  printf 'Crontab @reboot entry installed.\n'
}

_daemon_install_termux() {
  local bashclaw_bin="$1"
  local log_file="$2"

  local boot_dir="$HOME/.termux/boot"
  local boot_script="${boot_dir}/bashclaw-start.sh"

  ensure_dir "$boot_dir"

  cat > "$boot_script" <<BOOTEOF
#!/data/data/com.termux/files/usr/bin/bash
export BASHCLAW_STATE_DIR="${BASHCLAW_STATE_DIR}"
bash "${bashclaw_bin}" gateway >> "${log_file}" 2>&1 &
BOOTEOF

  chmod +x "$boot_script"
  printf 'Termux boot script installed: %s\n' "$boot_script"
  printf 'Requires Termux:Boot app to be installed.\n'
}

daemon_uninstall() {
  local init_sys
  init_sys="$(_detect_init_system)"

  case "$init_sys" in
    launchd)
      local plist_file="$HOME/Library/LaunchAgents/${_DAEMON_LABEL}.plist"
      if [[ -f "$plist_file" ]]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        printf 'LaunchAgent removed.\n'
      else
        printf 'LaunchAgent not found.\n'
      fi
      ;;
    systemd)
      local unit_file="$HOME/.config/systemd/user/bashclaw.service"
      if [[ -f "$unit_file" ]]; then
        systemctl --user stop bashclaw.service 2>/dev/null || true
        systemctl --user disable bashclaw.service 2>/dev/null || true
        rm -f "$unit_file"
        systemctl --user daemon-reload
        printf 'Systemd service removed.\n'
      else
        printf 'Systemd service not found.\n'
      fi
      ;;
    crontab)
      local existing
      existing="$(crontab -l 2>/dev/null || true)"
      if printf '%s' "$existing" | grep -qF "bashclaw gateway"; then
        printf '%s' "$existing" | grep -vF "bashclaw gateway" | crontab -
        printf 'Crontab entry removed.\n'
      else
        printf 'No crontab entry found.\n'
      fi
      ;;
    termux-boot)
      local boot_script="$HOME/.termux/boot/bashclaw-start.sh"
      if [[ -f "$boot_script" ]]; then
        rm -f "$boot_script"
        printf 'Termux boot script removed.\n'
      else
        printf 'Termux boot script not found.\n'
      fi
      ;;
    *)
      printf 'No daemon configuration found.\n'
      ;;
  esac

  daemon_stop
}

daemon_status() {
  local pid_file
  pid_file="$(_daemon_pid_file)"

  local init_sys
  init_sys="$(_detect_init_system)"
  printf 'Init system: %s\n' "$init_sys"

  if [[ ! -f "$pid_file" ]]; then
    printf 'Status:      stopped (no PID file)\n'
    return 1
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null)"
  if [[ -z "$pid" ]]; then
    printf 'Status:      stopped (empty PID file)\n'
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    printf 'Status:      running\n'
    printf 'PID:         %s\n' "$pid"

    local gw_port
    gw_port="$(config_get '.gateway.port' '18789')"
    printf 'Port:        %s\n' "$gw_port"

    local log_file
    log_file="$(_daemon_log_file)"
    printf 'Log:         %s\n' "$log_file"

    if [[ -f "$log_file" ]]; then
      local log_size
      log_size="$(file_size_bytes "$log_file")"
      printf 'Log size:    %s bytes\n' "$log_size"
    fi

    return 0
  else
    printf 'Status:      stopped (stale PID %s)\n' "$pid"
    rm -f "$pid_file"
    return 1
  fi
}

daemon_stop() {
  local pid_file
  pid_file="$(_daemon_pid_file)"

  if [[ ! -f "$pid_file" ]]; then
    printf 'No gateway PID file found.\n'
    return 1
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null)"
  if [[ -z "$pid" ]]; then
    printf 'Empty PID file.\n'
    rm -f "$pid_file"
    return 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'Gateway process %s not running.\n' "$pid"
    rm -f "$pid_file"
    return 1
  fi

  printf 'Stopping gateway (pid=%s)...\n' "$pid"
  kill -TERM "$pid" 2>/dev/null

  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    printf 'Sent SIGKILL.\n'
  fi

  rm -f "$pid_file"
  printf 'Gateway stopped.\n'
}

daemon_restart() {
  daemon_stop 2>/dev/null || true
  sleep 1

  local init_sys
  init_sys="$(_detect_init_system)"

  case "$init_sys" in
    launchd)
      local plist_file="$HOME/Library/LaunchAgents/${_DAEMON_LABEL}.plist"
      if [[ -f "$plist_file" ]]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        launchctl load "$plist_file" 2>/dev/null || true
        printf 'LaunchAgent restarted.\n'
      else
        printf 'LaunchAgent not installed. Starting daemon directly.\n'
        cmd_gateway --daemon
      fi
      ;;
    systemd)
      local unit_file="$HOME/.config/systemd/user/bashclaw.service"
      if [[ -f "$unit_file" ]]; then
        systemctl --user restart bashclaw.service
        printf 'Systemd service restarted.\n'
      else
        printf 'Systemd service not installed. Starting daemon directly.\n'
        cmd_gateway --daemon
      fi
      ;;
    *)
      printf 'Restarting gateway as daemon...\n'
      cmd_gateway --daemon
      ;;
  esac
}

daemon_logs() {
  local follow=false
  local lines=50

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) follow=true; shift ;;
      -n|--lines) lines="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local log_file
  log_file="$(_daemon_log_file)"

  if [[ ! -f "$log_file" ]]; then
    printf 'No log file found: %s\n' "$log_file"
    return 1
  fi

  if [[ "$follow" == "true" ]]; then
    tail -n "$lines" -f "$log_file"
  else
    tail -n "$lines" "$log_file"
  fi
}
