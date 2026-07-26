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
  scripts/setup-autodl-codex.sh [--alias NAME] --quick-reconnect --local-api-port PORT
  scripts/setup-autodl-codex.sh --quick-reconnect-active [--active-alias-port ALIAS=LOCAL[:REMOTE]]... [--local-api-port PORT]

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
  scripts/setup-autodl-codex.sh --alias autodl-v3 --quick-reconnect --local-api-port 8080
  scripts/setup-autodl-codex.sh --quick-reconnect-active --local-api-port 8080

What it does:
  1. Generates ~/.ssh/autodl_codex if missing.
  2. Uses your AutoDL password once to append the public key on the remote host.
  3. Writes a concrete Host alias into ~/.ssh/config.
  4. Verifies passwordless SSH with BatchMode=yes.
  5. Checks the latest Codex CLI release.
  6. Installs Codex on the remote host from the npm CDN platform tarball when possible.
  7. Falls back to a locally cached GitHub release package upload when npm CDN install fails.
  8. Optionally writes proxy env vars to the remote shell profile and restarts remote Codex app-server.
  9. Optionally starts a launchd-supervised SSH reverse tunnel from AutoDL back to your Mac local proxy/API port.
  10. Optionally logs the remote Codex CLI in with an API key.
  11. Optionally points Codex at a local OpenAI-compatible API reverse proxy.
  12. On connect, syncs local Codex skills (~/.codex/skills, ~/.agents/skills) to remote ~/.codex/skills (skip with --skip-local-skills).
  13. Installs enabled local plugins that also exist in a compatible remote marketplace (skip with --skip-local-plugins).

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

portable_sha256() {
  local file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | sed 's/^.*= //'
  else
    die "need shasum, sha256sum, or openssl to calculate SHA-256"
  fi
}

portable_sha256_text() {
  local value="$1"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 | sed 's/^.*= //'
  else
    die "need shasum, sha256sum, or openssl to calculate SHA-256"
  fi
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

ssh_alias_matches_target() {
  local alias="$1"
  local expected_user="$2"
  local expected_host="$3"
  local expected_port="$4"
  local expected_identity="$5"
  local resolved

  ssh_alias_configured "$alias" || return 1
  resolved="$(ssh -G "$alias" 2>/dev/null)" || return 1
  [[ "$(printf '%s\n' "$resolved" | awk '$1 == "user" { print $2; exit }')" == "$expected_user" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "hostname" { print $2; exit }')" == "$expected_host" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "port" { print $2; exit }')" == "$expected_port" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "identityfile" { print $2; exit }')" == "$expected_identity" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "serveraliveinterval" { print $2; exit }')" == "$SSH_ALIVE_INTERVAL" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "serveralivecountmax" { print $2; exit }')" == "$SSH_ALIVE_COUNT_MAX" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "tcpkeepalive" { print $2; exit }')" == "yes" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "ipqos" { print $2, $3; exit }')" == "none none" ]] &&
    [[ "$(printf '%s\n' "$resolved" | awk '$1 == "connecttimeout" { print $2; exit }')" == "$SSH_CONNECT_TIMEOUT" ]]
}

list_codex2autodl_aliases_for_target() {
  local target_user="$1"
  local target_host="$2"
  local target_port="$3"
  local exclude_alias="${4:-}"

  [[ -f "$CONFIG_FILE" ]] || return 0
  awk \
    -v target_user="$target_user" \
    -v target_host="$target_host" \
    -v target_port="$target_port" \
    -v exclude_alias="$exclude_alias" '
    function reset_block() {
      managed = 0
      alias = ""
      host = ""
      user = ""
      port = ""
    }
    function flush_block() {
      if (managed == 1 && alias != "" && alias != exclude_alias && host == target_host && user == target_user && port == target_port) {
        print alias
      }
      reset_block()
    }
    BEGIN {
      reset_block()
    }
    /^# Added by codex2autodl setup script$/ {
      flush_block()
      managed = 1
      next
    }
    $1 == "Host" {
      if (managed == 1 && alias == "") {
        alias = $2
      } else {
        flush_block()
      }
      next
    }
    managed == 1 && tolower($1) == "hostname" {
      host = $2
      next
    }
    managed == 1 && tolower($1) == "user" {
      user = $2
      next
    }
    managed == 1 && tolower($1) == "port" {
      port = $2
      next
    }
    END {
      flush_block()
    }
  ' "$CONFIG_FILE"
}

remove_ssh_aliases_from_config() {
  local alias
  local tmp_config

  [[ -f "$CONFIG_FILE" ]] || return 0
  [[ "$#" -gt 0 ]] || return 0

  for alias in "$@"; do
    [[ -n "$alias" ]] || continue
    tmp_config="$(mktemp)"
    awk \
      -v alias="$alias" \
      -v reliability_begin="# >>> codex2autodl ssh reliability: $alias >>>" \
      -v reliability_end="# <<< codex2autodl ssh reliability: $alias <<<" '
      function flush_pending_marker() {
        if (pending_marker != "") {
          print pending_marker
          pending_marker = ""
        }
      }
      $0 == reliability_begin { reliability_skip = 1; next }
      $0 == reliability_end { reliability_skip = 0; next }
      reliability_skip == 1 { next }
      /^# Added by codex2autodl setup script$/ {
        pending_marker = $0
        next
      }
      $1 == "Host" {
        skip = 0
        for (i = 2; i <= NF; i++) {
          if ($i == alias) {
            skip = 1
          }
        }
        if (skip == 1) {
          pending_marker = ""
          next
        }
        flush_pending_marker()
        print
        next
      }
      skip != 1 {
        flush_pending_marker()
        print
      }
      END {
        flush_pending_marker()
      }
    ' "$CONFIG_FILE" > "$tmp_config"
    cat "$tmp_config" > "$CONFIG_FILE"
    rm -f "$tmp_config"
  done

  chmod 600 "$CONFIG_FILE"
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

resolve_local_codex_binary() {
  local candidate
  local command_codex=""

  command_codex="$(command -v codex 2>/dev/null || true)"
  for candidate in \
    "${CODEX_INSTALL_DIR:-}/codex" \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$command_codex"; do
    [[ -n "$candidate" && "$candidate" != "/codex" && -x "$candidate" ]] || continue
    if "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

resolve_desktop_codex_version() {
  local codex_binary

  codex_binary="$(resolve_local_codex_binary)" || return 1
  "$codex_binary" --version 2>/dev/null |
    sed -n 's/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p' |
    head -n 1
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
  if remote_loopback_port_open "$alias" "$REMOTE_API_PORT" "$api_control_path"; then
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
    if remote_loopback_port_open "$alias" "$REMOTE_PROXY_PORT" "$proxy_control_path"; then
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
provider_api_key=""
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
if [ -f "$HOME/.codex/auth.json" ]; then
  provider_api_key="$(
    tr -d '\n' < "$HOME/.codex/auth.json" |
      sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  )"
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
      if [ -n "$provider_api_key" ]; then
        curl -sS -i --connect-timeout 10 --max-time 20 \
          -H "Authorization: Bearer $provider_api_key" \
          "$provider_test_url" 2>&1 |
          sed -E "s/(sk|ccr-profile)-[A-Za-z0-9_-]+/\1-<redacted>/g" |
          sed -n "1,16p"
      else
        curl -sS -i --connect-timeout 10 --max-time 20 "$provider_test_url" 2>&1 |
          sed -n "1,16p"
      fi
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
    if [ -n "$provider_api_key" ]; then
      curl -sS -i --connect-timeout 10 --max-time 20 \
        -H "Authorization: Bearer $provider_api_key" \
        "$api_test_url" 2>&1 |
        sed -E "s/(sk|ccr-profile)-[A-Za-z0-9_-]+/\1-<redacted>/g" |
        sed -n "1,16p"
    else
      curl -sS -i --connect-timeout 10 --max-time 20 "$api_test_url" 2>&1 |
        sed -n "1,16p"
    fi
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
  REMOTE_APP_SERVER_RESTARTED=1
}

refresh_remote_codex_wrapper() {
  local alias="$1"

  ssh "$alias" 'sh -s' <<'REMOTE_REFRESH_CODEX_WRAPPER'
set -eu
bin_dir="$HOME/.local/bin"
codex_home="${CODEX_HOME:-$HOME/.codex}"
real_codex="$codex_home/packages/standalone/current/bin/codex"
wrapper="$bin_dir/codex"

[ -x "$real_codex" ] || exit 0
mkdir -p "$bin_dir"

if [ -f "$codex_home/codex2autodl-env" ]; then
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
elif [ -f "$wrapper" ] && grep -F "codex2autodl wrapper" "$wrapper" >/dev/null 2>&1; then
  rm -f "$wrapper"
  ln -s "$real_codex" "$wrapper"
fi
REMOTE_REFRESH_CODEX_WRAPPER
}

install_remote_api_key() {
  local alias="$1"
  local api_key="$2"
  local api_key_digest

  [[ -n "$api_key" ]] || die "API key cannot be empty"
  api_key_digest="$(portable_sha256_text "$api_key")"

  if ssh "$alias" "CODEX_AUTODL_API_KEY_DIGEST=$(shell_quote "$api_key_digest") sh -s" <<'REMOTE_CHECK_API_KEY'
set -eu
auth_file="$HOME/.codex/auth.json"
[ -f "$auth_file" ] || exit 1
api_key="$(
  tr -d '\n' < "$auth_file" |
    sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
)"
[ -n "$api_key" ] || exit 1
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(printf '%s' "$api_key" | sha256sum | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  digest="$(printf '%s' "$api_key" | shasum -a 256 | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  digest="$(printf '%s' "$api_key" | openssl dgst -sha256 | sed 's/^.*= //')"
else
  exit 1
fi
unset api_key
[ "$digest" = "$CODEX_AUTODL_API_KEY_DIGEST" ]
REMOTE_CHECK_API_KEY
  then
    echo "Remote Codex API key already current; login and restart skipped."
    return 0
  fi

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

copy_skill_tree() {
  local src="$1"
  local dest="$2"

  mkdir -p "$dest"
  # -h: follow symlinks so remote gets real skill files, not broken Mac paths
  tar -C "$src" -chf - . | tar -C "$dest" -xf -
}

collect_local_skills_into() {
  local stage="$1"
  local dir="$2"
  local path name
  local count=0

  if [[ ! -d "$dir" ]]; then
    printf '%s\n' 0
    return 0
  fi

  for path in "$dir"/*; do
    [[ -e "$path" ]] || continue
    name="$(basename "$path")"
    # skip hidden dirs like .system (bundled/system skills)
    [[ "$name" == .* ]] && continue
    [[ -d "$path" || -L "$path" ]] || continue
    # only real skills
    [[ -f "$path/SKILL.md" ]] || continue
    # first source wins when same name exists in multiple roots
    [[ -e "$stage/$name" ]] && continue

    copy_skill_tree "$path" "$stage/$name"
    count=$((count + 1))
  done

  printf '%s\n' "$count"
}

sync_local_skills_to_remote() {
  local alias="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local stage manifest names manifest_digest total=0
  local n

  stage="$(mktemp -d "${TMPDIR:-/tmp}/codex2autodl-skills.XXXXXX")"
  manifest="$stage.manifest"
  names="$stage.names"

  n="$(collect_local_skills_into "$stage" "$codex_home/skills")"
  total=$((total + n))
  n="$(collect_local_skills_into "$stage" "$HOME/.agents/skills")"
  total=$((total + n))

  if [[ "$total" -eq 0 ]]; then
    echo "No local skills found; removing only skills previously managed by codex2autodl."
    ssh "$alias" 'sh -s' <<'REMOTE_CLEAR_MANAGED_SKILLS'
set -eu
skills_dir="$HOME/.codex/skills"
names_file="$HOME/.codex/codex2autodl-skills.names"
if [ -f "$names_file" ]; then
  while IFS= read -r name; do
    case "$name" in
      ''|.*|*/*) continue ;;
    esac
    rm -rf "$skills_dir/$name"
  done < "$names_file"
fi
rm -f "$HOME/.codex/codex2autodl-skills.manifest" \
      "$HOME/.codex/codex2autodl-skills.digest" \
      "$names_file"
REMOTE_CLEAR_MANAGED_SKILLS
    rm -rf "$stage" "$manifest" "$names"
    return 0
  fi

  require_cmd python3
  : > "$names"
  for path in "$stage"/*; do
    [[ -d "$path" ]] || continue
    basename "$path" >> "$names"
  done
  LC_ALL=C sort -o "$names" "$names"

  CODEX_AUTODL_SKILLS_STAGE="$stage" python3 - "$manifest" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

root = Path(os.environ["CODEX_AUTODL_SKILLS_STAGE"])
manifest = Path(sys.argv[1])
lines = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    lines.append(f"{digest}  {path.relative_to(root).as_posix()}\n")
manifest.write_text("".join(lines), encoding="utf-8")
PY
  manifest_digest="$(portable_sha256 "$manifest")"

  if ssh "$alias" "CODEX_AUTODL_SKILLS_DIGEST=$(shell_quote "$manifest_digest") sh -s" <<'REMOTE_CHECK_SKILLS'
set -eu
command -v sha256sum >/dev/null 2>&1 || exit 1
skills_dir="$HOME/.codex/skills"
manifest="$HOME/.codex/codex2autodl-skills.manifest"
digest_file="$HOME/.codex/codex2autodl-skills.digest"
names_file="$HOME/.codex/codex2autodl-skills.names"
[ -d "$skills_dir" ] &&
  [ -f "$manifest" ] &&
  [ -f "$digest_file" ] &&
  [ -f "$names_file" ] &&
  [ "$(cat "$digest_file")" = "$CODEX_AUTODL_SKILLS_DIGEST" ] ||
  exit 1

tmp_expected="/tmp/codex2autodl-skills-expected.$$"
tmp_actual="/tmp/codex2autodl-skills-actual.$$"
trap 'rm -f "$tmp_expected" "$tmp_actual"' EXIT
sed 's/^[0-9a-fA-F]*  //' "$manifest" | LC_ALL=C sort > "$tmp_expected"
(
  cd "$skills_dir"
  while IFS= read -r name; do
    case "$name" in
      ''|.*|*/*) continue ;;
    esac
    [ -d "$name" ] && find "$name" -type f -print
  done < "$names_file"
) | LC_ALL=C sort > "$tmp_actual"
cmp -s "$tmp_expected" "$tmp_actual" || exit 1
(cd "$skills_dir" && sha256sum -c "$manifest" >/dev/null 2>&1)
REMOTE_CHECK_SKILLS
  then
    echo "Remote skills already current ($total skill(s)); upload skipped."
    rm -rf "$stage" "$manifest" "$names"
    return 0
  fi

  echo "Remote skills differ; syncing $total skill(s) ..."
  ssh "$alias" 'sh -s' <<'REMOTE_REMOVE_OLD_MANAGED_SKILLS'
set -eu
skills_dir="$HOME/.codex/skills"
names_file="$HOME/.codex/codex2autodl-skills.names"
mkdir -p "$skills_dir"
if [ -f "$names_file" ]; then
  while IFS= read -r name; do
    case "$name" in
      ''|.*|*/*) continue ;;
    esac
    rm -rf "$skills_dir/$name"
  done < "$names_file"
fi
REMOTE_REMOVE_OLD_MANAGED_SKILLS

  (
    cd "$stage"
    tar -czf - .
  ) | ssh "$alias" 'mkdir -p "$HOME/.codex/skills" && tar -xzf - -C "$HOME/.codex/skills"'
  ssh "$alias" 'umask 077; cat > "$HOME/.codex/codex2autodl-skills.manifest"' < "$manifest"
  ssh "$alias" 'umask 077; cat > "$HOME/.codex/codex2autodl-skills.names"' < "$names"
  printf '%s\n' "$manifest_digest" |
    ssh "$alias" 'umask 077; cat > "$HOME/.codex/codex2autodl-skills.digest"'

  echo "Remote skills synchronized."
  rm -rf "$stage" "$manifest" "$names"
}

collect_enabled_local_plugins() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local config_file="$codex_home/config.toml"
  local codex_binary

  codex_binary="$(resolve_local_codex_binary || true)"
  if [[ -n "$codex_binary" ]] &&
    "$codex_binary" plugin list 2>/dev/null |
      awk '
        $1 ~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/ && $0 ~ /installed, enabled/ {
          version = $4
          if (version ~ /^\// || version ~ /^https?:/) {
            version = ""
          }
          print $1 "=" version
        }
      '; then
    return 0
  fi

  [[ -f "$config_file" ]] || return 0
  awk '
    /^\[plugins\."/ {
      plugin = $0
      sub(/^\[plugins\."/, "", plugin)
      sub(/"\][[:space:]]*$/, "", plugin)
      in_plugin = 1
      next
    }
    /^\[/ {
      plugin = ""
      in_plugin = 0
    }
    in_plugin == 1 && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true([[:space:]]*#.*)?$/ {
      print plugin "="
      plugin = ""
      in_plugin = 0
    }
  ' "$config_file"
}

sync_compatible_plugins_to_remote() {
  local alias="$1"
  local plugins

  plugins="$(collect_enabled_local_plugins | tr '\n' ' ')"
  if [[ -z "${plugins// }" ]]; then
    echo "No enabled local Codex plugins found."
    return 0
  fi

  echo "Syncing remotely compatible Codex plugins..."
  ssh "$alias" "CODEX_AUTODL_ENABLED_PLUGINS=$(shell_quote "$plugins") sh -s" <<'REMOTE_PLUGIN_SYNC'
set +e
PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
if ! command -v codex >/dev/null 2>&1; then
  echo "Remote Codex is unavailable; plugin sync skipped." >&2
  exit 0
fi

catalog="$(codex plugin list 2>/dev/null || true)"
available="$(
  printf '%s\n' "$catalog" |
    awk '$1 ~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/ { print $1 }'
)"
enabled="$(
  printf '%s\n' "$catalog" |
    awk '$1 ~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/ && $0 ~ /installed, enabled/ { print $1 }'
)"

for requested_entry in $CODEX_AUTODL_ENABLED_PLUGINS; do
  requested="${requested_entry%%=*}"
  desired_version="${requested_entry#*=}"
  plugin="$requested"
  if ! printf '%s\n' "$available" | grep -Fx "$plugin" >/dev/null 2>&1; then
    case "$plugin" in
      *@openai-curated)
        api_plugin="${plugin%@openai-curated}@openai-api-curated"
        if printf '%s\n' "$available" | grep -Fx "$api_plugin" >/dev/null 2>&1; then
          plugin="$api_plugin"
        fi
        ;;
    esac
  fi

  if ! printf '%s\n' "$available" | grep -Fx "$plugin" >/dev/null 2>&1; then
    echo "  skipped (not available on remote host): $requested"
    continue
  fi

  plugin_line="$(printf '%s\n' "$catalog" | awk -v plugin="$plugin" '$1 == plugin { print; exit }')"
  remote_version="$(printf '%s\n' "$plugin_line" | awk '{ print $4 }')"
  case "$remote_version" in
    ''|/*|http://*|https://*) remote_version="" ;;
  esac
  expected_version="$desired_version"
  if [ -n "$remote_version" ]; then
    expected_version="$remote_version"
  fi

  if printf '%s\n' "$enabled" | grep -Fx "$plugin" >/dev/null 2>&1 &&
    { [ -z "$expected_version" ] || [ "$remote_version" = "$expected_version" ]; }; then
    if [ -n "$remote_version" ]; then
      echo "  already enabled: $plugin ($remote_version)"
    else
      echo "  already enabled: $plugin"
    fi
    continue
  fi

  if printf '%s\n' "$enabled" | grep -Fx "$plugin" >/dev/null 2>&1; then
    codex plugin remove "$plugin" >/dev/null 2>&1 || true
  fi
  if codex plugin add "$plugin" >/dev/null 2>&1; then
    echo "  installed/updated: $plugin${expected_version:+ ($expected_version)}"
  else
    echo "  warning: failed to install $plugin" >&2
  fi
done
REMOTE_PLUGIN_SYNC
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

proxy_tunnel_watchdog_runner_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/.ssh/codex2autodl-%s-proxy-%s.watchdog.sh' "$HOME" "$alias" "$remote_port"
}

proxy_tunnel_log_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/.ssh/codex2autodl-%s-proxy-%s.watchdog.log' "$HOME" "$alias" "$remote_port"
}

proxy_tunnel_launchd_label() {
  local alias="$1"
  local remote_port="$2"
  printf 'com.codex2autodl.tunnel.%s.proxy.%s' "$alias" "$remote_port"
}

proxy_tunnel_launchd_plist_path() {
  local alias="$1"
  local remote_port="$2"
  printf '%s/Library/LaunchAgents/codex2autodl-%s-proxy-%s.plist' "$HOME" "$alias" "$remote_port"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

pid_is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

cleanup_stale_ssh_control_socket() {
  local alias="$1"
  local control_path=""

  control_path="$(ssh -G "$alias" 2>/dev/null | awk '$1 == "controlpath" { print $2; exit }')" || return 0
  [[ -n "$control_path" && "$control_path" == *codex2autodl-* && -S "$control_path" ]] || return 0

  if ! ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
    rm -f "$control_path"
  fi
}

reset_ssh_control_master() {
  local alias="$1"
  local control_path=""

  control_path="$(ssh -G "$alias" 2>/dev/null | awk '$1 == "controlpath" { print $2; exit }')" || return 0
  [[ -n "$control_path" && "$control_path" == *codex2autodl-* && -S "$control_path" ]] || return 0

  echo "Resetting existing SSH control master: $control_path"
  if ssh -S "$control_path" -O exit "$alias" >/dev/null 2>&1; then
    for _ in {1..20}; do
      [[ ! -S "$control_path" ]] && return 0
      sleep 0.1
    done
  fi

  if ! ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
    rm -f "$control_path"
  fi
}

active_codex_remote_aliases() {
  ps -axo command= 2>/dev/null |
    awk '
      /codex app-server proxy/ && /ssh[[:space:]].*-T/ {
        for (i = 1; i <= NF; i++) {
          if ($i != "ssh") {
            continue
          }
          skip = 0
          for (j = i + 1; j <= NF; j++) {
            token = $j
            if (skip == 1) {
              skip = 0
              continue
            }
            if (token == "-o" || token == "-i" || token == "-F" || token == "-S" ||
                token == "-p" || token == "-l" || token == "-J") {
              skip = 1
              continue
            }
            if (token ~ /^-/) {
              continue
            }
            print token
            break
          }
          break
        }
      }
    ' |
    awk '!seen[$0]++'
}

active_alias_port_spec() {
  local alias="$1"
  local mapping

  (( ${#ACTIVE_ALIAS_PORT_SPECS[@]} > 0 )) || return 1
  for mapping in "${ACTIVE_ALIAS_PORT_SPECS[@]}"; do
    if [[ "${mapping%%=*}" == "$alias" ]]; then
      printf '%s\n' "${mapping#*=}"
      return 0
    fi
  done
  return 1
}

remote_port_probe_script() {
  cat <<'REMOTE_PORT_PROBE'
set -u
port="${CODEX2AUTODL_PROBE_PORT:-}"
case "$port" in
  ''|*[!0-9]*) exit 64 ;;
esac

if command -v curl >/dev/null 2>&1; then
  curl -sS --connect-timeout 3 --max-time 5 -o /dev/null "http://127.0.0.1:$port/"
elif command -v wget >/dev/null 2>&1; then
  wget -S -O /dev/null -T 5 "http://127.0.0.1:$port/" 2>&1 | grep -q 'HTTP/'
elif command -v nc >/dev/null 2>&1; then
  nc -z -w 3 127.0.0.1 "$port"
elif command -v bash >/dev/null 2>&1; then
  bash -lc ":</dev/tcp/127.0.0.1/$port"
else
  exit 127
fi
REMOTE_PORT_PROBE
}

rotate_tunnel_log_if_needed() {
  local log_path="$1"
  local max_bytes="${CODEX2AUTODL_TUNNEL_LOG_MAX_BYTES:-1048576}"
  local size

  [[ -f "$log_path" ]] || return 0
  size="$(wc -c < "$log_path" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size > max_bytes )) || return 0

  rm -f "$log_path.3"
  [[ -f "$log_path.2" ]] && mv -f "$log_path.2" "$log_path.3"
  [[ -f "$log_path.1" ]] && mv -f "$log_path.1" "$log_path.2"
  mv -f "$log_path" "$log_path.1"
}

wait_for_reverse_proxy_tunnel() {
  local alias="$1"
  local remote_port="$2"
  local control_path="$3"
  local attempt

  for ((attempt = 1; attempt <= 20; attempt++)); do
    if remote_loopback_port_open "$alias" "$remote_port" "$control_path"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

remote_loopback_port_open() {
  local alias="$1"
  local remote_port="$2"
  local control_path="${3:-}"
  local ssh_args=(
    -o BatchMode=yes
    -o ConnectionAttempts=1
    -o ControlMaster=no
    -o ControlPath=none
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
    -o "ServerAliveInterval=$SSH_ALIVE_INTERVAL"
    -o "ServerAliveCountMax=2"
  )

  if [[ -n "$control_path" ]]; then
    [[ -S "$control_path" ]] || return 1
    ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1 || return 1
  fi

  # 独立连接做真实流量探测，避免把卡住的诊断 session 塞进隧道自己的 ControlMaster。
  remote_port_probe_script |
    ssh "${ssh_args[@]}" "$alias" "CODEX2AUTODL_PROBE_PORT=$(shell_quote "$remote_port") sh -s" >/dev/null 2>&1
}


free_remote_reverse_port() {
  # 远端残留 reverse-forward 占口时，新隧道会报
  # "remote port forwarding failed for listen port N"。
  # 只杀持有该 listen 的 sshd 会话，不动主 sshd。
  local alias="$1"
  local remote_port="$2"
  local control_path="${3:-}"
  local ssh_args=(
    -o BatchMode=yes
    -o ConnectionAttempts=1
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
    -o "ServerAliveInterval=$SSH_ALIVE_INTERVAL"
    -o "ServerAliveCountMax=2"
  )

  if [[ -n "$control_path" ]] && ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
    ssh_args=(-S "$control_path" "${ssh_args[@]}")
  fi

  ssh "${ssh_args[@]}" "$alias" "CODEX2AUTODL_FREE_PORT=$(shell_quote "$remote_port") sh -s" <<'REMOTE_FREE_PORT' >/dev/null 2>&1 || true
set +e
port="${CODEX2AUTODL_FREE_PORT:-}"
case "$port" in
  ''|*[!0-9]*) exit 0 ;;
esac

hex=$(printf '%04X' "$port" 2>/dev/null || true)
[ -n "$hex" ] || exit 0

inodes=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    sl*) continue ;;
  esac
  la=$(echo "$line" | awk '{print $2}')
  st=$(echo "$line" | awk '{print $4}')
  inode=$(echo "$line" | awk '{print $10}')
  port_hex=${la#*:}
  port_hex=$(echo "$port_hex" | tr 'a-f' 'A-F')
  [ "$port_hex" = "$hex" ] || continue
  [ "$st" = "0A" ] || continue
  [ -n "$inode" ] || continue
  inodes="$inodes $inode"
done < /proc/net/tcp 2>/dev/null

for inode in $inodes; do
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    ls -l "$p/fd" 2>/dev/null | grep -q "socket:\[$inode\]" || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"sshd: root@"*|*"sshd: "*@*)
        kill -9 "$pid" 2>/dev/null || true
        ;;
    esac
  done
done
REMOTE_FREE_PORT
}

cleanup_local_reverse_proxy_orphans() {
  local alias="$1"
  local local_port="$2"
  local remote_port="$3"
  local control_path="$4"
  local reverse_spec="-R 127.0.0.1:${remote_port}:127.0.0.1:${local_port}"
  local compact_reverse_spec="-R127.0.0.1:${remote_port}:127.0.0.1:${local_port}"
  local pid
  local command
  local killed=0

  while IFS= read -r line; do
    pid="${line%% *}"
    command="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$command" == *"ssh -fN"* ]] || continue
    [[ "$command" == *" $alias" ]] || continue
    if [[ "$command" == *"$control_path"* ||
      "$command" == *"$reverse_spec"* ||
      "$command" == *"$compact_reverse_spec"* ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      killed=$((killed + 1))
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)

  if [[ "$killed" -gt 0 ]]; then
    sleep 1
  fi

  return 0
}

write_reverse_proxy_watchdog_runner() {
  local alias="$1"
  local local_port="$2"
  local remote_port="$3"
  local control_path="$4"
  local pid_path="$5"
  local log_path="$6"
  local runner_path="$7"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set +u\n'
    printf 'CODEX_AUTODL_ALIAS=%s\n' "$(shell_quote "$alias")"
    printf 'CODEX_AUTODL_LOCAL_PORT=%s\n' "$(shell_quote "$local_port")"
    printf 'CODEX_AUTODL_REMOTE_PORT=%s\n' "$(shell_quote "$remote_port")"
    printf 'CODEX_AUTODL_CONTROL_PATH=%s\n' "$(shell_quote "$control_path")"
    printf 'CODEX_AUTODL_PID_PATH=%s\n' "$(shell_quote "$pid_path")"
    printf 'CODEX_AUTODL_LOG_PATH=%s\n' "$(shell_quote "$log_path")"
    printf 'CODEX_AUTODL_ALIVE_INTERVAL=%s\n' "$(shell_quote "$SSH_ALIVE_INTERVAL")"
    printf 'CODEX_AUTODL_ALIVE_COUNT_MAX=%s\n' "$(shell_quote "$SSH_ALIVE_COUNT_MAX")"
    printf 'CODEX_AUTODL_CONNECT_TIMEOUT=%s\n' "$(shell_quote "$SSH_CONNECT_TIMEOUT")"
    printf 'CODEX_AUTODL_CHECK_INTERVAL=%s\n' "$(shell_quote "$TUNNEL_CHECK_INTERVAL")"
    printf 'CODEX_AUTODL_RETRY_INTERVAL=%s\n' "$(shell_quote "$TUNNEL_RETRY_INTERVAL")"
    printf 'CODEX_AUTODL_RETRY_MAX_INTERVAL=%s\n' "$(shell_quote "$TUNNEL_RETRY_MAX_INTERVAL")"
    cat <<'WATCHDOG_RUNNER'

mkdir -p "$(dirname "$CODEX_AUTODL_PID_PATH")" "$(dirname "$CODEX_AUTODL_LOG_PATH")"
printf '%s\n' "$$" > "$CODEX_AUTODL_PID_PATH"
retry_interval="$CODEX_AUTODL_RETRY_INTERVAL"

log() {
  printf "%s %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$*" >>"$CODEX_AUTODL_LOG_PATH"
}

cleanup_pid() {
  rm -f "$CODEX_AUTODL_PID_PATH"
}

trap 'cleanup_pid; exit 0' HUP INT TERM
trap cleanup_pid EXIT

cleanup_local_orphans() {
  local reverse_spec="-R 127.0.0.1:${CODEX_AUTODL_REMOTE_PORT}:127.0.0.1:${CODEX_AUTODL_LOCAL_PORT}"
  local compact_reverse_spec="-R127.0.0.1:${CODEX_AUTODL_REMOTE_PORT}:127.0.0.1:${CODEX_AUTODL_LOCAL_PORT}"
  local line pid command killed=0

  while IFS= read -r line; do
    pid="${line%% *}"
    command="${line#* }"
    [ -n "$pid" ] || continue
    case "$command" in
      *"ssh -fN"*"$CODEX_AUTODL_ALIAS")
        case "$command" in
          *"$CODEX_AUTODL_CONTROL_PATH"*|*"$reverse_spec"*|*"$compact_reverse_spec"*)
            kill "$pid" >/dev/null 2>&1 || true
            killed=$((killed + 1))
            ;;
        esac
        ;;
    esac
  done <<EOF
$(ps -axo pid=,command= 2>/dev/null || true)
EOF

  if [ "$killed" -gt 0 ]; then
    log "removed $killed local orphan reverse tunnel process(es)"
    sleep 1
  fi
}

remote_port_open() {
  ssh -S "$CODEX_AUTODL_CONTROL_PATH" \
    -o BatchMode=yes \
    -o "ServerAliveInterval=$CODEX_AUTODL_ALIVE_INTERVAL" \
    -o ServerAliveCountMax=2 \
    "$CODEX_AUTODL_ALIAS" \
    "port=$CODEX_AUTODL_REMOTE_PORT; if command -v nc >/dev/null 2>&1; then nc -z -w 3 127.0.0.1 \"\$port\"; elif command -v bash >/dev/null 2>&1; then bash -lc \":</dev/tcp/127.0.0.1/\$port\"; else exit 127; fi" \
    >/dev/null 2>&1
}

while :; do
  if ssh -S "$CODEX_AUTODL_CONTROL_PATH" -O check "$CODEX_AUTODL_ALIAS" >/dev/null 2>&1; then
    if remote_port_open; then
      retry_interval="$CODEX_AUTODL_RETRY_INTERVAL"
      sleep "$CODEX_AUTODL_CHECK_INTERVAL"
      continue
    fi
    log "control master alive but remote port closed; restarting tunnel"
    ssh -S "$CODEX_AUTODL_CONTROL_PATH" -O exit "$CODEX_AUTODL_ALIAS" >/dev/null 2>&1 || true
    sleep 1
  fi

  cleanup_local_orphans
  # free remote reverse port if stale sshd still holds it
  ssh -o BatchMode=yes -o ConnectTimeout="$CODEX_AUTODL_CONNECT_TIMEOUT" \
    -o "ServerAliveInterval=$CODEX_AUTODL_ALIVE_INTERVAL" \
    -o ServerAliveCountMax=2 \
    "$CODEX_AUTODL_ALIAS" "port=$CODEX_AUTODL_REMOTE_PORT; sh -s" <<'FREEPORT' >/dev/null 2>&1 || true
set +e
case "$port" in ''|*[!0-9]*) exit 0 ;; esac
hex=$(printf '%04X' "$port" 2>/dev/null || true)
[ -n "$hex" ] || exit 0
inodes=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in sl*) continue ;; esac
  la=$(echo "$line" | awk '{print $2}')
  st=$(echo "$line" | awk '{print $4}')
  inode=$(echo "$line" | awk '{print $10}')
  port_hex=${la#*:}
  port_hex=$(echo "$port_hex" | tr 'a-f' 'A-F')
  [ "$port_hex" = "$hex" ] || continue
  [ "$st" = "0A" ] || continue
  [ -n "$inode" ] || continue
  inodes="$inodes $inode"
done < /proc/net/tcp 2>/dev/null
for inode in $inodes; do
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    ls -l "$p/fd" 2>/dev/null | grep -q "socket:\[$inode\]" || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"sshd: root@"*|*"sshd: "*@*) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done
done
FREEPORT
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
    retry_interval="$CODEX_AUTODL_RETRY_INTERVAL"
  else
    rc=$?
    log "reverse tunnel start failed rc=$rc"
    log "retrying in ${retry_interval}s"
    sleep "$retry_interval"
    retry_interval=$((retry_interval * 2))
    if [ "$retry_interval" -gt "$CODEX_AUTODL_RETRY_MAX_INTERVAL" ]; then
      retry_interval="$CODEX_AUTODL_RETRY_MAX_INTERVAL"
    fi
  fi
done
WATCHDOG_RUNNER
  } >"$runner_path"
  chmod 0755 "$runner_path"
}

stop_reverse_proxy_launchd() {
  local alias="$1"
  local remote_port="$2"
  local label
  local plist_path
  local runner_path
  local domain=""

  label="$(proxy_tunnel_launchd_label "$alias" "$remote_port")"
  plist_path="$(proxy_tunnel_launchd_plist_path "$alias" "$remote_port")"
  runner_path="$(proxy_tunnel_watchdog_runner_path "$alias" "$remote_port")"

  if command -v launchctl >/dev/null 2>&1; then
    domain="gui/$(id -u)"
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
    launchctl unload -w "$plist_path" >/dev/null 2>&1 || true
  fi

  rm -f "$plist_path" "$runner_path"
}

start_reverse_proxy_watchdog() {
  local alias="$1"
  local local_port="$2"
  local remote_port="$3"
  local control_path="$4"
  local pid_path="$5"
  local log_path="$6"
  local runner_path
  local plist_path
  local label
  local domain
  local pid=""
  local i

  [[ "$(uname -s)" == "Darwin" ]] || die "macOS launchd is required for supervised reverse tunnels"
  require_cmd launchctl

  runner_path="$(proxy_tunnel_watchdog_runner_path "$alias" "$remote_port")"
  plist_path="$(proxy_tunnel_launchd_plist_path "$alias" "$remote_port")"
  label="$(proxy_tunnel_launchd_label "$alias" "$remote_port")"
  domain="gui/$(id -u)"

  mkdir -p "$HOME/.ssh" "$HOME/Library/LaunchAgents"
  stop_reverse_proxy_launchd "$alias" "$remote_port"
  write_reverse_proxy_watchdog_runner "$alias" "$local_port" "$remote_port" "$control_path" "$pid_path" "$log_path" "$runner_path"
  cat >"$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$runner_path")</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$HOME")</string>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$log_path")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$log_path")</string>
</dict>
</plist>
PLIST

  if ! launchctl bootstrap "$domain" "$plist_path" >/dev/null 2>&1; then
    launchctl load -w "$plist_path" >/dev/null 2>&1 || return 1
  fi
  launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 || true

  for ((i = 1; i <= 20; i++)); do
    pid="$(cat "$pid_path" 2>/dev/null || true)"
    if pid_is_running "$pid"; then
      return 0
    fi
    sleep 0.25
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
  local plist_path
  local existing_pid=""
  local mapping_changed=0

  control_path="$(proxy_tunnel_control_path "$alias" "$remote_port")"
  pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$remote_port")"
  log_path="$(proxy_tunnel_log_path "$alias" "$remote_port")"
  plist_path="$(proxy_tunnel_launchd_plist_path "$alias" "$remote_port")"
  mkdir -p "$HOME/.ssh"

  # 每个 SSH alias 只保留当前端口的一条受管隧道。旧端口 watchdog 会持续
  # 抢占 SSH 会话，拖慢 Desktop 的 1 秒模型能力探针，最终让模型菜单变灰。
  cleanup_obsolete_reverse_proxy_tunnels "$alias" "$remote_port"
  cleanup_stale_ssh_control_socket "$alias"
  rotate_tunnel_log_if_needed "$log_path"

  if [[ -f "$pid_path" ]]; then
    existing_pid="$(cat "$pid_path" 2>/dev/null || true)"
    if pid_is_running "$existing_pid" &&
      [[ -f "$plist_path" ]] &&
      reverse_proxy_watchdog_matches "$alias" "$local_port" "$remote_port"; then
      echo "SSH reverse proxy tunnel watchdog is already running (pid $existing_pid)."
      if wait_for_reverse_proxy_tunnel "$alias" "$remote_port" "$control_path"; then
        echo "SSH reverse proxy tunnel is healthy: remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
        return 0
      fi

      echo "Existing tunnel watchdog did not recover the tunnel; restarting watchdog..."
      sleep 1
    elif pid_is_running "$existing_pid" && [[ -f "$plist_path" ]]; then
      echo "Tunnel port mapping changed; restarting watchdog..."
      mapping_changed=1
    fi
    stop_reverse_proxy_launchd "$alias" "$remote_port"
    pid_is_running "$existing_pid" && kill "$existing_pid" >/dev/null 2>&1 || true
    rm -f "$pid_path"
  fi

  if [[ "$mapping_changed" -eq 1 ]]; then
    ssh -S "$control_path" -O exit "$alias" >/dev/null 2>&1 || true
    rm -f "$control_path"
  fi

  if ssh -S "$control_path" -O check "$alias" >/dev/null 2>&1; then
    echo "SSH reverse proxy tunnel is already running; adding watchdog supervision:"
  else
    cleanup_local_reverse_proxy_orphans "$alias" "$local_port" "$remote_port" "$control_path"
    rm -f "$control_path"
    echo "Starting supervised SSH reverse proxy tunnel:"
  fi

  if [[ "$mapping_changed" -ne 1 ]]; then
    free_remote_reverse_port "$alias" "$remote_port"
  fi
  echo "  remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
  echo "  watchdog log: $log_path"
  echo "  launchd plist: $plist_path"

  start_reverse_proxy_watchdog "$alias" "$local_port" "$remote_port" "$control_path" "$pid_path" "$log_path" ||
    die "failed to start launchd watchdog: $plist_path"

  if wait_for_reverse_proxy_tunnel "$alias" "$remote_port" "$control_path"; then
    echo "SSH reverse proxy tunnel is healthy: remote 127.0.0.1:$remote_port -> local 127.0.0.1:$local_port"
  else
    echo "Warning: tunnel watchdog started, but the tunnel is not healthy yet. Check: tail -f $log_path" >&2
  fi
}

reverse_proxy_watchdog_matches() {
  local alias="$1"
  local local_port="$2"
  local remote_port="$3"
  local runner_path

  runner_path="$(proxy_tunnel_watchdog_runner_path "$alias" "$remote_port")"
  [[ -f "$runner_path" ]] || return 1
  grep -Fqx "CODEX_AUTODL_ALIAS=$(shell_quote "$alias")" "$runner_path" &&
    grep -Fqx "CODEX_AUTODL_LOCAL_PORT=$(shell_quote "$local_port")" "$runner_path" &&
    grep -Fqx "CODEX_AUTODL_REMOTE_PORT=$(shell_quote "$remote_port")" "$runner_path"
}

stop_reverse_proxy_tunnel() {
  local alias="$1"
  local remote_port="$2"
  local control_path
  local pid_path
  local existing_pid=""

  control_path="$(proxy_tunnel_control_path "$alias" "$remote_port")"
  pid_path="$(proxy_tunnel_watchdog_pid_path "$alias" "$remote_port")"

  stop_reverse_proxy_launchd "$alias" "$remote_port"

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

managed_reverse_proxy_ports() {
  local alias="$1"
  local artifact
  local name
  local prefix="codex2autodl-${alias}-proxy-"
  local suffix
  local port

  for artifact in \
    "$HOME/Library/LaunchAgents/${prefix}"*.plist \
    "$HOME/.ssh/${prefix}"*; do
    [[ -e "$artifact" ]] || continue
    name="${artifact##*/}"
    [[ "$name" == "$prefix"* ]] || continue
    suffix="${name#"$prefix"}"
    port="${suffix%%.*}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    printf '%s\n' "$port"
  done | awk '!seen[$0]++'
}

cleanup_obsolete_reverse_proxy_tunnels() {
  local alias="$1"
  local keep_remote_port="$2"
  local obsolete_port
  local artifact

  while IFS= read -r obsolete_port; do
    [[ -n "$obsolete_port" && "$obsolete_port" != "$keep_remote_port" ]] || continue
    echo "Removing obsolete managed tunnel for $alias on remote port $obsolete_port..."
    stop_reverse_proxy_tunnel "$alias" "$obsolete_port"
    for artifact in "$HOME/.ssh/codex2autodl-${alias}-proxy-${obsolete_port}".*; do
      [[ -e "$artifact" ]] || continue
      rm -f "$artifact"
    done
  done < <(managed_reverse_proxy_ports "$alias")
}

remove_alias_tunnel_artifacts() {
  local alias
  local artifact

  for alias in "$@"; do
    [[ -n "$alias" ]] || continue
    for artifact in "$HOME/.ssh"/codex2autodl-"$alias"-proxy-*; do
      [[ -e "$artifact" ]] || continue
      rm -f "$artifact"
    done
  done
}

replace_existing_aliases_for_target() {
  local target_user="$1"
  local target_host="$2"
  local target_port="$3"
  local new_alias="$4"
  local old_alias
  local old_alias_list
  local old_aliases=()

  old_alias_list="$(list_codex2autodl_aliases_for_target "$target_user" "$target_host" "$target_port" "$new_alias")" ||
    die "failed to scan SSH config for existing aliases"

  while IFS= read -r old_alias; do
    [[ -n "$old_alias" ]] || continue
    old_aliases+=("$old_alias")
  done <<< "$old_alias_list"

  [[ "${#old_aliases[@]}" -gt 0 ]] || return 0

  echo "Found existing codex2autodl alias(es) for this SSH target; replacing them with: $new_alias"
  for old_alias in "${old_aliases[@]}"; do
    echo "  removing old alias: $old_alias"
    stop_reverse_proxy_tunnel "$old_alias" "$REMOTE_API_PORT"
    if [[ "$REMOTE_PROXY_PORT" != "$REMOTE_API_PORT" ]]; then
      stop_reverse_proxy_tunnel "$old_alias" "$REMOTE_PROXY_PORT"
    fi
  done

  remove_ssh_aliases_from_config "${old_aliases[@]}"
  remove_alias_tunnel_artifacts "${old_aliases[@]}"
}

configure_remote_proxy() {
  local alias="$1"
  local proxy_url="$2"
  local clear_proxy="$3"

  if [[ "$clear_proxy" -eq 1 ]]; then
    if ssh "$alias" 'sh -s' <<'REMOTE_PROXY_CLEAR_CHECK'
set -eu
codex_home="${CODEX_HOME:-$HOME/.codex}"
[ ! -e "$codex_home/codex2autodl-env" ] || exit 1
wrapper="$HOME/.local/bin/codex"
if [ -f "$wrapper" ] && grep -F "codex2autodl wrapper" "$wrapper" >/dev/null 2>&1; then
  exit 1
fi
for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.zprofile" "$HOME/.zshrc"; do
  [ -f "$profile" ] || continue
  if grep -F "# >>> codex2autodl proxy >>>" "$profile" >/dev/null 2>&1; then
    exit 1
  fi
done
REMOTE_PROXY_CLEAR_CHECK
    then
      echo "Remote proxy environment already clear; rewrite and restart skipped."
      return 0
    fi
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
  rm -f "$HOME/.codex/codex2autodl-env"
  echo "Remote proxy env block cleared."
else
  write_proxy_env_file
  echo "Remote proxy env block written."
fi
REMOTE_PROXY_CONFIG

  refresh_remote_codex_wrapper "$alias"
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
  local remote_model="$MODEL"
  local prepared_catalog=""
  local catalog_digest=""
  local catalog_changed=0

  [[ "$provider_name" =~ ^[A-Za-z0-9_-]+$ ]] || die "API provider name can only contain letters, numbers, underscore, and dash"

  local remote_catalog_path=""
  if [[ "$clear_provider" -eq 1 ]]; then
    echo "Clearing remote API provider '$provider_name' from Codex config..."
  else
    [[ -n "$base_url" ]] || die "--api-base-url cannot be empty"
    [[ "$base_url" != *$'\n'* ]] || die "--api-base-url cannot contain newlines"
    echo "Writing remote API provider '$provider_name': $base_url"
    if [[ -n "$MODEL_CATALOG_FILE" ]]; then
      [[ -f "$MODEL_CATALOG_FILE" ]] || die "model catalog file not found: $MODEL_CATALOG_FILE"
      remote_catalog_path="1"
      prepared_catalog="$(mktemp "${TMPDIR:-/tmp}/codex2autodl-remote-catalog.XXXXXX")"
      if [[ "$provider_name" == "claude-code-router" ]]; then
        # Desktop whitelist prefers bare OpenAI model names.
        # Infer CCR namespace prefixes from the current local catalog; do not hardcode.
        if ! command -v python3 >/dev/null 2>&1; then
          die "python3 is required on Mac to prepare remote CCR model catalog"
        fi
        MODEL_CATALOG_FILE="$MODEL_CATALOG_FILE" CODEX_AUTODL_MODEL="$remote_model" \
          python3 - "$prepared_catalog" <<'PY'
import json, os, re, sys
src = os.environ["MODEL_CATALOG_FILE"]
dst = sys.argv[1]
default_model = os.environ.get("CODEX_AUTODL_MODEL", "") or ""
openaiish = re.compile(r"^(gpt-|o[0-9]|chatgpt-|codex-|dall-e|gpt-image|text-embedding|omni-)")
data = json.load(open(src, encoding="utf-8"))
prefixes = set()
if "/" in default_model:
    prefixes.add(default_model.split("/", 1)[0] + "/")
for item in data.get("models") or []:
    slug = str((item or {}).get("slug") or (item or {}).get("id") or "")
    if "/" not in slug:
        continue
    ns, rest = slug.split("/", 1)
    if openaiish.match(rest) or (default_model and default_model.startswith(ns + "/")):
        prefixes.add(ns + "/")
prefixes = sorted(prefixes, key=len, reverse=True)

def strip_text(value):
    for prefix in prefixes:
        if value.startswith(prefix):
            return value[len(prefix):]
    return value

def walk(node):
    if isinstance(node, dict):
        return {k: walk(v) for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v) for v in node]
    if isinstance(node, str):
        return strip_text(node)
    return node

prepared = walk(data)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(prepared, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("CCR remote catalog strip prefixes: " + (" ".join(prefixes) if prefixes else "(none)"))
if default_model:
    stripped = strip_text(default_model)
    if stripped != default_model:
        print("CCR remote default model: " + stripped)
        with open(dst + ".model", "w", encoding="utf-8") as f:
            f.write(stripped)
PY
        if [[ -f "$prepared_catalog.model" ]]; then
          remote_model="$(cat "$prepared_catalog.model")"
          rm -f "$prepared_catalog.model"
        fi
      else
        cat "$MODEL_CATALOG_FILE" > "$prepared_catalog"
      fi
      catalog_digest="$(portable_sha256 "$prepared_catalog")"
      if ssh "$alias" "CODEX_AUTODL_CATALOG_DIGEST=$(shell_quote "$catalog_digest") sh -s" <<'REMOTE_CHECK_MODEL_CATALOG'
set -eu
catalog="$HOME/.codex/codex2autodl-model-catalog.json"
[ -f "$catalog" ] || exit 1
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$catalog" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  digest="$(shasum -a 256 "$catalog" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  digest="$(openssl dgst -sha256 "$catalog" | sed 's/^.*= //')"
else
  exit 1
fi
[ "$digest" = "$CODEX_AUTODL_CATALOG_DIGEST" ]
REMOTE_CHECK_MODEL_CATALOG
      then
        echo "Remote model catalog already current; upload skipped."
      else
        echo "Remote model catalog differs; uploading: $MODEL_CATALOG_FILE"
        ssh "$alias" 'mkdir -p "$HOME/.codex" && umask 077 && cat > "$HOME/.codex/codex2autodl-model-catalog.json"' < "$prepared_catalog"
        catalog_changed=1
      fi
    fi
  fi

  if [[ "$provider_name" == "claude-code-router" && -z "${MODEL_CATALOG_FILE:-}" && "$remote_model" == */* ]]; then
    # No catalog provided: strip one namespace from the current default model name.
    remote_model="${remote_model#*/}"
  fi

  if [[ "$clear_provider" -ne 1 ]] &&
    ssh "$alias" \
      "CODEX_AUTODL_API_PROVIDER_NAME=$(shell_quote "$provider_name") CODEX_AUTODL_API_BASE_URL=$(shell_quote "$base_url") CODEX_AUTODL_WIRE_API=$(shell_quote "$WIRE_API") CODEX_AUTODL_MODEL=$(shell_quote "$remote_model") CODEX_AUTODL_HAS_CATALOG=$(shell_quote "$remote_catalog_path") sh -s" <<'REMOTE_CHECK_API_PROVIDER_CONFIG'
set -eu
config_file="$HOME/.codex/config.toml"
provider="$CODEX_AUTODL_API_PROVIDER_NAME"
[ -f "$config_file" ] || exit 1

current_provider="$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
current_model="$(sed -n 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
current_catalog="$(sed -n 's/^[[:space:]]*model_catalog_json[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1)"
provider_values="$(
  awk -v provider="$provider" '
    $0 == "[model_providers." provider "]" { in_provider = 1; next }
    in_provider == 1 && /^\[/ { exit }
    in_provider == 1 {
      if ($1 == "base_url") {
        line = $0
        sub(/^[^=]*=[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        base_url = line
      } else if ($1 == "wire_api") {
        line = $0
        sub(/^[^=]*=[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        wire_api = line
      } else if ($1 == "requires_openai_auth") {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        auth = line
      }
    }
    END {
      print base_url
      print wire_api
      print auth
    }
  ' "$config_file"
)"
current_base_url="$(printf '%s\n' "$provider_values" | sed -n '1p')"
current_wire_api="$(printf '%s\n' "$provider_values" | sed -n '2p')"
current_auth="$(printf '%s\n' "$provider_values" | sed -n '3p')"
expected_catalog=""
if [ "$CODEX_AUTODL_HAS_CATALOG" = "1" ]; then
  expected_catalog="$HOME/.codex/codex2autodl-model-catalog.json"
fi

[ "$current_provider" = "$provider" ] &&
  [ "$current_model" = "$CODEX_AUTODL_MODEL" ] &&
  [ "$current_catalog" = "$expected_catalog" ] &&
  [ "$current_base_url" = "$CODEX_AUTODL_API_BASE_URL" ] &&
  [ "$current_wire_api" = "$CODEX_AUTODL_WIRE_API" ] &&
  [ "$current_auth" = "true" ] &&
  [ ! -e "$HOME/.codex/codex2autodl-model-proxy.pl" ] &&
  [ ! -e "$HOME/.codex/codex2autodl-model-proxy-start" ] &&
  [ ! -e "$HOME/.codex/codex2autodl-model-proxy.pid" ]
REMOTE_CHECK_API_PROVIDER_CONFIG
  then
    if [[ "$catalog_changed" -eq 0 ]]; then
      echo "Remote model/provider config already current; rewrite and restart skipped."
      [[ -n "$prepared_catalog" ]] && rm -f "$prepared_catalog" "$prepared_catalog.model"
      return 0
    fi

    echo "Remote provider config is current; restarting only because the model catalog changed."
    [[ -n "$prepared_catalog" ]] && rm -f "$prepared_catalog" "$prepared_catalog.model"
    refresh_remote_codex_wrapper "$alias"
    restart_remote_codex_app_server "$alias"
    return 0
  fi

  ssh "$alias" \
    "CODEX_AUTODL_API_PROVIDER_NAME=$(shell_quote "$provider_name") CODEX_AUTODL_API_BASE_URL=$(shell_quote "$base_url") CODEX_AUTODL_CLEAR_API_PROVIDER='$clear_provider' CODEX_AUTODL_WIRE_API=$(shell_quote "$WIRE_API") CODEX_AUTODL_MODEL=$(shell_quote "$remote_model") CODEX_AUTODL_HAS_CATALOG=$(shell_quote "$remote_catalog_path") sh -s" <<'REMOTE_API_PROVIDER_CONFIG'
set -eu

config_dir="$HOME/.codex"
config_file="$config_dir/config.toml"
provider="$CODEX_AUTODL_API_PROVIDER_NAME"
mkdir -p "$config_dir"

# 清理曾经试验过的远端模型前置代理，恢复 provider 直接走 SSH 反向隧道。
legacy_proxy_pid="$config_dir/codex2autodl-model-proxy.pid"
if [ -f "$legacy_proxy_pid" ]; then
  pid="$(cat "$legacy_proxy_pid" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      ;;
  esac
fi
rm -f "$config_dir/codex2autodl-model-proxy.pl" \
      "$config_dir/codex2autodl-model-proxy-start" \
      "$config_dir/codex2autodl-model-proxy.pid" \
      "$config_dir/codex2autodl-model-proxy.log"

touch "$config_file"
chmod 0600 "$config_file" 2>/dev/null || true
catalog_path=""
if [ "${CODEX_AUTODL_HAS_CATALOG:-}" = "1" ]; then
  catalog_path="$config_dir/codex2autodl-model-catalog.json"
fi

tmp="$config_file.codex2autodl.$$"
awk -v provider="$provider" '
  BEGIN { skip = 0 }
  /^[[:space:]]*model[[:space:]]*=/ { next }
  /^[[:space:]]*model_catalog_json[[:space:]]*=/ { next }
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
  wire_api="${CODEX_AUTODL_WIRE_API:-responses}"
  {
    printf '\nmodel_provider = "%s"\n' "$provider"
    if [ -n "$CODEX_AUTODL_MODEL" ]; then
      printf 'model = "%s"\n' "$CODEX_AUTODL_MODEL"
    fi
    if [ -n "$catalog_path" ]; then
      printf 'model_catalog_json = "%s"\n' "$catalog_path"
    fi
    cat "$config_file"
    printf '\n[model_providers.%s]\n' "$provider"
    printf 'name = "%s"\n' "$provider"
    printf 'base_url = "%s"\n' "$CODEX_AUTODL_API_BASE_URL"
    printf 'wire_api = "%s"\n' "$wire_api"
    printf 'requires_openai_auth = true\n'
  } > "$tmp"
  cat "$tmp" > "$config_file"
  rm -f "$tmp"
  echo "Remote API provider written."
else
  echo "Remote API provider cleared."
fi
REMOTE_API_PROVIDER_CONFIG

  [[ -n "$prepared_catalog" ]] && rm -f "$prepared_catalog" "$prepared_catalog.model"
  refresh_remote_codex_wrapper "$alias"
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
QUICK_RECONNECT=0
QUICK_RECONNECT_ACTIVE=0
LOCAL_API_SPEC=""
LOCAL_API_PORT=""
REMOTE_API_PORT=""
API_SCHEME="http"
OPENAI_BASE_URL=""
CLEAR_OPENAI_BASE_URL=0
API_PROVIDER_NAME="codex2api"
API_PROVIDER_BASE_URL=""
CLEAR_API_PROVIDER=0
WIRE_API="responses"
MODEL=""
MODEL_CATALOG_FILE=""
API_KEY_PROMPT=0
API_KEY_ENV_NAME=""
API_KEY_FILE=""
COPY_LOCAL_AUTH=0
SYNC_LOCAL_SKILLS=1
SYNC_LOCAL_PLUGINS=1
REMOTE_CODEX_UPDATED=0
REMOTE_APP_SERVER_RESTARTED=0
ACTIVE_ALIAS_PORT_SPECS=()
SSH_ALIVE_INTERVAL=15
SSH_ALIVE_COUNT_MAX=8
SSH_CONNECT_TIMEOUT=15
SSH_CONTROL_PERSIST=10m
TUNNEL_CHECK_INTERVAL=15
TUNNEL_RETRY_INTERVAL=10
TUNNEL_RETRY_MAX_INTERVAL=120
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
    --wire-api)
      [[ $# -ge 2 ]] || die "--wire-api requires a value"
      WIRE_API="$2"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value"
      MODEL="$2"
      shift 2
      ;;
    --model-catalog-file)
      [[ $# -ge 2 ]] || die "--model-catalog-file requires a file path"
      MODEL_CATALOG_FILE="$2"
      [[ "$MODEL_CATALOG_FILE" == "~/"* ]] && MODEL_CATALOG_FILE="$HOME/${MODEL_CATALOG_FILE#\~/}"
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
    --quick-reconnect)
      QUICK_RECONNECT=1
      shift
      ;;
    --quick-reconnect-active)
      QUICK_RECONNECT_ACTIVE=1
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
    --skip-local-skills)
      SYNC_LOCAL_SKILLS=0
      shift
      ;;
    --skip-local-plugins)
      SYNC_LOCAL_PLUGINS=0
      shift
      ;;
    --active-alias-port)
      [[ $# -ge 2 ]] || die "--active-alias-port requires ALIAS=LOCAL[:REMOTE]"
      ACTIVE_ALIAS_PORT_SPECS+=("$2")
      shift 2
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

[[ "$ALIAS" =~ ^[A-Za-z0-9._-]+$ && "$ALIAS" != -* ]] || die "alias can only contain letters, numbers, dot, underscore, and dash, and cannot start with dash"
if [[ "$QUICK_RECONNECT" -eq 1 && ${#ARGS[@]} -gt 0 ]]; then
  die "--quick-reconnect works with an existing SSH alias; do not pass a new SSH command"
fi
if [[ "$QUICK_RECONNECT_ACTIVE" -eq 1 && ${#ARGS[@]} -gt 0 ]]; then
  die "--quick-reconnect-active repairs existing active SSH aliases; do not pass a new SSH command"
fi
if [[ "$QUICK_RECONNECT" -eq 1 && "$QUICK_RECONNECT_ACTIVE" -eq 1 ]]; then
  die "use only one of --quick-reconnect or --quick-reconnect-active"
fi
if (( ${#ACTIVE_ALIAS_PORT_SPECS[@]} > 0 )); then
  for active_alias_port in "${ACTIVE_ALIAS_PORT_SPECS[@]}"; do
    [[ "$active_alias_port" == *=* ]] || die "invalid --active-alias-port value: $active_alias_port"
    active_alias_name="${active_alias_port%%=*}"
    active_port_spec="${active_alias_port#*=}"
    [[ "$active_alias_name" =~ ^[A-Za-z0-9._-]+$ && "$active_alias_name" != -* ]] ||
      die "invalid alias in --active-alias-port: $active_alias_name"
    if [[ "$active_port_spec" == *:* ]]; then
      active_local_port="${active_port_spec%%:*}"
      active_remote_port="${active_port_spec#*:}"
    else
      active_local_port="$active_port_spec"
      active_remote_port="$active_port_spec"
    fi
    [[ "$active_local_port" =~ ^[0-9]+$ ]] ||
      die "invalid local port in --active-alias-port: $active_alias_port"
    [[ "$active_remote_port" =~ ^[0-9]+$ ]] ||
      die "invalid remote port in --active-alias-port: $active_alias_port"
  done
fi
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

case "$WIRE_API" in
  responses|chat) ;;
  *) die "--wire-api must be one of: responses, chat" ;;
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
  if [[ "$STOP_API_TUNNEL" -eq 0 ]]; then
    API_PROVIDER_BASE_URL="$API_SCHEME://127.0.0.1:$REMOTE_API_PORT/v1"
  fi
  if [[ -z "$REMOTE_PROXY_URL" && "$STOP_API_TUNNEL" -eq 0 ]]; then
    CLEAR_REMOTE_PROXY=1
  fi
fi

if [[ -z "$REMOTE_API_PORT" ]]; then
  REMOTE_API_PORT="8080"
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
  if [[ "$QUICK_RECONNECT_ACTIVE" -eq 1 ]]; then
    require_cmd ssh
    if [[ -z "$LOCAL_API_PORT" ]]; then
      LOCAL_API_PORT="$REMOTE_API_PORT"
    fi
    active_aliases=()
    while IFS= read -r active_alias; do
      [[ -n "$active_alias" ]] || continue
      [[ "$active_alias" =~ ^[A-Za-z0-9._-]+$ && "$active_alias" != -* ]] || continue
      ssh_alias_configured "$active_alias" || continue
      active_aliases+=("$active_alias")
    done < <(active_codex_remote_aliases)

    if [[ "${#active_aliases[@]}" -eq 0 ]]; then
      echo "No active Codex remote SSH aliases found."
      exit 0
    fi

    echo "Quick reconnect active API tunnel(s): ${active_aliases[*]}"
    for active_alias in "${active_aliases[@]}"; do
      active_local_port="$LOCAL_API_PORT"
      active_remote_port="$REMOTE_API_PORT"
      if active_port_spec="$(active_alias_port_spec "$active_alias")"; then
        if [[ "$active_port_spec" == *:* ]]; then
          active_local_port="${active_port_spec%%:*}"
          active_remote_port="${active_port_spec#*:}"
        else
          active_local_port="$active_port_spec"
          active_remote_port="$active_port_spec"
        fi
      fi
      echo
      echo "== repairing active alias: $active_alias ($active_local_port:$active_remote_port)"
      ensure_ssh_reliability_override "$active_alias"
      start_reverse_proxy_tunnel "$active_alias" "$active_local_port" "$active_remote_port"
    done

    if [[ "$RUN_DIAGNOSE" -eq 1 ]]; then
      for active_alias in "${active_aliases[@]}"; do
        run_local_diagnostics "$active_alias"
      done
    fi
    exit 0
  fi

  ensure_ssh_reliability_override "$ALIAS"

  if [[ "$QUICK_RECONNECT" -eq 1 ]]; then
    require_cmd ssh
    if [[ -z "$LOCAL_API_PORT" ]]; then
      LOCAL_API_PORT="$REMOTE_API_PORT"
    fi
    echo "Quick reconnect: repairing API tunnel only."
    start_reverse_proxy_tunnel "$ALIAS" "$LOCAL_API_PORT" "$REMOTE_API_PORT"
    if [[ "$RUN_DIAGNOSE" -eq 1 ]]; then
      run_local_diagnostics "$ALIAS"
    fi
    exit 0
  fi

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

  if [[ "$SYNC_LOCAL_SKILLS" -eq 1 && -n "$LOCAL_API_SPEC" && "$STOP_API_TUNNEL" -eq 0 ]]; then
    require_cmd ssh
    sync_local_skills_to_remote "$ALIAS"
  fi
  if [[ "$SYNC_LOCAL_PLUGINS" -eq 1 && -n "$LOCAL_API_SPEC" && "$STOP_API_TUNNEL" -eq 0 ]]; then
    require_cmd ssh
    sync_compatible_plugins_to_remote "$ALIAS"
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

replace_existing_aliases_for_target "$USER" "$HOST" "$PORT" "$ALIAS"

if ssh_alias_matches_target "$ALIAS" "$USER" "$HOST" "$PORT" "$KEY_FILE"; then
  echo "SSH alias config already current; rewrite and control-master reset skipped."
else
  echo "Writing SSH config: $CONFIG_FILE"
  touch "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  TMP_CONFIG="$(mktemp)"
  awk \
    -v alias="$ALIAS" \
    -v reliability_begin="# >>> codex2autodl ssh reliability: $ALIAS >>>" \
    -v reliability_end="# <<< codex2autodl ssh reliability: $ALIAS <<<" '
    function flush_pending_marker() {
      if (pending_marker != "") {
        print pending_marker
        pending_marker = ""
      }
    }
    $0 == reliability_begin { reliability_skip = 1; next }
    $0 == reliability_end { reliability_skip = 0; next }
    reliability_skip == 1 { next }
    /^# Added by codex2autodl setup script$/ {
      pending_marker = $0
      next
    }
    $1 == "Host" {
      skip = 0
      for (i = 2; i <= NF; i++) {
        if ($i == alias) {
          skip = 1
        }
      }
      if (skip == 1) {
        pending_marker = ""
        next
      }
      flush_pending_marker()
      print
      next
    }
    skip != 1 {
      flush_pending_marker()
      print
    }
    END {
      flush_pending_marker()
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

  reset_ssh_control_master "$ALIAS"
fi

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

  desktop_codex_version="$(resolve_desktop_codex_version || true)"
  latest_resolution_failed=0
  if [[ -n "$desktop_codex_version" ]]; then
    latest_version="$desktop_codex_version"
  else
    latest_version="$(resolve_latest_codex_version || true)"
  fi

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

  if [[ -n "$desktop_codex_version" ]]; then
    echo "Desktop Codex version: $latest_version ($codex_target)"
  elif [[ "$latest_resolution_failed" -eq 0 ]]; then
    echo "Latest Codex release: $latest_version ($codex_target)"
  else
    echo "Selected Codex release: $latest_version ($codex_target)"
  fi

  if [[ "$remote_codex_version" == "$latest_version" && "$remote_current_login_shell_ok" -eq 1 ]]; then
    echo "Remote Codex matches desktop and is visible to login shell: $remote_codex_version"
  else
    if [[ -n "$remote_codex_version" ]]; then
      echo "Remote Codex version is $remote_codex_version; desktop requires $latest_version. Updating..."
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
  while [ "$attempt" -le 1 ]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fL --connect-timeout 20 --max-time 120 -o "$output" "$url"; then
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
    REMOTE_CODEX_UPDATED=1
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

if [[ "$SYNC_LOCAL_SKILLS" -eq 1 ]]; then
  sync_local_skills_to_remote "$ALIAS"
fi
if [[ "$SYNC_LOCAL_PLUGINS" -eq 1 ]]; then
  sync_compatible_plugins_to_remote "$ALIAS"
fi
if [[ "$REMOTE_CODEX_UPDATED" -eq 1 && "$REMOTE_APP_SERVER_RESTARTED" -eq 0 ]]; then
  echo "Remote Codex binary changed; restarting app-server once."
  restart_remote_codex_app_server "$ALIAS"
fi

echo
echo "Done. In Codex App, open Settings -> Connections and add/select SSH host:"
echo "  $ALIAS"

if [[ "$RUN_DIAGNOSE" -eq 1 ]]; then
  run_remote_diagnostics "$ALIAS"
fi
