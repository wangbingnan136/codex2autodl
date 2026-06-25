#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/setup-autodl-codex.sh --interactive
  scripts/setup-autodl-codex.sh --interactive [--local-api-port PORT] [--api-key-prompt]
  scripts/setup-autodl-codex.sh [--alias NAME] [--skip-codex-install] [--proxy URL] ssh -p PORT USER@HOST
  scripts/setup-autodl-codex.sh [--alias NAME] [--skip-codex-install] [--local-proxy-port PORT] ssh -p PORT USER@HOST
  scripts/setup-autodl-codex.sh [--alias NAME] [--skip-codex-install] [--local-api-port PORT] ssh -p PORT USER@HOST
  scripts/setup-autodl-codex.sh [--alias NAME] [--skip-codex-install] [--proxy URL] "ssh -p PORT USER@HOST"
  scripts/setup-autodl-codex.sh [--alias NAME] [--ssh-password-prompt] [--local-api-port PORT] [--api-key-prompt] "ssh -p PORT USER@HOST"
  scripts/setup-autodl-codex.sh [--alias NAME] [--ssh-password-file FILE] [--local-api-port PORT] [--api-key-file FILE] "ssh -p PORT USER@HOST"
  scripts/setup-autodl-codex.sh [--alias NAME] --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --proxy URL --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --local-proxy-port PORT --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --local-api-port PORT --api-key-prompt --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --api-base-url URL --api-key-prompt --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --openai-base-url URL --api-key-prompt --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --api-key-prompt --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --api-key-env ENV_VAR --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --api-key-file FILE --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --copy-local-auth --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --clear-proxy --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --clear-api-provider --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --clear-openai-base-url --diagnose
  scripts/setup-autodl-codex.sh [--alias NAME] --stop-proxy-tunnel
  scripts/setup-autodl-codex.sh [--alias NAME] --stop-api-tunnel
  scripts/setup-autodl-codex.sh [--alias NAME] --stop-api-tunnel --local-api-port PORT

Examples:
  scripts/setup-autodl-codex.sh --interactive --local-api-port 8080 --api-key-prompt
  scripts/setup-autodl-codex.sh ssh -p 51418 root@connect.westd.seetacloud.com
  scripts/setup-autodl-codex.sh --alias autodl-v3 "ssh -p 51418 root@connect.westd.seetacloud.com"
  scripts/setup-autodl-codex.sh --alias autodl-v3 --ssh-password-prompt "ssh -p 51418 root@connect.westd.seetacloud.com"
  scripts/setup-autodl-codex.sh --diagnose
  scripts/setup-autodl-codex.sh --proxy http://127.0.0.1:7890 --diagnose
  scripts/setup-autodl-codex.sh --local-proxy-port 7890 --diagnose
  scripts/setup-autodl-codex.sh --local-api-port 8080 --api-key-prompt --diagnose
  scripts/setup-autodl-codex.sh --api-key-prompt --diagnose

What it does:
  1. Generates ~/.ssh/autodl_codex if missing.
  2. Uses your AutoDL password once to append the public key on the remote host.
  3. Writes a concrete Host alias into ~/.ssh/config.
  4. Verifies passwordless SSH with BatchMode=yes.
  5. Checks the latest Codex CLI release.
  6. Installs Codex on the remote host from the npm CDN platform tarball when possible.
  7. Falls back to a locally cached GitHub release package upload when npm CDN install fails.
  8. Optionally writes proxy env vars to the remote shell profile and restarts remote Codex app-server.
  9. Optionally starts a supervised SSH reverse tunnel from AutoDL back to your Mac local proxy/API port.
  10. Optionally logs the remote Codex CLI in with an API key.
  11. Optionally points Codex at a local OpenAI-compatible API reverse proxy.

The password is read silently and is not saved to disk.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

prompt_with_default() {
  local label="$1"
  local default_value="$2"
  local answer

  if [[ -n "$default_value" ]]; then
    printf "%s [%s]: " "$label" "$default_value" >&2
  else
    printf "%s: " "$label" >&2
  fi

  IFS= read -r answer
  if [[ -n "$answer" ]]; then
    printf '%s\n' "$answer"
  else
    printf '%s\n' "$default_value"
  fi
}

read_first_line_from_file() {
  local label="$1"
  local file="$2"
  local value=""

  [[ -n "$file" ]] || die "$label file path cannot be empty"
  [[ -f "$file" ]] || die "$label file not found: $file"
  [[ -r "$file" ]] || die "$label file is not readable: $file"

  IFS= read -r value < "$file" || true
  [[ -n "$value" ]] || die "$label file is empty: $file"
  printf '%s\n' "$value"
}

upload_public_key_with_password() {
  local port="$1"
  local user="$2"
  local host="$3"
  local pubkey_q="$4"
  local remote_cmd
  local rc

  if [[ -n "$SSH_PASSWORD_FILE" ]]; then
    AUTODL_SETUP_PASSWORD="$(read_first_line_from_file "AutoDL SSH password" "$SSH_PASSWORD_FILE")"
  else
    printf "AutoDL SSH password (input hidden, not saved): "
    IFS= read -r -s AUTODL_SETUP_PASSWORD || true
    echo
  fi
  [[ -n "$AUTODL_SETUP_PASSWORD" ]] || die "password cannot be empty"
  export AUTODL_SETUP_PASSWORD

  remote_cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; grep -qxF $pubkey_q ~/.ssh/authorized_keys || printf '%s\n' $pubkey_q >> ~/.ssh/authorized_keys"

  echo "Uploading public key to AutoDL..."
  export AUTODL_SETUP_PORT="$port"
  export AUTODL_SETUP_USER="$user"
  export AUTODL_SETUP_HOST="$host"
  export AUTODL_SETUP_REMOTE_CMD="$remote_cmd"

  set +e
  expect <<'EOF'
set timeout 30
set password $env(AUTODL_SETUP_PASSWORD)
set port $env(AUTODL_SETUP_PORT)
set user $env(AUTODL_SETUP_USER)
set host $env(AUTODL_SETUP_HOST)
set remote_cmd $env(AUTODL_SETUP_REMOTE_CMD)

spawn ssh \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o NumberOfPasswordPrompts=1 \
  -o StrictHostKeyChecking=accept-new \
  -p $port \
  "$user@$host" \
  "$remote_cmd"

expect {
  -re "(?i)are you sure you want to continue connecting" {
    send -- "yes\r"
    exp_continue
  }
  -re "(?i)password:" {
    send -- "$password\r"
    exp_continue
  }
  -re "(?i)permission denied" {
    exit 10
  }
  timeout {
    exit 11
  }
  eof {
    catch wait result
    set code [lindex $result 3]
    exit $code
  }
}
EOF
  rc=$?
  set -e

  unset AUTODL_SETUP_PASSWORD
  unset AUTODL_SETUP_PORT AUTODL_SETUP_USER AUTODL_SETUP_HOST AUTODL_SETUP_REMOTE_CMD

  [[ "$rc" -eq 0 ]] || die "failed to upload public key with password; check the AutoDL password and SSH target"
}

shell_quote() {
  # Quote one string for POSIX sh.
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

curl_retry() {
  local attempt
  local max_attempts=5
  local rc=0

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if curl -fsSL --connect-timeout 20 --max-time 300 "$@"; then
      return 0
    fi

    rc=$?
    if (( attempt < max_attempts )); then
      echo "curl failed, retrying ($attempt/$max_attempts)..." >&2
      sleep $((attempt * 2))
    fi
  done

  return "$rc"
}

ssh_alias_configured() {
  local alias="$1"

  [[ -f "$CONFIG_FILE" ]] || return 1
  awk -v alias="$alias" '
    $1 == "Host" {
      for (i = 2; i <= NF; i++) {
        if ($i == alias) {
          found = 1
        }
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$CONFIG_FILE"
}

ensure_ssh_reliability_override() {
  local alias="$1"
  local marker_begin="# >>> codex2autodl ssh reliability: $alias >>>"
  local marker_end="# <<< codex2autodl ssh reliability: $alias <<<"
  local tmp_config

  ssh_alias_configured "$alias" || return 0

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  tmp_config="$(mktemp)"
  awk -v begin="$marker_begin" -v end="$marker_end" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$CONFIG_FILE" > "$tmp_config"

  {
    printf "%s\n" "$marker_begin"
    printf "Host %s\n" "$alias"
    printf "  ServerAliveInterval %s\n" "$SSH_ALIVE_INTERVAL"
    printf "  ServerAliveCountMax %s\n" "$SSH_ALIVE_COUNT_MAX"
    printf "  TCPKeepAlive yes\n"
    printf "  IPQoS none\n"
    printf "  ConnectTimeout %s\n" "$SSH_CONNECT_TIMEOUT"
    printf "  ControlMaster auto\n"
    printf "  ControlPath %s/codex2autodl-%%C.sock\n" "$SSH_DIR"
    printf "  ControlPersist %s\n" "$SSH_CONTROL_PERSIST"
    printf "%s\n\n" "$marker_end"
    cat "$tmp_config"
  } > "$CONFIG_FILE"

  rm -f "$tmp_config"
  chmod 600 "$CONFIG_FILE"
}

resolve_latest_codex_version() {
  local latest_version
  local effective_url

  latest_version="$(
    curl_retry https://registry.npmjs.org/@openai%2Fcodex/latest |
      sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' |
      head -n 1
  )" || true

  if [[ -n "$latest_version" ]]; then
    printf '%s\n' "$latest_version"
    return 0
  fi

  latest_version="$(
    curl_retry https://api.github.com/repos/openai/codex/releases/latest |
      sed -n 's/.*"tag_name":[[:space:]]*"rust-v\([^"]*\)".*/\1/p' |
      head -n 1
  )" || true

  if [[ -n "$latest_version" ]]; then
    printf '%s\n' "$latest_version"
    return 0
  fi

  effective_url="$(
    curl_retry -I -o /dev/null -w '%{url_effective}' https://github.com/openai/codex/releases/latest
  )" || true

  latest_version="$(
    printf '%s\n' "$effective_url" |
      sed -n 's#.*/releases/tag/rust-v\([^/?#]*\).*#\1#p' |
      head -n 1
  )"

  if [[ -n "$latest_version" ]]; then
    printf '%s\n' "$latest_version"
    return 0
  fi

  return 1
}

run_local_diagnostics() {
  local alias="$1"
  local api_control_path
  local api_pid_path
  local proxy_control_path
  local proxy_pid_path
  local pid=""

  api_control_path="$(proxy_tunnel_control_path "$alias" "$REMOTE_API_PORT")"
  api_pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$REMOTE_API_PORT")"
  proxy_control_path="$(proxy_tunnel_control_path "$alias" "$REMOTE_PROXY_PORT")"
  proxy_pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$REMOTE_PROXY_PORT")"

  echo
  echo "== local ssh config"
  if ssh -G "$alias" >/tmp/codex2autodl-ssh-g.$$ 2>/dev/null; then
    awk '
      /^(hostname|user|port|identityfile|serveraliveinterval|serveralivecountmax|tcpkeepalive|ipqos|connecttimeout|controlmaster|controlpath|controlpersist)[[:space:]]/ {
        print
      }
    ' /tmp/codex2autodl-ssh-g.$$
  else
    echo "ssh -G failed for alias: $alias"
  fi
  rm -f /tmp/codex2autodl-ssh-g.$$

  echo
  echo "== local managed tunnels"
  if [[ -f "$api_pid_path" ]]; then
    pid="$(cat "$api_pid_path" 2>/dev/null || true)"
    if pid_is_running "$pid"; then
      echo "api tunnel watchdog: running pid=$pid"
    else
      echo "api tunnel watchdog: stale pid=$pid"
    fi
  else
    echo "api tunnel watchdog: not found"
  fi
  if ssh -S "$api_control_path" -O check "$alias" >/dev/null 2>&1; then
    echo "api tunnel: healthy remote 127.0.0.1:$REMOTE_API_PORT"
  else
    echo "api tunnel: not healthy remote 127.0.0.1:$REMOTE_API_PORT"
  fi

  if [[ "$REMOTE_PROXY_PORT" != "$REMOTE_API_PORT" ]]; then
    if [[ -f "$proxy_pid_path" ]]; then
      pid="$(cat "$proxy_pid_path" 2>/dev/null || true)"
      if pid_is_running "$pid"; then
        echo "proxy tunnel watchdog: running pid=$pid"
      else
        echo "proxy tunnel watchdog: stale pid=$pid"
      fi
    else
      echo "proxy tunnel watchdog: not found"
    fi
    if ssh -S "$proxy_control_path" -O check "$alias" >/dev/null 2>&1; then
      echo "proxy tunnel: healthy remote 127.0.0.1:$REMOTE_PROXY_PORT"
    else
      echo "proxy tunnel: not healthy remote 127.0.0.1:$REMOTE_PROXY_PORT"
    fi
  fi
}

run_remote_diagnostics() {
  local alias="$1"

  run_local_diagnostics "$alias"

  echo
  echo "Running remote diagnostics on: $alias"
  ssh \
    -o "ServerAliveInterval=$SSH_ALIVE_INTERVAL" \
    -o "ServerAliveCountMax=$SSH_ALIVE_COUNT_MAX" \
    -o TCPKeepAlive=yes \
    -o IPQoS=none \
    "$alias" 'sh -s' <<'REMOTE_DIAGNOSE'
set +e

codex2autodl_env="$HOME/.codex/codex2autodl-env"
codex2autodl_env_loaded=0
if [ -f "$codex2autodl_env" ]; then
  # shellcheck disable=SC1090
  . "$codex2autodl_env"
  codex2autodl_env_loaded=1
fi

echo "== system"
date
hostname
uptime
free -h 2>/dev/null || true
df -h / /tmp "$HOME/.codex" "$HOME/.local" 2>/dev/null || true

echo
echo "== proxy env"
env | grep -Ei "^(http|https|all|no)_proxy=" | sed -E "s#=.*#=<set>#" || echo "no proxy env vars"
if [ -f "$HOME/.codex/codex2autodl-env" ]; then
  if [ "$codex2autodl_env_loaded" = "1" ]; then
    echo "codex2autodl env file: present and loaded for diagnostics"
  else
    echo "codex2autodl env file: present but not loaded"
  fi
else
  echo "codex2autodl env file: missing"
fi
if [ -f "$HOME/.local/bin/codex" ] && grep -F "codex2autodl wrapper" "$HOME/.local/bin/codex" >/dev/null 2>&1; then
  echo "codex wrapper: present"
else
  echo "codex wrapper: not present"
fi

echo
echo "== codex config"
config_file="$HOME/.codex/config.toml"
openai_base_url=""
model_provider=""
provider_base_url=""
if [ -f "$config_file" ]; then
  sed -n "1,220p" "$config_file" | sed -E 's/(api[_-]?key|token|secret|password)[[:space:]]*=[[:space:]]*"[^"]*"/\1 = "<redacted>"/Ig'
  openai_base_url="$(sed -n 's/^[[:space:]]*openai_base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | tail -n 1)"
  model_provider="$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
  if [ -n "$model_provider" ] && [ "$model_provider" != "openai" ]; then
    provider_base_url="$(awk -v provider="$model_provider" '
      $0 == "[model_providers." provider "]" { in_provider = 1; next }
      in_provider == 1 && /^\[/ { in_provider = 0 }
      in_provider == 1 && /^[[:space:]]*base_url[[:space:]]*=/ {
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
      }
    ' "$config_file")"
  fi
else
  echo "missing: $config_file"
fi

echo
echo "== codex"
PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
command -v codex || true
codex --version 2>&1 || true
codex login status 2>&1 | sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g" || true

echo
echo "== codex doctor"
if command -v codex >/dev/null 2>&1; then
  codex doctor 2>&1 | sed -n "1,220p"
else
  echo "codex is not installed or not on PATH"
fi

echo
echo "== endpoint checks"
if [ -n "$model_provider" ] && [ "$model_provider" != "openai" ]; then
  echo "-- direct OpenAI public endpoint checks skipped"
  echo "   active provider is '$model_provider', so model calls use the configured provider base URL instead of api.openai.com"
  if [ -n "$provider_base_url" ]; then
    echo "-- configured provider base_url: $provider_base_url"
    provider_test_url="${provider_base_url%/}/models"
    if command -v curl >/dev/null 2>&1; then
      curl -sS -i --connect-timeout 10 --max-time 20 "$provider_test_url" 2>&1 | sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g" | sed -n "1,16p"
    elif command -v wget >/dev/null 2>&1; then
      wget --spider --timeout=20 "$provider_test_url" 2>&1 | sed -n "1,16p"
    else
      echo "curl/wget not found"
    fi
  fi
  echo
fi
if [ -n "$openai_base_url" ]; then
  echo "-- configured openai_base_url: $openai_base_url"
  api_test_url="${openai_base_url%/}/models"
  if command -v curl >/dev/null 2>&1; then
    curl -sS -i --connect-timeout 10 --max-time 20 "$api_test_url" 2>&1 | sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g" | sed -n "1,16p"
  elif command -v wget >/dev/null 2>&1; then
    wget --spider --timeout=20 "$api_test_url" 2>&1 | sed -n "1,16p"
  else
    echo "curl/wget not found"
  fi
  echo
fi
if [ -z "$model_provider" ] || [ "$model_provider" = "openai" ]; then
  for url in \
    https://api.openai.com \
    https://chatgpt.com \
    https://auth.openai.com \
    https://persistent.oaistatic.com \
    https://registry.npmjs.org
  do
    echo "-- $url"
    if command -v curl >/dev/null 2>&1; then
      curl -I -L --connect-timeout 10 --max-time 20 -sS "$url" 2>&1 | sed -n "1,10p"
    elif command -v wget >/dev/null 2>&1; then
      wget --spider --timeout=20 "$url" 2>&1 | sed -n "1,10p"
    else
      echo "curl/wget not found"
    fi
  done
fi

echo
echo "== codex processes"
ps -eo pid,ppid,pcpu,pmem,etime,comm,args --sort=-pcpu 2>/dev/null | awk 'NR == 1 || $6 == "codex" || $0 ~ /app-server|sshd/' | sed -n "1,40p"
REMOTE_DIAGNOSE
}

restart_remote_codex_app_server() {
  local alias="$1"

  echo "Restarting remote Codex app-server so environment changes take effect..."
  ssh "$alias" 'sh -s' <<'REMOTE_RESTART_APP_SERVER'
set +e
ps -eo pid=,comm=,args= 2>/dev/null |
  awk '$2 == "codex" && index($0, "app-server") { print $1 }' |
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
sleep 1
ps -eo pid=,comm=,args= 2>/dev/null |
  awk '$2 == "codex" && index($0, "app-server") { print $1 }' |
  while read -r pid; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
rm -f "$HOME/.codex/app-server-control/app-server-control.sock" \
      "$HOME/.codex/app-server-control/app-server-startup.lock" \
      "$HOME/.codex/app-server-daemon/app-server.pid" \
      "$HOME/.codex/app-server-daemon/app-server-updater.pid" 2>/dev/null || true
REMOTE_RESTART_APP_SERVER
}

install_remote_api_key() {
  local alias="$1"
  local api_key="$2"

  [[ -n "$api_key" ]] || die "API key cannot be empty"

  echo "Logging remote Codex in with API key..."
  if printf '%s' "$api_key" | ssh "$alias" '
set -eu
PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
mkdir -p "$HOME/.codex"
log_file="/tmp/codex2autodl-api-key-login.log"
api_key="$(cat)"
if printf "%s" "$api_key" | codex login --with-api-key >"$log_file" 2>&1; then
  unset api_key
  codex login status 2>&1 | sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g"
else
  unset api_key
  echo "Remote API key login failed:" >&2
  sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g" "$log_file" >&2 || true
  exit 91
fi
'
  then
    restart_remote_codex_app_server "$alias"
  else
    die "remote API key login failed"
  fi
}

copy_local_auth_to_remote() {
  local alias="$1"
  local auth_file="$HOME/.codex/auth.json"

  [[ -f "$auth_file" ]] || die "local auth file not found: $auth_file"

  echo "Copying local Codex auth cache to remote host..."
  ssh "$alias" 'mkdir -p "$HOME/.codex" && umask 077 && cat > "$HOME/.codex/auth.json"' < "$auth_file"
  ssh "$alias" 'chmod 600 "$HOME/.codex/auth.json" && PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; codex login status 2>&1 | sed -E "s/sk-[A-Za-z0-9_-]+/sk-<redacted>/g"'
  restart_remote_codex_app_server "$alias"
}

proxy_tunnel_control_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/.ssh/codex2autodl-%s-proxy-%s.sock' "$HOME" "$alias" "$remote_port"
}

proxy_tunnel_watchdog_pid_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/.ssh/codex2autodl-%s-proxy-%s.watchdog.pid' "$HOME" "$alias" "$remote_port"
}

proxy_tunnel_log_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/.ssh/codex2autodl-%s-proxy-%s.watchdog.log' "$HOME" "$alias" "$remote_port"
}

pid_is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

wait_for_reverse_proxy_tunnel() {
  local alias="$1"
  local remote_port="$2"
  local control_path="$3"
  local attempt

  for ((attempt = 1; attempt <= 20; attempt++)); do
    if ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

start_reverse_proxy_tunnel() {
  local alias="$1"
  local local_port="$2"
  local remote_port="$3"
  local control_path
  local pid_path
  local log_path
  local existing_pid=""

  control_path="$(proxy_tunnel_control_path "$alias" "$remote_port")"
  pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$remote_port")"
  log_path="$(proxy_tunnel_log_path "$alias" "$remote_port")"
  mkdir -p "$HOME/.ssh"

  if [[ -f "$pid_path" ]]; then
    existing_pid="$(cat "$pid_path" 2>/dev/null || true)"
    if pid_is_running "$existing_pid"; then
      echo "SSH reverse proxy tunnel watchdog is already running (pid $existing_pid)."
      if wait_for_reverse_proxy_tunnel "$alias" "$remote_port" "$control_path"; then
        echo "SSH reverse proxy tunnel is healthy: remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
        return 0
      fi

      echo "Existing tunnel watchdog did not recover the tunnel; restarting watchdog..."
      kill "$existing_pid" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "$pid_path"
  fi

  if ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
    echo "SSH reverse proxy tunnel is already running; adding watchdog supervision:"
  else
    rm -f "$control_path"
    echo "Starting supervised SSH reverse proxy tunnel:"
  fi

  echo "  remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
  echo "  watchdog log: $log_path"

  CODEX_AUTODL_ALIAS="$alias" \
    CODEX_AUTODL_LOCAL_PORT="$local_port" \
    CODEX_AUTODL_REMOTE_PORT="$remote_port" \
    CODEX_AUTODL_CONTROL_PATH="$control_path" \
    CODEX_AUTODL_ALIVE_INTERVAL="$SSH_ALIVE_INTERVAL" \
    CODEX_AUTODL_ALIVE_COUNT_MAX="$SSH_ALIVE_COUNT_MAX" \
    CODEX_AUTODL_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
    CODEX_AUTODL_CHECK_INTERVAL="$TUNNEL_CHECK_INTERVAL" \
    CODEX_AUTODL_RETRY_INTERVAL="$TUNNEL_RETRY_INTERVAL" \
    nohup bash -c '
set -u

log() {
  printf "%s %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$*"
}

while :; do
  if ssh -S "$CODEX_AUTODL_CONTROL_PATH" -O check "$CODEX_AUTODL_ALIAS" >/dev/null 2>&1; then
    sleep "$CODEX_AUTODL_CHECK_INTERVAL"
    continue
  fi

  rm -f "$CODEX_AUTODL_CONTROL_PATH"
  log "reverse tunnel down; starting remote 127.0.0.1:${CODEX_AUTODL_REMOTE_PORT} -> local 127.0.0.1:${CODEX_AUTODL_LOCAL_PORT}"
  if ssh -fN -M -S "$CODEX_AUTODL_CONTROL_PATH" \
    -o ExitOnForwardFailure=yes \
    -o "ServerAliveInterval=$CODEX_AUTODL_ALIVE_INTERVAL" \
    -o "ServerAliveCountMax=$CODEX_AUTODL_ALIVE_COUNT_MAX" \
    -o TCPKeepAlive=yes \
    -o IPQoS=none \
    -o "ConnectTimeout=$CODEX_AUTODL_CONNECT_TIMEOUT" \
    -R "127.0.0.1:${CODEX_AUTODL_REMOTE_PORT}:127.0.0.1:${CODEX_AUTODL_LOCAL_PORT}" \
    "$CODEX_AUTODL_ALIAS"; then
    log "reverse tunnel started"
    sleep "$CODEX_AUTODL_CHECK_INTERVAL"
  else
    rc=$?
    log "reverse tunnel start failed rc=$rc"
    sleep "$CODEX_AUTODL_RETRY_INTERVAL"
  fi
done
' >>"$log_path" 2>&1 &

  printf '%s\n' "$!" > "$pid_path"

  if wait_for_reverse_proxy_tunnel "$alias" "$remote_port" "$control_path"; then
    echo "SSH reverse proxy tunnel is healthy: remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
  else
    echo "Warning: tunnel watchdog started, but the tunnel is not healthy yet. Check: tail -f $log_path" >&2
    return 1
  fi
}

stop_reverse_proxy_tunnel() {
  local alias="$1"
  local remote_port="$2"
  local control_path
  local pid_path
  local existing_pid=""

  control_path="$(proxy_tunnel_control_path "$alias" "$remote_port")"
  pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$remote_port")"

  if [[ -f "$pid_path" ]]; then
    existing_pid="$(cat "$pid_path" 2>/dev/null || true)"
    if pid_is_running "$existing_pid"; then
      kill "$existing_pid" >/dev/null 2>&1 || true
      echo "Stopped SSH reverse proxy tunnel watchdog for remote port $remote_port."
    fi
    rm -f "$pid_path"
  fi

  if ssh -S "$control_path" -O exit "$alias" >/dev/null 2>&1; then
    echo "Stopped SSH reverse proxy tunnel for remote port $remote_port."
  else
    echo "No managed SSH reverse proxy tunnel found for remote port $remote_port."
  fi
  rm -f "$control_path"
}

configure_remote_proxy() {
  local alias="$1"
  local proxy_url="$2"
  local clear_proxy="$3"

  if [[ "$clear_proxy" -eq 1 ]]; then
    echo "Clearing codex2autodl proxy env block on remote host..."
  else
    [[ -n "$proxy_url" ]] || die "--proxy URL cannot be empty"
    [[ "$proxy_url" != *$'\n'* ]] || die "--proxy URL cannot contain newlines"
    echo "Writing proxy env block on remote host..."
  fi

  ssh "$alias" "CODEX_AUTODL_PROXY_URL=$(shell_quote "$proxy_url") CODEX_AUTODL_CLEAR_PROXY='$clear_proxy' sh -s" <<'REMOTE_PROXY_CONFIG'
set -eu

marker_begin="# >>> codex2autodl proxy >>>"
marker_end="# <<< codex2autodl proxy <<<"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

strip_proxy_block() {
  file="$1"
  [ -f "$file" ] || return 0
  tmp="$file.codex2autodl.$$"
  awk -v begin="$marker_begin" -v end="$marker_end" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_proxy_env_file() {
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  env_file="$codex_home/codex2autodl-env"
  mkdir -p "$codex_home"

  proxy_q="$(shell_quote "$CODEX_AUTODL_PROXY_URL")"
  no_proxy_q="$(shell_quote "localhost,127.0.0.1,::1")"
  {
    printf 'export HTTPS_PROXY=%s\n' "$proxy_q"
    printf 'export HTTP_PROXY=%s\n' "$proxy_q"
    printf 'export ALL_PROXY=%s\n' "$proxy_q"
    printf 'export https_proxy=%s\n' "$proxy_q"
    printf 'export http_proxy=%s\n' "$proxy_q"
    printf 'export all_proxy=%s\n' "$proxy_q"
    printf 'export NO_PROXY=%s\n' "$no_proxy_q"
    printf 'export no_proxy=%s\n' "$no_proxy_q"
  } > "$env_file"
  chmod 0600 "$env_file"
}

install_codex_wrapper() {
  bin_dir="$HOME/.local/bin"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  real_codex="$codex_home/packages/standalone/current/bin/codex"
  wrapper="$bin_dir/codex"

  if [ ! -x "$real_codex" ]; then
    echo "Standalone Codex binary not found at $real_codex; shell profile proxy env was written, but wrapper was skipped." >&2
    return 0
  fi

  mkdir -p "$bin_dir"
  tmp="$bin_dir/.codex.wrapper.$$"
  cat > "$tmp" <<'WRAPPER'
#!/bin/sh
# codex2autodl wrapper
codex_home="${CODEX_HOME:-$HOME/.codex}"
if [ -f "$codex_home/codex2autodl-env" ]; then
  . "$codex_home/codex2autodl-env"
fi
exec "$codex_home/packages/standalone/current/bin/codex" "$@"
WRAPPER
  chmod 0755 "$tmp"
  rm -f "$wrapper"
  mv "$tmp" "$wrapper"
}

restore_codex_symlink_if_wrapper() {
  bin_dir="$HOME/.local/bin"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  real_codex="$codex_home/packages/standalone/current/bin/codex"
  wrapper="$bin_dir/codex"

  rm -f "$codex_home/codex2autodl-env"
  if [ -f "$wrapper" ] && grep -F "codex2autodl wrapper" "$wrapper" >/dev/null 2>&1 && [ -x "$real_codex" ]; then
    rm -f "$wrapper"
    ln -s "$real_codex" "$wrapper"
  fi
}

write_proxy_block() {
  file="$1"
  touch "$file"
  chmod 0644 "$file" 2>/dev/null || true
  strip_proxy_block "$file"

  proxy_q="$(shell_quote "$CODEX_AUTODL_PROXY_URL")"
  no_proxy_q="$(shell_quote "localhost,127.0.0.1,::1")"
  {
    printf '\n%s\n' "$marker_begin"
    printf 'export HTTPS_PROXY=%s\n' "$proxy_q"
    printf 'export HTTP_PROXY=%s\n' "$proxy_q"
    printf 'export ALL_PROXY=%s\n' "$proxy_q"
    printf 'export https_proxy=%s\n' "$proxy_q"
    printf 'export http_proxy=%s\n' "$proxy_q"
    printf 'export all_proxy=%s\n' "$proxy_q"
    printf 'export NO_PROXY=%s\n' "$no_proxy_q"
    printf 'export no_proxy=%s\n' "$no_proxy_q"
    printf '%s\n' "$marker_end"
  } >> "$file"
}

profiles="$HOME/.profile $HOME/.bashrc"
[ -f "$HOME/.bash_profile" ] && profiles="$profiles $HOME/.bash_profile"
[ -f "$HOME/.bash_login" ] && profiles="$profiles $HOME/.bash_login"
[ -f "$HOME/.zprofile" ] && profiles="$profiles $HOME/.zprofile"
[ -f "$HOME/.zshrc" ] && profiles="$profiles $HOME/.zshrc"

for profile in $profiles; do
  if [ "$CODEX_AUTODL_CLEAR_PROXY" = "1" ]; then
    strip_proxy_block "$profile"
  else
    write_proxy_block "$profile"
  fi
done

if [ "$CODEX_AUTODL_CLEAR_PROXY" = "1" ]; then
  restore_codex_symlink_if_wrapper
  echo "Remote proxy env block cleared."
else
  write_proxy_env_file
  install_codex_wrapper
  echo "Remote proxy env block written."
fi
REMOTE_PROXY_CONFIG

  restart_remote_codex_app_server "$alias"
}

configure_remote_openai_base_url() {
  local alias="$1"
  local base_url="$2"
  local clear_base_url="$3"

  if [[ "$clear_base_url" -eq 1 ]]; then
    echo "Clearing remote openai_base_url from Codex config..."
  else
    [[ -n "$base_url" ]] || die "--openai-base-url cannot be empty"
    [[ "$base_url" != *$'\n'* ]] || die "--openai-base-url cannot contain newlines"
    echo "Writing remote openai_base_url: $base_url"
  fi

  ssh "$alias" "CODEX_AUTODL_OPENAI_BASE_URL=$(shell_quote "$base_url") CODEX_AUTODL_CLEAR_OPENAI_BASE_URL='$clear_base_url' sh -s" <<'REMOTE_OPENAI_BASE_URL_CONFIG'
set -eu

config_dir="$HOME/.codex"
config_file="$config_dir/config.toml"
mkdir -p "$config_dir"
touch "$config_file"
chmod 0600 "$config_file" 2>/dev/null || true

tmp="$config_file.codex2autodl.$$"
awk '
  /^[[:space:]]*openai_base_url[[:space:]]*=/ { next }
  { print }
' "$config_file" > "$tmp"
cat "$tmp" > "$config_file"
rm -f "$tmp"

if [ "$CODEX_AUTODL_CLEAR_OPENAI_BASE_URL" != "1" ]; then
  tmp="$config_file.codex2autodl.root.$$"
  {
    printf 'openai_base_url = "%s"\n\n' "$CODEX_AUTODL_OPENAI_BASE_URL"
    cat "$config_file"
  } > "$tmp"
  cat "$tmp" > "$config_file"
  rm -f "$tmp"
  echo "Remote openai_base_url written."
else
  echo "Remote openai_base_url cleared."
fi
REMOTE_OPENAI_BASE_URL_CONFIG

  restart_remote_codex_app_server "$alias"
}

configure_remote_api_provider() {
  local alias="$1"
  local provider_name="$2"
  local base_url="$3"
  local clear_provider="$4"

  [[ "$provider_name" =~ ^[A-Za-z0-9_-]+$ ]] || die "API provider name can only contain letters, numbers, underscore, and dash"

  if [[ "$clear_provider" -eq 1 ]]; then
    echo "Clearing remote API provider '$provider_name' from Codex config..."
  else
    [[ -n "$base_url" ]] || die "--api-base-url cannot be empty"
    [[ "$base_url" != *$'\n'* ]] || die "--api-base-url cannot contain newlines"
    echo "Writing remote API provider '$provider_name': $base_url"
  fi

  ssh "$alias" \
    "CODEX_AUTODL_API_PROVIDER_NAME=$(shell_quote "$provider_name") CODEX_AUTODL_API_BASE_URL=$(shell_quote "$base_url") CODEX_AUTODL_CLEAR_API_PROVIDER='$clear_provider' sh -s" <<'REMOTE_API_PROVIDER_CONFIG'
set -eu

config_dir="$HOME/.codex"
config_file="$config_dir/config.toml"
provider="$CODEX_AUTODL_API_PROVIDER_NAME"
mkdir -p "$config_dir"
touch "$config_file"
chmod 0600 "$config_file" 2>/dev/null || true

tmp="$config_file.codex2autodl.$$"
awk -v provider="$provider" '
  BEGIN { skip = 0 }
  /^[[:space:]]*model_provider[[:space:]]*=/ { next }
  /^[[:space:]]*openai_base_url[[:space:]]*=/ { next }
  $0 == "[model_providers." provider "]" { skip = 1; next }
  skip == 1 && /^\[/ { skip = 0 }
  skip != 1 { print }
' "$config_file" > "$tmp"
cat "$tmp" > "$config_file"
rm -f "$tmp"

if [ "$CODEX_AUTODL_CLEAR_API_PROVIDER" != "1" ]; then
  tmp="$config_file.codex2autodl.root.$$"
  {
    printf '\nmodel_provider = "%s"\n' "$provider"
    cat "$config_file"
    printf '\n[model_providers.%s]\n' "$provider"
    printf 'name = "%s"\n' "$provider"
    printf 'base_url = "%s"\n' "$CODEX_AUTODL_API_BASE_URL"
    printf 'wire_api = "responses"\n'
    printf 'requires_openai_auth = true\n'
  } > "$tmp"
  cat "$tmp" > "$config_file"
  rm -f "$tmp"
  echo "Remote API provider written."
else
  echo "Remote API provider cleared."
fi
REMOTE_API_PROVIDER_CONFIG

  restart_remote_codex_app_server "$alias"
}

remote_env_prefix() {
  local proxy_url="$1"

  if [[ -z "$proxy_url" ]]; then
    return 0
  fi

  printf 'HTTPS_PROXY=%s HTTP_PROXY=%s ALL_PROXY=%s https_proxy=%s http_proxy=%s all_proxy=%s NO_PROXY=%s no_proxy=%s ' \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "$proxy_url")" \
    "$(shell_quote "localhost,127.0.0.1,::1")" \
    "$(shell_quote "localhost,127.0.0.1,::1")"
}

ALIAS="autodl-codex"
INTERACTIVE=0
SSH_PASSWORD_PROMPT=0
SSH_PASSWORD_FILE=""
SKIP_CODEX_INSTALL=0
REMOTE_PROXY_URL=""
CLEAR_REMOTE_PROXY=0
RUN_DIAGNOSE=0
LOCAL_PROXY_SPEC=""
LOCAL_PROXY_PORT=""
REMOTE_PROXY_PORT=""
PROXY_SCHEME="http"
STOP_PROXY_TUNNEL=0
STOP_API_TUNNEL=0
LOCAL_API_SPEC=""
LOCAL_API_PORT=""
REMOTE_API_PORT=""
API_SCHEME="http"
OPENAI_BASE_URL=""
CLEAR_OPENAI_BASE_URL=0
API_PROVIDER_NAME="codex2api"
API_PROVIDER_BASE_URL=""
CLEAR_API_PROVIDER=0
API_KEY_PROMPT=0
API_KEY_ENV_NAME=""
API_KEY_FILE=""
COPY_LOCAL_AUTH=0
SSH_ALIVE_INTERVAL=15
SSH_ALIVE_COUNT_MAX=8
SSH_CONNECT_TIMEOUT=15
SSH_CONTROL_PERSIST=10m
TUNNEL_CHECK_INTERVAL=15
TUNNEL_RETRY_INTERVAL=10
SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/autodl_codex"
CONFIG_FILE="$SSH_DIR/config"
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive|-I)
      INTERACTIVE=1
      SSH_PASSWORD_PROMPT=1
      shift
      ;;
    --ssh-password-prompt)
      SSH_PASSWORD_PROMPT=1
      shift
      ;;
    --ssh-password-file)
      [[ $# -ge 2 ]] || die "--ssh-password-file requires a file path"
      SSH_PASSWORD_FILE="$2"
      shift 2
      ;;
    --alias)
      [[ $# -ge 2 ]] || die "--alias requires a value"
      ALIAS="$2"
      shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || die "--proxy requires a URL"
      REMOTE_PROXY_URL="$2"
      shift 2
      ;;
    --local-proxy-port)
      [[ $# -ge 2 ]] || die "--local-proxy-port requires a port or LOCAL:REMOTE port pair"
      LOCAL_PROXY_SPEC="$2"
      shift 2
      ;;
    --proxy-scheme)
      [[ $# -ge 2 ]] || die "--proxy-scheme requires a value"
      PROXY_SCHEME="$2"
      shift 2
      ;;
    --local-api-port)
      [[ $# -ge 2 ]] || die "--local-api-port requires a port or LOCAL:REMOTE port pair"
      LOCAL_API_SPEC="$2"
      shift 2
      ;;
    --api-scheme)
      [[ $# -ge 2 ]] || die "--api-scheme requires a value"
      API_SCHEME="$2"
      shift 2
      ;;
    --openai-base-url)
      [[ $# -ge 2 ]] || die "--openai-base-url requires a URL"
      OPENAI_BASE_URL="$2"
      shift 2
      ;;
    --api-base-url)
      [[ $# -ge 2 ]] || die "--api-base-url requires a URL"
      API_PROVIDER_BASE_URL="$2"
      shift 2
      ;;
    --api-provider-name)
      [[ $# -ge 2 ]] || die "--api-provider-name requires a value"
      API_PROVIDER_NAME="$2"
      shift 2
      ;;
    --clear-api-provider)
      CLEAR_API_PROVIDER=1
      shift
      ;;
    --clear-openai-base-url)
      CLEAR_OPENAI_BASE_URL=1
      shift
      ;;
    --clear-proxy)
      CLEAR_REMOTE_PROXY=1
      shift
      ;;
    --stop-proxy-tunnel)
      STOP_PROXY_TUNNEL=1
      shift
      ;;
    --stop-api-tunnel)
      STOP_API_TUNNEL=1
      shift
      ;;
    --api-key-prompt)
      API_KEY_PROMPT=1
      shift
      ;;
    --api-key-env)
      [[ $# -ge 2 ]] || die "--api-key-env requires an environment variable name"
      API_KEY_ENV_NAME="$2"
      shift 2
      ;;
    --api-key-file)
      [[ $# -ge 2 ]] || die "--api-key-file requires a file path"
      API_KEY_FILE="$2"
      shift 2
      ;;
    --copy-local-auth)
      COPY_LOCAL_AUTH=1
      shift
      ;;
    --diagnose)
      RUN_DIAGNOSE=1
      shift
      ;;
    --skip-codex-install)
      SKIP_CODEX_INSTALL=1
      shift
      ;;
    --install-codex)
      echo "Note: --install-codex is now the default; continuing." >&2
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      ARGS+=("$@")
      break
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$INTERACTIVE" -eq 1 ]]; then
  ALIAS="$(prompt_with_default "Connection alias, ASCII only" "$ALIAS")"
  if [[ ${#ARGS[@]} -eq 0 ]]; then
    SSH_COMMAND_INPUT="$(prompt_with_default "Paste AutoDL SSH command" "")"
    [[ -n "$SSH_COMMAND_INPUT" ]] || die "SSH command cannot be empty in interactive mode"
    ARGS=("$SSH_COMMAND_INPUT")
  fi
fi

[[ "$ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || die "alias can only contain letters, numbers, dot, underscore, and dash"
if [[ "$SSH_PASSWORD_PROMPT" -eq 1 && -n "$SSH_PASSWORD_FILE" ]]; then
  die "--ssh-password-prompt and --ssh-password-file cannot be used together"
fi
if [[ -n "$REMOTE_PROXY_URL" && "$CLEAR_REMOTE_PROXY" -eq 1 ]]; then
  die "--proxy and --clear-proxy cannot be used together"
fi
if [[ -n "$REMOTE_PROXY_URL" && -n "$LOCAL_PROXY_SPEC" ]]; then
  die "--proxy and --local-proxy-port cannot be used together"
fi
if [[ -n "$LOCAL_PROXY_SPEC" && -n "$LOCAL_API_SPEC" ]]; then
  die "--local-proxy-port and --local-api-port are different modes; use only one"
fi
if [[ -n "$REMOTE_PROXY_URL" && -n "$LOCAL_API_SPEC" ]]; then
  die "--proxy and --local-api-port are different modes; use only one"
fi
if [[ -n "$OPENAI_BASE_URL" && "$CLEAR_OPENAI_BASE_URL" -eq 1 ]]; then
  die "--openai-base-url and --clear-openai-base-url cannot be used together"
fi
if [[ -n "$OPENAI_BASE_URL" && -n "$LOCAL_API_SPEC" ]]; then
  die "--openai-base-url and --local-api-port cannot be used together"
fi
if [[ -n "$API_PROVIDER_BASE_URL" && "$CLEAR_API_PROVIDER" -eq 1 ]]; then
  die "--api-base-url and --clear-api-provider cannot be used together"
fi
if [[ -n "$API_PROVIDER_BASE_URL" && -n "$LOCAL_API_SPEC" ]]; then
  die "--api-base-url and --local-api-port cannot be used together"
fi
if [[ -n "$OPENAI_BASE_URL" && -n "$API_PROVIDER_BASE_URL" ]]; then
  die "--openai-base-url and --api-base-url are different modes; use only one"
fi
auth_action_count=0
[[ "$API_KEY_PROMPT" -eq 1 ]] && auth_action_count=$((auth_action_count + 1))
[[ -n "$API_KEY_ENV_NAME" ]] && auth_action_count=$((auth_action_count + 1))
[[ -n "$API_KEY_FILE" ]] && auth_action_count=$((auth_action_count + 1))
[[ "$COPY_LOCAL_AUTH" -eq 1 ]] && auth_action_count=$((auth_action_count + 1))
if (( auth_action_count > 1 )); then
  die "use only one auth option: --api-key-prompt, --api-key-env, --api-key-file, or --copy-local-auth"
fi
case "$PROXY_SCHEME" in
  http|socks5|socks5h) ;;
  *) die "--proxy-scheme must be one of: http, socks5, socks5h" ;;
esac
case "$API_SCHEME" in
  http|https) ;;
  *) die "--api-scheme must be one of: http, https" ;;
esac

if [[ -n "$LOCAL_PROXY_SPEC" ]]; then
  if [[ "$LOCAL_PROXY_SPEC" == *:* ]]; then
    LOCAL_PROXY_PORT="${LOCAL_PROXY_SPEC%%:*}"
    REMOTE_PROXY_PORT="${LOCAL_PROXY_SPEC#*:}"
  else
    LOCAL_PROXY_PORT="$LOCAL_PROXY_SPEC"
    REMOTE_PROXY_PORT="$LOCAL_PROXY_SPEC"
  fi

  [[ "$LOCAL_PROXY_PORT" =~ ^[0-9]+$ ]] || die "local proxy port must be numeric: $LOCAL_PROXY_PORT"
  [[ "$REMOTE_PROXY_PORT" =~ ^[0-9]+$ ]] || die "remote proxy port must be numeric: $REMOTE_PROXY_PORT"
  REMOTE_PROXY_URL="$PROXY_SCHEME://127.0.0.1:$REMOTE_PROXY_PORT"
fi

if [[ -z "$REMOTE_PROXY_PORT" ]]; then
  REMOTE_PROXY_PORT="7890"
fi

if [[ -n "$LOCAL_API_SPEC" ]]; then
  if [[ "$LOCAL_API_SPEC" == *:* ]]; then
    LOCAL_API_PORT="${LOCAL_API_SPEC%%:*}"
    REMOTE_API_PORT="${LOCAL_API_SPEC#*:}"
  else
    LOCAL_API_PORT="$LOCAL_API_SPEC"
    REMOTE_API_PORT="$LOCAL_API_SPEC"
  fi

  [[ "$LOCAL_API_PORT" =~ ^[0-9]+$ ]] || die "local API port must be numeric: $LOCAL_API_PORT"
  [[ "$REMOTE_API_PORT" =~ ^[0-9]+$ ]] || die "remote API port must be numeric: $REMOTE_API_PORT"
  API_PROVIDER_BASE_URL="$API_SCHEME://127.0.0.1:$REMOTE_API_PORT/v1"
  if [[ -z "$REMOTE_PROXY_URL" ]]; then
    CLEAR_REMOTE_PROXY=1
  fi
fi

if [[ -z "$REMOTE_API_PORT" ]]; then
  REMOTE_API_PORT="8080"
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
  ensure_ssh_reliability_override "$ALIAS"

  if [[ "$STOP_PROXY_TUNNEL" -eq 1 ]]; then
    require_cmd ssh
    stop_reverse_proxy_tunnel "$ALIAS" "$REMOTE_PROXY_PORT"
  fi

  if [[ "$STOP_API_TUNNEL" -eq 1 ]]; then
    require_cmd ssh
    stop_reverse_proxy_tunnel "$ALIAS" "$REMOTE_API_PORT"
  fi

  if [[ -n "$LOCAL_PROXY_SPEC" && "$STOP_PROXY_TUNNEL" -eq 0 ]]; then
    require_cmd ssh
    start_reverse_proxy_tunnel "$ALIAS" "$LOCAL_PROXY_PORT" "$REMOTE_PROXY_PORT"
  fi

  if [[ -n "$LOCAL_API_SPEC" && "$STOP_API_TUNNEL" -eq 0 ]]; then
    require_cmd ssh
    start_reverse_proxy_tunnel "$ALIAS" "$LOCAL_API_PORT" "$REMOTE_API_PORT"
  fi

  if [[ (-n "$REMOTE_PROXY_URL" && "$STOP_PROXY_TUNNEL" -eq 0) || "$CLEAR_REMOTE_PROXY" -eq 1 ]]; then
    require_cmd ssh
    configure_remote_proxy "$ALIAS" "$REMOTE_PROXY_URL" "$CLEAR_REMOTE_PROXY"
  fi

  if [[ -n "$OPENAI_BASE_URL" || "$CLEAR_OPENAI_BASE_URL" -eq 1 ]]; then
    require_cmd ssh
    configure_remote_openai_base_url "$ALIAS" "$OPENAI_BASE_URL" "$CLEAR_OPENAI_BASE_URL"
  fi

  if [[ -n "$API_PROVIDER_BASE_URL" || "$CLEAR_API_PROVIDER" -eq 1 ]]; then
    require_cmd ssh
    configure_remote_api_provider "$ALIAS" "$API_PROVIDER_NAME" "$API_PROVIDER_BASE_URL" "$CLEAR_API_PROVIDER"
  fi

  if [[ "$API_KEY_PROMPT" -eq 1 ]]; then
    require_cmd ssh
    printf "Remote Codex API key (codex2api mode uses your codex2api key; input hidden, not saved): "
    IFS= read -r -s REMOTE_CODEX_API_KEY
    echo
    install_remote_api_key "$ALIAS" "$REMOTE_CODEX_API_KEY"
    unset REMOTE_CODEX_API_KEY
  elif [[ -n "$API_KEY_ENV_NAME" ]]; then
    require_cmd ssh
    [[ -n "${!API_KEY_ENV_NAME:-}" ]] || die "environment variable is empty or unset: $API_KEY_ENV_NAME"
    install_remote_api_key "$ALIAS" "${!API_KEY_ENV_NAME}"
  elif [[ -n "$API_KEY_FILE" ]]; then
    require_cmd ssh
    REMOTE_CODEX_API_KEY="$(read_first_line_from_file "remote Codex API key" "$API_KEY_FILE")"
    install_remote_api_key "$ALIAS" "$REMOTE_CODEX_API_KEY"
    unset REMOTE_CODEX_API_KEY
  elif [[ "$COPY_LOCAL_AUTH" -eq 1 ]]; then
    require_cmd ssh
    copy_local_auth_to_remote "$ALIAS"
  fi

  if [[ "$RUN_DIAGNOSE" -eq 1 ]]; then
    require_cmd ssh
    run_remote_diagnostics "$ALIAS"
    exit 0
  fi

  if [[ -n "$REMOTE_PROXY_URL" || "$CLEAR_REMOTE_PROXY" -eq 1 || "$STOP_PROXY_TUNNEL" -eq 1 || "$STOP_API_TUNNEL" -eq 1 || "$auth_action_count" -gt 0 || -n "$OPENAI_BASE_URL" || "$CLEAR_OPENAI_BASE_URL" -eq 1 || -n "$API_PROVIDER_BASE_URL" || "$CLEAR_API_PROVIDER" -eq 1 ]]; then
    exit 0
  fi

  usage
  exit 1
fi

SSH_COMMAND="${ARGS[*]}"
read -r -a TOKENS <<< "$SSH_COMMAND"
[[ "${TOKENS[0]:-}" == "ssh" ]] || die "input must start with ssh"

PORT=""
USER=""
HOST=""

i=1
while [[ $i -lt ${#TOKENS[@]} ]]; do
  token="${TOKENS[$i]}"
  case "$token" in
    -p)
      (( i + 1 < ${#TOKENS[@]} )) || die "-p requires a port"
      PORT="${TOKENS[$((i + 1))]}"
      i=$((i + 2))
      ;;
    -p*)
      PORT="${token#-p}"
      i=$((i + 1))
      ;;
    -l)
      (( i + 1 < ${#TOKENS[@]} )) || die "-l requires a user"
      USER="${TOKENS[$((i + 1))]}"
      i=$((i + 2))
      ;;
    -o|-i|-J)
      # Skip supported ssh option values if the user pasted a longer command.
      (( i + 1 < ${#TOKENS[@]} )) || die "$token requires a value"
      i=$((i + 2))
      ;;
    -*)
      die "unsupported ssh option in pasted command: $token"
      ;;
    *)
      if [[ "$token" == *@* ]]; then
        USER="${token%@*}"
        HOST="${token#*@}"
      elif [[ -z "$HOST" ]]; then
        HOST="$token"
      fi
      i=$((i + 1))
      ;;
  esac
done

[[ -n "$HOST" ]] || die "could not parse host from: $SSH_COMMAND"
[[ -n "$USER" ]] || USER="root"
[[ -n "$PORT" ]] || PORT="22"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "port must be numeric: $PORT"

require_cmd ssh
require_cmd scp
require_cmd ssh-keygen
require_cmd expect
require_cmd curl

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Generating SSH key: $KEY_FILE"
  ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "codex-autodl" >/dev/null
else
  echo "Reusing SSH key: $KEY_FILE"
fi

chmod 600 "$KEY_FILE"
PUBKEY="$(cat "$KEY_FILE.pub")"
PUBKEY_Q="$(shell_quote "$PUBKEY")"

echo
echo "Parsed AutoDL SSH target:"
echo "  alias: $ALIAS"
echo "  user:  $USER"
echo "  host:  $HOST"
echo "  port:  $PORT"
echo

KEY_LOGIN_READY=0
echo "Trying existing key login first..."
if ssh \
  -i "$KEY_FILE" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" \
  -o "ServerAliveInterval=$SSH_ALIVE_INTERVAL" \
  -o "ServerAliveCountMax=$SSH_ALIVE_COUNT_MAX" \
  -o TCPKeepAlive=yes \
  -o IPQoS=none \
  -o StrictHostKeyChecking=accept-new \
  -p "$PORT" \
  "$USER@$HOST" \
  'echo CODEX_AUTODL_KEY_OK' | grep -q 'CODEX_AUTODL_KEY_OK'; then
  KEY_LOGIN_READY=1
  if [[ "$SSH_PASSWORD_PROMPT" -eq 1 ]]; then
    echo "Existing key already works, but password upload is forced for this target."
  else
    echo "Existing key already works; password prompt skipped."
  fi
fi

PASSWORD_UPLOAD_DONE=0
if [[ "$KEY_LOGIN_READY" -ne 1 || "$SSH_PASSWORD_PROMPT" -eq 1 ]]; then
  upload_public_key_with_password "$PORT" "$USER" "$HOST" "$PUBKEY_Q"
  PASSWORD_UPLOAD_DONE=1
fi

echo "Writing SSH config: $CONFIG_FILE"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

TMP_CONFIG="$(mktemp)"
awk \
  -v alias="$ALIAS" \
  -v reliability_begin="# >>> codex2autodl ssh reliability: $ALIAS >>>" \
  -v reliability_end="# <<< codex2autodl ssh reliability: $ALIAS <<<" '
  $0 == reliability_begin { reliability_skip = 1; next }
  $0 == reliability_end { reliability_skip = 0; next }
  reliability_skip == 1 { next }
  $1 == "Host" {
    skip = 0
    for (i = 2; i <= NF; i++) {
      if ($i == alias) {
        skip = 1
      }
    }
  }
  skip != 1 {
    print
  }
' "$CONFIG_FILE" > "$TMP_CONFIG"

{
  printf "# Added by codex2autodl setup script\n"
  printf "Host %s\n" "$ALIAS"
  printf "  HostName %s\n" "$HOST"
  printf "  User %s\n" "$USER"
  printf "  Port %s\n" "$PORT"
  printf "  IdentityFile %s\n" "$KEY_FILE"
  printf "  IdentitiesOnly yes\n"
  printf "  ServerAliveInterval %s\n" "$SSH_ALIVE_INTERVAL"
  printf "  ServerAliveCountMax %s\n" "$SSH_ALIVE_COUNT_MAX"
  printf "  TCPKeepAlive yes\n"
  printf "  IPQoS none\n"
  printf "  ConnectTimeout %s\n" "$SSH_CONNECT_TIMEOUT"
  printf "  ControlMaster auto\n"
  printf "  ControlPath %s/codex2autodl-%%C.sock\n" "$SSH_DIR"
  printf "  ControlPersist %s\n" "$SSH_CONTROL_PERSIST"
  printf "\n"
  cat "$TMP_CONFIG"
} > "$CONFIG_FILE"

rm -f "$TMP_CONFIG"
chmod 600 "$CONFIG_FILE"

echo "Verifying passwordless SSH..."
if ssh -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" "$ALIAS" 'echo CODEX_AUTODL_SSH_OK' | grep -q 'CODEX_AUTODL_SSH_OK'; then
  echo "Passwordless SSH is ready: ssh $ALIAS"
else
  if [[ "$PASSWORD_UPLOAD_DONE" -eq 0 ]]; then
    echo "Passwordless SSH via alias failed; uploading key with this server's password once..."
    upload_public_key_with_password "$PORT" "$USER" "$HOST" "$PUBKEY_Q"
    echo "Re-verifying passwordless SSH..."
    if ssh -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" "$ALIAS" 'echo CODEX_AUTODL_SSH_OK' | grep -q 'CODEX_AUTODL_SSH_OK'; then
      echo "Passwordless SSH is ready: ssh $ALIAS"
    else
      die "passwordless SSH verification failed. Try: ssh -v $ALIAS"
    fi
  else
    die "passwordless SSH verification failed after password key upload. Try: ssh -v $ALIAS"
  fi
fi

if [[ "$STOP_PROXY_TUNNEL" -eq 1 ]]; then
  stop_reverse_proxy_tunnel "$ALIAS" "$REMOTE_PROXY_PORT"
fi

if [[ "$STOP_API_TUNNEL" -eq 1 ]]; then
  stop_reverse_proxy_tunnel "$ALIAS" "$REMOTE_API_PORT"
fi

if [[ -n "$LOCAL_PROXY_SPEC" && "$STOP_PROXY_TUNNEL" -eq 0 ]]; then
  start_reverse_proxy_tunnel "$ALIAS" "$LOCAL_PROXY_PORT" "$REMOTE_PROXY_PORT"
fi

if [[ -n "$LOCAL_API_SPEC" && "$STOP_API_TUNNEL" -eq 0 ]]; then
  start_reverse_proxy_tunnel "$ALIAS" "$LOCAL_API_PORT" "$REMOTE_API_PORT"
fi

if [[ "$SKIP_CODEX_INSTALL" -eq 0 ]]; then
  echo "Checking remote Codex CLI..."
  remote_arch="$(ssh "$ALIAS" 'uname -m')"
  case "$remote_arch" in
    x86_64|amd64)
      codex_target="x86_64-unknown-linux-musl"
      npm_platform="linux-x64"
      ;;
    aarch64|arm64)
      codex_target="aarch64-unknown-linux-musl"
      npm_platform="linux-arm64"
      ;;
    *)
      die "unsupported remote Linux architecture: $remote_arch"
      ;;
  esac

  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/codex2autodl"
  mkdir -p "$cache_dir"

  asset="codex-package-$codex_target.tar.gz"
  checksum_asset="codex-package_SHA256SUMS"
  archive_path="$cache_dir/$asset"
  checksum_path="$cache_dir/$checksum_asset"
  version_path="$cache_dir/$asset.version"

  remote_codex_version="$(
    ssh "$ALIAS" 'PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; if command -v codex >/dev/null 2>&1; then codex --version | sed -n "s/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p" | head -n 1; fi' ||
      true
  )"

  remote_current_login_shell_ok=0
  if [[ -n "$remote_codex_version" ]] &&
    ssh "$ALIAS" '${SHELL:-/bin/sh} -ilc "command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1"' >/dev/null 2>&1; then
    remote_current_login_shell_ok=1
  fi

  latest_version="$(resolve_latest_codex_version || true)"
  latest_resolution_failed=0

  if [[ -z "$latest_version" ]]; then
    latest_resolution_failed=1
    cached_version=""
    if [[ -f "$version_path" ]]; then
      cached_version="$(cat "$version_path")"
    fi

    if [[ -n "$cached_version" ]]; then
      latest_version="$cached_version"
      echo "Warning: could not resolve latest Codex release; using cached package version $latest_version." >&2
    elif [[ -n "$remote_codex_version" && "$remote_current_login_shell_ok" -eq 1 ]]; then
      echo "Warning: could not resolve latest Codex release; keeping existing remote Codex $remote_codex_version." >&2
      latest_version="$remote_codex_version"
    else
      die "could not resolve latest Codex release and no local cached package is available. Retry later or check GitHub connectivity."
    fi
  fi

  if [[ "$latest_resolution_failed" -eq 0 ]]; then
    echo "Latest Codex release: $latest_version ($codex_target)"
  else
    echo "Selected Codex release: $latest_version ($codex_target)"
  fi

  if [[ "$remote_codex_version" == "$latest_version" && "$remote_current_login_shell_ok" -eq 1 ]]; then
    echo "Remote Codex is already latest and visible to login shell: $remote_codex_version"
  else
    if [[ -n "$remote_codex_version" ]]; then
      echo "Remote Codex version is $remote_codex_version; latest is $latest_version. Updating..."
    else
      echo "Remote Codex is missing. Installing..."
    fi

    npm_tarball_url="https://registry.npmjs.org/@openai/codex/-/codex-$latest_version-$npm_platform.tgz"
    npm_remote_install_ok=0

    echo "Trying fast remote install from npm CDN platform package..."
    if ssh "$ALIAS" \
      "$(remote_env_prefix "$REMOTE_PROXY_URL")CODEX_VERSION='$latest_version' CODEX_TARGET='$codex_target' CODEX_NPM_URL='$npm_tarball_url' sh -s" <<'REMOTE_CODEX_NPM_INSTALL'
set -eu

download_file() {
  output="$1"
  url="$2"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fL --connect-timeout 20 --max-time 300 -o "$output" "$url"; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -O "$output" "$url"; then
        return 0
      fi
    else
      echo "Remote host needs curl or wget for npm CDN install." >&2
      return 127
    fi

    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done
  return 1
}

add_path_block() {
  profile="$1"
  marker_begin="# >>> codex2autodl >>>"
  marker_end="# <<< codex2autodl <<<"
  path_line='export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"'

  if [ -f "$profile" ] && grep -F "$marker_begin" "$profile" >/dev/null 2>&1; then
    return 0
  fi

  {
    printf '\n%s\n' "$marker_begin"
    printf '%s\n' "$path_line"
    printf '%s\n' "$marker_end"
  } >> "$profile"
}

ensure_shell_path() {
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  add_path_block "$HOME/.profile"
  add_path_block "$HOME/.bashrc"
  [ -f "$HOME/.bash_profile" ] && add_path_block "$HOME/.bash_profile"
  [ -f "$HOME/.zprofile" ] && add_path_block "$HOME/.zprofile"
  [ -f "$HOME/.zshrc" ] && add_path_block "$HOME/.zshrc"
}

verify_login_shell_can_see_codex() {
  login_shell="${SHELL:-/bin/sh}"
  if [ ! -x "$login_shell" ]; then
    login_shell="/bin/sh"
  fi

  "$login_shell" -ilc 'command -v codex >/dev/null 2>&1 && codex --version' >/tmp/codex2autodl-login-shell-check.log 2>&1
}

archive="/tmp/codex2autodl-npm-$CODEX_VERSION-$CODEX_TARGET.tgz"
extract_dir="/tmp/codex2autodl-npm-extract-$CODEX_VERSION-$CODEX_TARGET"
rm -rf "$archive" "$extract_dir"
mkdir -p "$extract_dir"

echo "Downloading remote npm tarball: $CODEX_NPM_URL"
download_file "$archive" "$CODEX_NPM_URL"

tar -xzf "$archive" -C "$extract_dir"
vendor_root="$extract_dir/package/vendor/$CODEX_TARGET"
if [ ! -x "$vendor_root/bin/codex" ]; then
  echo "Downloaded npm tarball does not contain expected codex binary: $vendor_root/bin/codex" >&2
  exit 89
fi

bin_dir="$HOME/.local/bin"
codex_home="${CODEX_HOME:-$HOME/.codex}"
standalone_root="$codex_home/packages/standalone"
releases_dir="$standalone_root/releases"
release_name="$CODEX_VERSION-$CODEX_TARGET"
release_dir="$releases_dir/$release_name"
stage_dir="$releases_dir/.staging.$release_name.$$"

mkdir -p "$bin_dir" "$releases_dir" "$standalone_root"
rm -rf "$stage_dir"
mkdir -p "$stage_dir"
cp -R "$vendor_root/." "$stage_dir/"

chmod 0755 "$stage_dir/bin/codex" "$stage_dir/codex-path/rg"
if [ -f "$stage_dir/codex-resources/bwrap" ]; then
  chmod 0755 "$stage_dir/codex-resources/bwrap"
fi
ln -sf "bin/codex" "$stage_dir/codex"

rm -rf "$release_dir"
mv "$stage_dir" "$release_dir"

tmp_current="$standalone_root/.current.$$"
ln -s "$release_dir" "$tmp_current"
rm -f "$standalone_root/current"
mv -f "$tmp_current" "$standalone_root/current"

tmp_codex="$bin_dir/.codex.$$"
ln -s "$standalone_root/current/bin/codex" "$tmp_codex"
rm -f "$bin_dir/codex"
mv -f "$tmp_codex" "$bin_dir/codex"

ensure_shell_path
codex --version

if verify_login_shell_can_see_codex; then
  echo "Remote login shell can find codex."
else
  echo "Codex is installed, but the remote login shell still cannot find it." >&2
  echo "Login-shell check output:" >&2
  cat /tmp/codex2autodl-login-shell-check.log >&2 || true
  exit 88
fi

rm -rf "$archive" "$extract_dir"
REMOTE_CODEX_NPM_INSTALL
    then
      npm_remote_install_ok=1
    else
      post_npm_version="$(
        ssh "$ALIAS" 'PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; if command -v codex >/dev/null 2>&1; then codex --version | sed -n "s/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p" | head -n 1; fi' ||
          true
      )"
      if [[ "$post_npm_version" == "$latest_version" ]]; then
        echo "Remote npm install reported a non-zero exit, but Codex $post_npm_version is installed. Continuing."
        npm_remote_install_ok=1
      else
        echo "Remote npm CDN install failed; falling back to local GitHub package cache/upload." >&2
      fi
    fi

    if [[ "$npm_remote_install_ok" -ne 1 ]]; then
    archive_url="https://github.com/openai/codex/releases/download/rust-v$latest_version/$asset"
    checksum_url="https://github.com/openai/codex/releases/download/rust-v$latest_version/$checksum_asset"

    file_sha256() {
      if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
      elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
      elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | sed 's/^.*= //'
      else
        die "need shasum, sha256sum, or openssl to verify Codex package"
      fi
    }

    verify_cached_package() {
      [[ -f "$archive_path" && -f "$checksum_path" && -f "$version_path" ]] || return 1
      [[ "$(cat "$version_path")" == "$latest_version" ]] || return 1

      expected_digest="$(awk -v asset="$asset" '$2 == asset { print $1; found = 1 } END { if (!found) exit 1 }' "$checksum_path")" || return 1
      actual_digest="$(file_sha256 "$archive_path")"
      [[ "$expected_digest" == "$actual_digest" ]]
    }

    if verify_cached_package; then
      echo "Using cached Codex package: $archive_path"
    else
      echo "Downloading Codex Linux package locally..."
      tmp_archive="$archive_path.tmp.$$"
      tmp_checksum="$checksum_path.tmp.$$"
      curl_retry -o "$tmp_archive" "$archive_url"
      curl_retry -o "$tmp_checksum" "$checksum_url"
      mv "$tmp_archive" "$archive_path"
      mv "$tmp_checksum" "$checksum_path"
      printf '%s\n' "$latest_version" > "$version_path"

      if ! verify_cached_package; then
        rm -f "$archive_path" "$checksum_path" "$version_path"
        die "downloaded Codex package failed checksum verification"
      fi
      echo "Cached Codex package: $archive_path"
    fi

    remote_tmp_dir="/tmp/codex2autodl-$latest_version-$codex_target"
    ssh "$ALIAS" "rm -rf '$remote_tmp_dir' && mkdir -p '$remote_tmp_dir'"
    echo "Uploading Codex package to remote host..."
    scp "$archive_path" "$checksum_path" "$ALIAS:$remote_tmp_dir/"

    echo "Installing Codex package on remote host..."
    ssh "$ALIAS" \
      "$(remote_env_prefix "$REMOTE_PROXY_URL")CODEX_VERSION='$latest_version' CODEX_TARGET='$codex_target' CODEX_ARCHIVE='$remote_tmp_dir/$asset' CODEX_CHECKSUMS='$remote_tmp_dir/$checksum_asset' sh -s" <<'REMOTE_CODEX_PACKAGE_INSTALL'
set -eu

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else
    echo "Need sha256sum, shasum, or openssl on remote host." >&2
    exit 86
  fi
}

add_path_block() {
  profile="$1"
  marker_begin="# >>> codex2autodl >>>"
  marker_end="# <<< codex2autodl <<<"
  path_line='export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"'

  if [ -f "$profile" ] && grep -F "$marker_begin" "$profile" >/dev/null 2>&1; then
    return 0
  fi

  {
    printf '\n%s\n' "$marker_begin"
    printf '%s\n' "$path_line"
    printf '%s\n' "$marker_end"
  } >> "$profile"
}

ensure_shell_path() {
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  add_path_block "$HOME/.profile"
  add_path_block "$HOME/.bashrc"
  [ -f "$HOME/.bash_profile" ] && add_path_block "$HOME/.bash_profile"
  [ -f "$HOME/.zprofile" ] && add_path_block "$HOME/.zprofile"
  [ -f "$HOME/.zshrc" ] && add_path_block "$HOME/.zshrc"
}

verify_login_shell_can_see_codex() {
  login_shell="${SHELL:-/bin/sh}"
  if [ ! -x "$login_shell" ]; then
    login_shell="/bin/sh"
  fi

  "$login_shell" -ilc 'command -v codex >/dev/null 2>&1 && codex --version' >/tmp/codex2autodl-login-shell-check.log 2>&1
}

expected_digest="$(awk -v asset="$(basename "$CODEX_ARCHIVE")" '$2 == asset { print $1; found = 1 } END { if (!found) exit 1 }' "$CODEX_CHECKSUMS")"
actual_digest="$(file_sha256 "$CODEX_ARCHIVE")"
if [ "$expected_digest" != "$actual_digest" ]; then
  echo "Remote package checksum mismatch." >&2
  echo "expected: $expected_digest" >&2
  echo "actual:   $actual_digest" >&2
  exit 87
fi

bin_dir="$HOME/.local/bin"
codex_home="${CODEX_HOME:-$HOME/.codex}"
standalone_root="$codex_home/packages/standalone"
releases_dir="$standalone_root/releases"
release_name="$CODEX_VERSION-$CODEX_TARGET"
release_dir="$releases_dir/$release_name"
stage_dir="$releases_dir/.staging.$release_name.$$"

mkdir -p "$bin_dir" "$releases_dir" "$standalone_root"
rm -rf "$stage_dir"
mkdir -p "$stage_dir"
tar -xzf "$CODEX_ARCHIVE" -C "$stage_dir"

chmod 0755 "$stage_dir/bin/codex" "$stage_dir/codex-path/rg"
if [ -f "$stage_dir/codex-resources/bwrap" ]; then
  chmod 0755 "$stage_dir/codex-resources/bwrap"
fi
ln -sf "bin/codex" "$stage_dir/codex"

rm -rf "$release_dir"
mv "$stage_dir" "$release_dir"

tmp_current="$standalone_root/.current.$$"
ln -s "$release_dir" "$tmp_current"
rm -f "$standalone_root/current"
mv -f "$tmp_current" "$standalone_root/current"

tmp_codex="$bin_dir/.codex.$$"
ln -s "$standalone_root/current/bin/codex" "$tmp_codex"
rm -f "$bin_dir/codex"
mv -f "$tmp_codex" "$bin_dir/codex"

ensure_shell_path
codex --version

if verify_login_shell_can_see_codex; then
  echo "Remote login shell can find codex."
else
  echo "Codex is installed, but the remote login shell still cannot find it." >&2
  echo "Login-shell check output:" >&2
  cat /tmp/codex2autodl-login-shell-check.log >&2 || true
  exit 88
fi
REMOTE_CODEX_PACKAGE_INSTALL

    ssh "$ALIAS" "rm -rf '$remote_tmp_dir'"
    fi
  fi
else
  echo
  echo "Skipped remote Codex CLI installation/check."
  echo "Manual check:"
  echo "  ssh $ALIAS 'command -v codex && codex --version'"
fi

if [[ -n "$REMOTE_PROXY_URL" || "$CLEAR_REMOTE_PROXY" -eq 1 ]]; then
  configure_remote_proxy "$ALIAS" "$REMOTE_PROXY_URL" "$CLEAR_REMOTE_PROXY"
fi

if [[ -n "$OPENAI_BASE_URL" || "$CLEAR_OPENAI_BASE_URL" -eq 1 ]]; then
  configure_remote_openai_base_url "$ALIAS" "$OPENAI_BASE_URL" "$CLEAR_OPENAI_BASE_URL"
fi

if [[ -n "$API_PROVIDER_BASE_URL" || "$CLEAR_API_PROVIDER" -eq 1 ]]; then
  configure_remote_api_provider "$ALIAS" "$API_PROVIDER_NAME" "$API_PROVIDER_BASE_URL" "$CLEAR_API_PROVIDER"
fi

if [[ "$API_KEY_PROMPT" -eq 1 ]]; then
  printf "Remote Codex API key (codex2api mode uses your codex2api key; input hidden, not saved): "
  IFS= read -r -s REMOTE_CODEX_API_KEY
  echo
  install_remote_api_key "$ALIAS" "$REMOTE_CODEX_API_KEY"
  unset REMOTE_CODEX_API_KEY
elif [[ -n "$API_KEY_ENV_NAME" ]]; then
  [[ -n "${!API_KEY_ENV_NAME:-}" ]] || die "environment variable is empty or unset: $API_KEY_ENV_NAME"
  install_remote_api_key "$ALIAS" "${!API_KEY_ENV_NAME}"
elif [[ -n "$API_KEY_FILE" ]]; then
  REMOTE_CODEX_API_KEY="$(read_first_line_from_file "remote Codex API key" "$API_KEY_FILE")"
  install_remote_api_key "$ALIAS" "$REMOTE_CODEX_API_KEY"
  unset REMOTE_CODEX_API_KEY
elif [[ "$COPY_LOCAL_AUTH" -eq 1 ]]; then
  copy_local_auth_to_remote "$ALIAS"
fi

echo
echo "Done. In Codex App, open Settings -> Connections and add/select SSH host:"
echo "  $ALIAS"

if [[ "$RUN_DIAGNOSE" -eq 1 ]]; then
  run_remote_diagnostics "$ALIAS"
fi
