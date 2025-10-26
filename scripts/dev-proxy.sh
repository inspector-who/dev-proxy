#!/usr/bin/env bash
set -euo pipefail

# Resolve repository root robustly, even if installed under /usr/local/bin as symlink or copy.
# Priority: DEV_PROXY_ROOT env var -> symlink/realpath detection -> heuristics relative to script dir -> PWD

# 1) If user explicitly sets DEV_PROXY_ROOT, honor it
if [[ -n "${DEV_PROXY_ROOT:-}" ]]; then
  ROOT_DIR="${DEV_PROXY_ROOT}"
else
  # 2) Try to resolve the actual script path (following symlinks when possible)
  _src="$0"
  if command -v greadlink >/dev/null 2>&1; then
    _src="$(greadlink -f "$_src" 2>/dev/null || echo "$_src")"
  elif command -v readlink >/dev/null 2>&1; then
    # On macOS, readlink may not support -f; resolve one level and rebuild absolute path
    _rl="$(readlink "$_src" 2>/dev/null || true)"
    if [[ -n "$_rl" ]]; then
      if [[ "$_rl" = /* ]]; then
        _src="$_rl"
      else
        _src="$(cd "$(dirname "$_src")" && cd "$(dirname "$_rl")" && pwd)/$(basename "$_rl")"
      fi
    fi
  elif command -v realpath >/dev/null 2>&1; then
    _src="$(realpath "$_src" 2>/dev/null || echo "$_src")"
  fi
  SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

  # 3) Candidate roots relative to SCRIPT_DIR and PWD
  if [[ -f "$SCRIPT_DIR/../docker-compose.yml" ]]; then
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  elif [[ -f "$SCRIPT_DIR/../../dev-proxy/docker-compose.yml" ]]; then
    ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && cd dev-proxy && pwd)"
  elif [[ -f "$PWD/docker-compose.yml" ]]; then
    ROOT_DIR="$PWD"
  elif [[ -f "$PWD/dev-proxy/docker-compose.yml" ]]; then
    ROOT_DIR="$(cd "$PWD/dev-proxy" && pwd)"
  else
    echo "Cannot locate dev-proxy/docker-compose.yml automatically." >&2
    echo "Please set DEV_PROXY_ROOT to your repo root, e.g.:" >&2
    echo "  export DEV_PROXY_ROOT=/path/to/dev-zoo" >&2
    exit 1
  fi
fi

COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
PROJECT_NAME="dev-proxy"

# Load .env if exists to get TRAEFIK_NETWORK and port vars
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ROOT_DIR/.env"
  set +a
elif [[ -f "$ROOT_DIR/.env.dist" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ROOT_DIR/.env.dist"
  set +a
fi
TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-traefik}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  up                         Create network (if needed) and start Traefik stack
  down                       Stop Traefik stack
  restart                    Restart Traefik stack
  logs                       Tail Traefik logs
  status                     Show Traefik stack status
  network                    Ensure external network exists
  mkcert ls                  List SAN entries from current dev cert
  mkcert add HOST [HOST..]   Add SAN entries and reissue dev cert (backup before change)
  mkcert rm HOST [HOST..]    Remove SAN entries and reissue dev cert (backup before change)
  mkcert backup              Create a timestamped backup of current dev cert/key
  config                     Validate docker compose config
  help                       Show this help

Environment:
  TRAEFIK_NETWORK (default: traefik)
  DEV_PROXY_ROOT (optional): absolute path to repo root with dev-proxy/docker-compose.yml
  TRAEFIK_SUBNET (optional): explicit subnet CIDR for the network (e.g. 10.123.0.0/16)
  TRAEFIK_SUBNETS (optional): space-separated list of candidate subnets to try
EOF
}

# Helpers for cert paths and SAN handling
_cert_paths() {
  CERT_DIR="$ROOT_DIR/gateway/certs"
  CERT="$CERT_DIR/dev.pem"
  KEY="$CERT_DIR/dev-key.pem"
  BACKUPS_DIR="$CERT_DIR/backups"
}

_extract_sans() {
  # Prints SAN host entries (DNS/IP) one per line to stdout; includes CN if present
  local cert_file="$1"
  [[ -f "$cert_file" ]] || return 0
  local text
  text=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null || true)
  [[ -n "${text:-}" ]] || return 0
  # Extract DNS entries
  printf "%s" "$text" | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://' || true
  # Extract IP entries (two possible labels)
  printf "%s" "$text" | grep -oE 'IP Address:[^,[:space:]]+' | sed 's/^IP Address://' || true
  printf "%s" "$text" | grep -oE '\bIP:[^,[:space:]]+' | sed 's/^IP://' || true
  # Also include CN (Subject CN) if present
  local cn
  cn=$(printf "%s" "$text" | sed -n 's/^\s*Subject:.*CN\s*=\s*\([^,]\+\).*/\1/p' | head -n1 || true)
  if [[ -z "$cn" ]]; then
    cn=$(printf "%s" "$text" | sed -n 's/^\s*Subject:.*CN=\([^,]\+\).*/\1/p' | head -n1 || true)
  fi
  if [[ -n "$cn" ]]; then
    echo "$cn"
  fi
}

_backup_cert_key() {
  _cert_paths
  mkdir -p "$BACKUPS_DIR"
  local ts
  ts=$(date '+%Y%m%d-%H%M%S')
  local backed_up=0
  if [[ -f "$CERT" ]]; then
    cp -f "$CERT" "$BACKUPS_DIR/$(basename "$CERT").$ts.BAK"
    echo "Backup: $BACKUPS_DIR/$(basename "$CERT").$ts.BAK"
    backed_up=1
  else
    echo "Warning: cert not found: $CERT" >&2
  fi
  if [[ -f "$KEY" ]]; then
    cp -f "$KEY" "$BACKUPS_DIR/$(basename "$KEY").$ts.BAK"
    echo "Backup: $BACKUPS_DIR/$(basename "$KEY").$ts.BAK"
    backed_up=1
  else
    echo "Warning: key not found: $KEY" >&2
  fi
  return $backed_up
}

_regen_cert_with_hosts() {
  # args: hosts array
  _cert_paths
  mkdir -p "$CERT_DIR"
  local -a hosts=("$@")
  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "Error: no hosts to issue certificate" >&2
    return 2
  fi
  if command -v mkcert >/dev/null 2>&1; then
    echo "Using mkcert to generate dev certificates for: ${hosts[*]}"
    mkcert -install || true
    mkcert -cert-file "$CERT" -key-file "$KEY" "${hosts[@]}"
  else
    echo "mkcert not found. Using openssl to generate a self-signed cert (browser will warn)."
    local san_list=""
    local h entry
    for h in "${hosts[@]}"; do
      if [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        entry="IP:$h"
      elif [[ "$h" == *:* ]]; then
        entry="IP:$h"
      else
        entry="DNS:$h"
      fi
      if [[ -z "$san_list" ]]; then
        san_list="$entry"
      else
        san_list="$san_list,$entry"
      fi
    done
    local SAN="subjectAltName=$san_list"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout "$KEY" \
      -out "$CERT" \
      -subj "/CN=${hosts[0]}" \
      -addext "$SAN"
  fi
  echo "Certificates generated: $CERT, $KEY"
}

mkcert_cmd() {
  local subcmd="${1:-}"; shift || true
  case "$subcmd" in
    ls)
      _cert_paths
      if [[ ! -f "$CERT" ]]; then
        echo "No certificate found: $CERT" >&2
        return 1
      fi
      echo "SAN entries in $CERT:"
      _extract_sans "$CERT" | sort -u || true
      ;;
    add)
      if [[ $# -lt 1 ]]; then
        echo "Usage: $(basename "$0") mkcert add HOST [HOST ...]" >&2
        return 2
      fi
      _cert_paths
      local -a current=()
      if [[ -f "$CERT" ]]; then
        mapfile -t current < <(_extract_sans "$CERT" | sort -u)
      fi
      # Build union
      declare -A seen=()
      local -a combined=()
      local h
      for h in "${current[@]}" "$@"; do
        [[ -z "$h" ]] && continue
        if [[ -z "${seen[$h]:-}" ]]; then
          seen[$h]=1
          combined+=("$h")
        fi
      done
      # Detect changes (best-effort)
      if [[ ${#combined[@]} -eq ${#current[@]} ]]; then
        local changed=0
        # check if every current is in combined
        declare -A in_comb=()
        for h in "${combined[@]}"; do in_comb[$h]=1; done
        for h in "${current[@]}"; do [[ -n "${in_comb[$h]:-}" ]] || changed=1; done
        if [[ $changed -eq 0 ]]; then
          echo "No changes: all hosts already present in SAN"
          return 0
        fi
      fi
      echo "Creating backup before changes..."
      _backup_cert_key || true
      _regen_cert_with_hosts "${combined[@]}"
      ;;
    rm)
      if [[ $# -lt 1 ]]; then
        echo "Usage: $(basename "$0") mkcert rm HOST [HOST ...]" >&2
        return 2
      fi
      _cert_paths
      if [[ ! -f "$CERT" ]]; then
        echo "No certificate found: $CERT" >&2
        return 1
      fi
      mapfile -t current < <(_extract_sans "$CERT" | sort -u)
      # Remove listed hosts
      declare -A to_remove=()
      for h in "$@"; do to_remove[$h]=1; done
      local -a remaining=()
      local removed=0
      for h in "${current[@]}"; do
        if [[ -n "${to_remove[$h]:-}" ]]; then
          removed=1
        else
          remaining+=("$h")
        fi
      done
      if [[ $removed -eq 0 ]]; then
        echo "No changes: none of specified hosts found in SAN"
        return 0
      fi
      if [[ ${#remaining[@]} -eq 0 ]]; then
        echo "Error: removing these hosts would leave certificate with empty SAN. Aborting." >&2
        return 2
      fi
      echo "Creating backup before changes..."
      _backup_cert_key || true
      _regen_cert_with_hosts "${remaining[@]}"
      ;;
    backup)
      _backup_cert_key || true
      ;;
    ""|help|-h|--help)
      echo "mkcert subcommands: ls | add HOST... | rm HOST... | backup"; return 0 ;;
    *)
      echo "Unknown mkcert subcommand: $subcmd" >&2
      echo "mkcert subcommands: ls | add HOST... | rm HOST... | backup" >&2
      return 2 ;;
  esac
}

ensure_network() {
  echo "Ensuring external network '$TRAEFIK_NETWORK' exists..."
  if docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
    echo "Network '$TRAEFIK_NETWORK' already exists"
    return 0
  fi
  # Try create with default settings first
  if docker network create -d bridge "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
    echo "Created network '$TRAEFIK_NETWORK'"
    return 0
  fi
  echo "Default network create failed. Will try explicit subnets (IPAM pool exhaustion workaround)..."
  local CANDIDATE_SUBNETS
  # Support both a single subnet and a list
  if [[ -n "${TRAEFIK_SUBNET:-}" ]]; then
    CANDIDATE_SUBNETS="$TRAEFIK_SUBNET"
  fi
  if [[ -n "${TRAEFIK_SUBNETS:-}" ]]; then
    CANDIDATE_SUBNETS="${CANDIDATE_SUBNETS:+$CANDIDATE_SUBNETS }$TRAEFIK_SUBNETS"
  fi
  # Add some defaults if none provided
  if [[ -z "${CANDIDATE_SUBNETS:-}" ]]; then
    CANDIDATE_SUBNETS="172.30.0.0/16 172.31.0.0/16 10.10.0.0/16 192.168.100.0/24 10.123.0.0/16"
  fi
  local created=0 net
  for net in $CANDIDATE_SUBNETS; do
    [[ -z "$net" ]] && continue
    echo "Trying subnet $net ..."
    if docker network create -d bridge --subnet "$net" "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
      echo "Created network '$TRAEFIK_NETWORK' with subnet $net"
      created=1
      break
    fi
  done
  if [[ "$created" -ne 1 ]]; then
    echo "Failed to create network '$TRAEFIK_NETWORK'." >&2
    echo "Hints:" >&2
    echo " - Provide a free subnet via TRAEFIK_SUBNET=10.123.0.0/16 dev-proxy network" >&2
    echo " - Or run 'docker network prune' to clean up unused docker networks and retry" >&2
    return 1
  fi
}

up() {
  ensure_network
  echo "Starting Traefik stack (-p $PROJECT_NAME) using $COMPOSE_FILE ..."
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d
  # Hints with actual host ports from .env (with defaults)
  local DASHBOARD_PORT="${TRAEFIK_PORT_DASHBOARD:-8081}"
  local HTTP_PORT="${TRAEFIK_PORT_HTTP:-80}"
  local HTTPS_PORT="${TRAEFIK_PORT_HTTPS:-443}"
  echo "Dashboard: http://localhost:${DASHBOARD_PORT}"
  echo "Entrypoints: http -> :${HTTP_PORT}, https -> :${HTTPS_PORT}"
}

down() {
  echo "Stopping Traefik stack (-p $PROJECT_NAME) ..."
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans
}

restart() {
  down || true
  up
}

logs() {
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" logs -f --no-color
}

status() {
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" ps
}

config() {
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config
}

cmd="${1:-help}"
case "$cmd" in
  up) up ;;
  down) down ;;
  restart) restart ;;
  logs) logs ;;
  status) status ;;
  network) ensure_network ;;
  mkcert) shift; mkcert_cmd "$@" ;;
  config) config ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: $cmd"; usage; exit 1 ;;
esac
