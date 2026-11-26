#!/usr/bin/env bash
#
# Hermes Gateway Desktop Setup Wizard
# Configures a remote backend for the Hermes Desktop app.
#
# Usage:
#   Non-interactive (recommended): bash setup-gateway.sh
#   With custom values:            bash setup-gateway.sh admin 'MyPass123!' 9119
#   Port as a flag:                bash setup-gateway.sh admin 'MyPass123!' --port 9119
#   Port from the environment:     PORT=9119 bash setup-gateway.sh admin 'MyPass123!'
#   Interactive mode:              INTERACTIVE=1 bash setup-gateway.sh
#   Overwrite existing creds:      bash setup-gateway.sh --clean
#   Repair service, keep creds:    bash setup-gateway.sh --keep-creds --port 9119
#   curl:                          curl -fsSL https://raw.githubusercontent.com/MiaAI-Lab/HermesGW-Desktop-setup/main/setup-gateway.sh | bash
#
# Two users, two instances, one host — run the wizard once per account, from
# that account, with a different port each time:
#
#   sudo -iu alice bash setup-gateway.sh admin 'Pass123!' 9119
#   sudo -iu bob   bash setup-gateway.sh admin 'Pass456!' 9120
#
# Everything the wizard touches is per user:
#   credentials  $HOME/.hermes/.env
#   service      $HOME/.config/systemd/user/hermes-serve.service
#   log          $HOME/.local/state/hermes/logs/hermes-serve-<port>.log
#   journal      journalctl --user -u hermes-serve.service
#
# Requirements:
#   - Hermes Agent installed (hermes command on PATH, for every user that runs this)
#   - Linux with systemd (user services)
#   - Network access on the chosen port
#
# Fixes over the upstream version (MiaAI-Lab/HermesGW-Desktop-setup):
#   1. setup_port() takes the port from its FIRST argument (upstream read the
#      third argument of the function, which is always empty, so every run
#      silently fell back to 9119 and a second account could never pick a port).
#   2. The nohup log lives in the user's own state dir instead of the shared
#      /tmp/hermes-serve.log, which the first account owned and every other
#      account failed to open ("Permission denied") — the server never started.
#   3. No nohup copy is started when systemd --user is available, so the unit
#      and the manual process stop fighting for the same port.
#   4. XDG_RUNTIME_DIR is exported, so `systemctl --user` also works over ssh.
#   5. A port taken by another account is a hard error instead of a silent
#      "skipping server start" that leaves a half-configured install.
#   6. Linger/systemd hiccups no longer abort the wizard halfway through.

set -eo pipefail

# ── Colors & symbols ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INFO()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
OK()    { echo -e "${GREEN}[  OK  ]${NC}  $*"; }
WARN()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
ERROR() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
HEADING() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

usage() {
    cat <<'EOF'
Usage: bash setup-gateway.sh [LOGIN] [PASSWORD] [PORT] [options]

  LOGIN         dashboard username                (default: admin)
  PASSWORD      dashboard password                (default: generated)
  PORT          TCP port to listen on             (default: 9119)
  --port N      same as the 3rd positional argument
  --host H      bind address (default: 0.0.0.0; use 127.0.0.1 for ssh-tunnel-only)
  --clean       overwrite existing credentials in ~/.hermes/.env
  --keep-creds  reuse the credentials already in ~/.hermes/.env
                (repair/replace the service without breaking a paired Desktop app)
  --allow-root  run as root anyway (breaks per-user isolation)
  -h, --help    show this help

Two users on one host: run the wizard once per account, with its own port:

  sudo -iu alice bash setup-gateway.sh admin 'Pass123!' 9119
  sudo -iu bob   bash setup-gateway.sh admin 'Pass456!' 9120

Logs (per user, per port): ~/.local/state/hermes/logs/hermes-serve-<port>.log
EOF
}

# ── Detect IPs ────────────────────────────────────────────────────
detect_ips() {
    LAN_IP=$(ip -4 addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | grep -vE 'docker|virbr|veth|lo' | head -1 | awk '{print $2}' | cut -d/ -f1) || true
    [[ -z "$LAN_IP" ]] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true

    TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}' | cut -d/ -f1) || true

    HOSTNAME=$(hostname 2>/dev/null) || true
    HOSTNAME="${HOSTNAME:-localhost}"

    # Default port: $PORT from the environment wins, an explicit argument
    # (see setup_port) wins over both.
    PORT="${PORT:-9119}"

    # Bind address: 0.0.0.0 keeps upstream behaviour (and engages Hermes' auth
    # gate, which requires a registered auth provider on non-loopback binds).
    # For ssh-tunnel-only setups 127.0.0.1 works too and needs no auth provider.
    HOST="${HOST:-0.0.0.0}"
}

# ── systemd --user availability ───────────────────────────────────
# `systemctl --user` over a plain ssh session may fail with
# "Failed to connect to bus: No such file or directory" when XDG_RUNTIME_DIR is
# not exported. Upstream then silently fell back to nohup, and both users ended
# up sharing /tmp/hermes-serve.log. Make the bus reachable instead.
have_user_systemd() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -d "${XDG_RUNTIME_DIR:-}" ]]; then
        if [[ -d "/run/user/$(id -u)" ]]; then
            export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        fi
    fi
    systemctl --user show-environment &>/dev/null
}

# ── Port helpers ──────────────────────────────────────────────────
# Anything listening on $1 (any local address) -> true.
port_listening() {
    local port="$1" out=""

    if command -v ss &>/dev/null; then
        out=$(ss -H -tln "sport = :$port" 2>/dev/null) || true
        if [[ -z "$out" ]]; then
            # exotic/filter-less iproute2 build: fall back to a full scan
            out=$(ss -H -tln 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"') || true
        fi
        [[ -n "$out" ]]
        return
    fi

    if command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port$"
        return
    fi

    return 1
}

# PID listening on $1, if we are allowed to see it (ss -p only shows our own
# processes for a non-root user, which is exactly what we want).
port_owner_pid() {
    local port="$1"
    command -v ss &>/dev/null || return 0
    ss -H -tlnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true
}

# True when the listener on $1 belongs to the current account.
port_owned_by_me() {
    local pid=""
    pid=$(port_owner_pid "$1" 2>/dev/null) || true
    [[ -n "$pid" ]]
}

# A few ports that are free right now, for the hint shown on a conflict.
find_free_ports() {
    local p=$(( 10#${1:-9119} + 1 )) n=0 out=""
    while [[ $n -lt 3 && $p -le 65535 ]]; do
        if ! port_listening "$p"; then
            out+="$p "
            n=$((n + 1))
        fi
        p=$((p + 1))
    done
    echo "${out:-none}"
}

# ── Check prerequisites ──────────────────────────────────────────
check_prereqs() {
    local has_error=0

    if [[ ${EUID:-$(id -u)} -eq 0 && ${ALLOW_ROOT:-0} -ne 1 ]]; then
        ERROR "Do not run this wizard as root (and not through plain 'sudo')."
        ERROR "The gateway is configured per account: \$HOME/.hermes, systemd --user,"
        ERROR "the log file and the unit all live in the user's own home directory."
        ERROR "On a two-user host run it once per account:"
        ERROR "  sudo -iu alice bash setup-gateway.sh admin 'Pass1' 9119"
        ERROR "  sudo -iu bob   bash setup-gateway.sh admin 'Pass2' 9120"
        ERROR "If you really need root, add --allow-root."
        exit 1
    fi

    if ! command -v hermes &>/dev/null; then
        ERROR "Hermes CLI not found for $(id -un) ($(command -v hermes 2>/dev/null || echo 'not on PATH')). Install it as this user:"
        ERROR "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
        has_error=1
    else
        OK "Hermes CLI found: $(command -v hermes)"
    fi

    # Verify 'hermes serve' subcommand exists (v0.18.0+)
    if ! hermes serve --help &>/dev/null 2>&1; then
        ERROR "'hermes serve' subcommand not available."
        ERROR "This script requires Hermes v0.18.0 or newer."
        ERROR "Update Hermes: hermes update"
        has_error=1
    else
        OK "'hermes serve' subcommand available"
    fi

    if have_user_systemd; then
        OK "systemd user services available"
    else
        WARN "systemd user services are not reachable from this session."
        WARN "Credentials will still be configured and the server will be started with nohup,"
        WARN "but it will not survive a reboot. Re-run as a login session: sudo -iu $(id -un)"
    fi

    if ! command -v openssl &>/dev/null; then
        ERROR "openssl not found. Install it to generate a secure secret."
        has_error=1
    else
        OK "openssl available"
    fi

    if [[ $has_error -eq 1 ]]; then
        ERROR "Fix the issues above and run the wizard again."
        exit 1
    fi
}

# ── Parse flags ───────────────────────────────────────────────────
CLEAN=0
KEEP_CREDS=0
ALLOW_ROOT=0
PORT_ARG=""
HOST_ARG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --keep-creds) KEEP_CREDS=1; shift ;;
        --allow-root) ALLOW_ROOT=1; shift ;;
        --host)
            if [[ -z "${2:-}" ]]; then
                ERROR "--host needs a value, e.g. --host 127.0.0.1"
                exit 2
            fi
            HOST_ARG="$2"
            shift 2
            ;;
        --host=*) HOST_ARG="${1#*=}"; shift ;;
        --port)
            if [[ -z "${2:-}" ]]; then
                ERROR "--port needs a value, e.g. --port 9120"
                exit 2
            fi
            PORT_ARG="$2"
            shift 2
            ;;
        --port=*) PORT_ARG="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            case "$1" in
                -*) ERROR "Unknown option: $1 (try --help)"; exit 2 ;;
            esac
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

ARG_USERNAME="${1:-}"
ARG_PASSWORD="${2:-}"
ARG_PORT="${3:-}"
if [[ -n "$PORT_ARG" ]]; then
    ARG_PORT="$PORT_ARG"
fi
if [[ $CLEAN -eq 1 && $KEEP_CREDS -eq 1 ]]; then
    ERROR "--clean and --keep-creds are mutually exclusive."
    exit 2
fi

# ── Check if already configured ──────────────────────────────────
check_existing_config() {
    local env_file="$HOME/.hermes/.env"

    if [[ -f "$env_file" ]]; then
        if grep -q "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "$env_file" 2>/dev/null; then
            if [[ $CLEAN -eq 1 ]]; then
                INFO "Running in --clean mode — overwriting existing credentials."
            else
                WARN "Remote backend credentials already exist in $env_file"
                if [[ "${INTERACTIVE:-0}" == "1" ]]; then
                    echo ""
                    echo -n "  Reconfigure? [y/N] "
                    read -r -t 10 ANSWER 2>/dev/null || true
                    ANSWER="${ANSWER:-N}"
                    if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
                        INFO "Keeping existing configuration."
                        return 1
                    fi
                else
                    INFO "Existing config detected. Skipping (run with --clean to overwrite)."
                    return 1
                fi
            fi
        fi
    fi
    return 0
}

# ── Reuse existing credentials (--keep-creds) ────────────────────
# Repairs a half-installed account — credentials first, service later — without
# regenerating the password/secret and therefore without breaking a Desktop app
# that is already paired with this gateway.
load_existing_credentials() {
    HEADING "Reusing Existing Credentials"

    local env_file="$HOME/.hermes/.env"
    if [[ ! -f "$env_file" ]]; then
        ERROR "--keep-creds was given, but $env_file does not exist."
        ERROR "Run without --keep-creds (or with --clean) to create credentials."
        return 1
    fi

    USERNAME=$(grep -m1 '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    local has_pw=""
    has_pw=$(grep -m1 '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=' "$env_file" 2>/dev/null || true)

    if [[ -z "$USERNAME" || -z "$has_pw" ]]; then
        ERROR "$env_file has no HERMES_DASHBOARD_BASIC_AUTH_* credentials."
        ERROR "Run without --keep-creds (or with --clean) to create them."
        return 1
    fi

    PASSWORD="(kept — see $env_file)"
    SECRET="(kept — see $env_file)"

    OK "Keeping credentials from $env_file"
    INFO "  User:     $(id -un)"
    INFO "  Username: $USERNAME"
    INFO "  Password: unchanged"
    return 0
}

# ── Setup credentials ────────────────────────────────────────────
setup_credentials() {
    HEADING "Remote Backend Credentials"

    USERNAME="${1:-admin}"
    local password="${2:-}"

    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12)
        WARN "No password provided. Generated one:"
        # Print to stderr so it shows even when piped to bash
        echo "" >&2
        echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${BOLD}${GREEN}║  SAVE THIS PASSWORD:  $password${NC}" >&2
        echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}" >&2
        echo "" >&2
    fi
    PASSWORD="$password"

    if [[ ${#PASSWORD} -lt 8 ]]; then
        WARN "Password is less than 8 characters — consider a stronger one."
        if [[ "${INTERACTIVE:-0}" == "1" ]]; then
            echo -n "  Continue anyway? [y/N] "
            read -r -t 10 ANSWER 2>/dev/null || true
            if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
                ERROR "Aborted."
                exit 1
            fi
        fi
    fi

    SECRET=$(openssl rand -base64 32)
    OK "Generated stable auth secret (survives restarts)"

    echo ""
    INFO "Credentials summary:"
    INFO "  User:     $(id -un)  (home: $HOME)"
    INFO "  Username: $USERNAME"
    INFO "  Password: (hidden)"
    INFO "  Secret:   $SECRET"

    # Write to .env
    local env_file="$HOME/.hermes/.env"
    local tmp_file
    tmp_file=$(mktemp)
    mkdir -p "$HOME/.hermes"

    if [[ -f "$env_file" ]]; then
        grep -v "HERMES_DASHBOARD_BASIC_AUTH" "$env_file" > "$tmp_file" 2>/dev/null || true
        cp "$tmp_file" "$env_file"
    fi

    cat >> "$env_file" <<EOF

# ═══════════════════════════════════════════════════════════════════
# Hermes Gateway Desktop — Remote Backend Auth
# Generated by setup-gateway.sh on $(date)
# ═══════════════════════════════════════════════════════════════════
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$USERNAME
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$PASSWORD
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SECRET
EOF

    chmod 600 "$env_file"
    rm -f "$tmp_file"

    OK "Credentials written to $env_file (mode 600, user $(id -un))"
}

# ── Configure port ────────────────────────────────────────────────
setup_port() {
    HEADING "Port Configuration"

    # FIX (1): the port is the FIRST argument of this function.
    # Upstream used ${3:-9119} — the third argument of the *function*, which is
    # always empty because main() calls `setup_port "${3:-}"`. Result: every run
    # silently used 9119, so a second account always collided with the first.
    PORT="${1:-${PORT:-9119}}"

    if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]]; then
        ERROR "Invalid port: '$PORT' (expected a number 1..65535)."
        exit 2
    fi
    PORT=$((10#$PORT))   # normalise: "09119" -> 9119, no octal surprises
    if (( PORT < 1 || PORT > 65535 )); then
        ERROR "Invalid port: $PORT (expected 1..65535)."
        exit 2
    fi

    if [[ -z "$HOST" || "$HOST" =~ [[:space:]] ]]; then
        ERROR "Invalid bind address: '$HOST'."
        exit 2
    fi

    echo "  Bind address: $HOST   (0.0.0.0 = LAN/public, 127.0.0.1 = ssh-tunnel only)"
    echo "  Available IPs:"
    if [[ -n "$LAN_IP" ]]; then
        echo "    LAN:      $LAN_IP"
    else
        echo "    LAN:      (not detected — you'll enter it manually)"
    fi
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "    Tailscale: $TAILSCALE_IP"
    else
        echo "    Tailscale: (not detected — not connected?)"
    fi
    echo ""

    if port_listening "$PORT"; then
        if port_owned_by_me "$PORT"; then
            OK "Port $PORT is already served by your own account — reusing it"
        else
            ERROR "Port $PORT is already taken on this host by another process or account."
            ERROR "Two gateways cannot listen on one port, and a half-started install"
            ERROR "is worse than no install at all — refusing to continue."
            ERROR "Start this instance on a free port instead, e.g.:"
            ERROR "  bash setup-gateway.sh ${USERNAME:-admin} '<password>' $((PORT + 1))"
            ERROR "Currently free ports: $(find_free_ports "$PORT")"
            exit 3
        fi
    else
        OK "Port $PORT is available"
    fi
}

# ── Per-user log file ────────────────────────────────────────────
# FIX (2): upstream logged to /tmp/hermes-serve.log — one fixed path shared by
# every account on the host. The first user created it (0644), and for the
# second user the shell redirection itself failed:
#   bash: /tmp/hermes-serve.log: Permission denied
# The child never even exec'd `hermes serve`, and the wizard only reported a
# misleading "Server failed to start". Keep the log inside the user's home.
setup_logs() {
    local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
    LOG_DIR="$state_home/hermes/logs"
    LOG_FILE="$LOG_DIR/hermes-serve-$PORT.log"

    if ! mkdir -p "$LOG_DIR"; then
        ERROR "Cannot create log directory: $LOG_DIR"
        exit 1
    fi
    chmod 700 "$state_home/hermes" 2>/dev/null || true
    chmod 700 "$LOG_DIR" 2>/dev/null || true

    # rotate a log that grew past 10 MiB
    local size=0
    if [[ -f "$LOG_FILE" ]]; then
        size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt 10485760 ]]; then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi

    if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
        ERROR "Cannot write to log file: $LOG_FILE"
        ERROR "Check ownership and permissions of $LOG_DIR (is this your home?)."
        exit 1
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    OK "Log file (per user, per port): $LOG_FILE"
}

# ── Start the backend server ─────────────────────────────────────
start_backend() {
    HEADING "Starting Backend Server"

    local service="hermes-serve.service"

    # FIX (3): when systemd --user is available the unit is the single owner of
    # the port. Upstream started a nohup copy *and* enabled the unit on the same
    # port, so the unit crash-looped with "address already in use".
    if have_user_systemd; then
        if systemctl --user is-active "$service" &>/dev/null; then
            OK "Server already running via systemd (PID: $(systemctl --user show -p MainPID --value "$service" 2>/dev/null || echo 'unknown'))"
        else
            INFO "systemd --user is available — starting the server as a service (no nohup copy)."
            INFO "Logs: journalctl --user -u $service -f"
        fi
        return 0
    fi

    WARN "systemd --user is not available — starting a detached process on port $PORT."
    WARN "It will not be restarted automatically and will not survive a reboot."

    if port_listening "$PORT"; then
        INFO "A process is already listening on port $PORT — nothing to start."
        return 0
    fi

    INFO "Starting hermes serve on $HOST:$PORT ..."
    INFO "Log: $LOG_FILE"

    nohup hermes serve --host "$HOST" --port "$PORT" >> "$LOG_FILE" 2>&1 &
    local pid=$!

    # Give the process a moment to initialize
    sleep 2

    if ! kill -0 "$pid" 2>/dev/null; then
        ERROR "Server failed to start (process $pid exited immediately)."
        if [[ -s "$LOG_FILE" ]]; then
            WARN "Last lines of $LOG_FILE:"
            tail -n 20 "$LOG_FILE" >&2 || true
        else
            WARN "The log file is empty — the shell could not even open it or hermes printed nothing."
        fi
        return 1
    fi

    local max_wait=30 waited=0
    while [[ $waited -lt $max_wait ]]; do
        if port_listening "$PORT"; then
            OK "Server started (PID: $pid) — listening on port $PORT"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    WARN "Process $pid is alive but port $PORT is not listening yet."
    WARN "  tail -n 50 $LOG_FILE"
    return 1
}

# ── Set up systemd service ───────────────────────────────────────
setup_systemd() {
    HEADING "Systemd Service Setup"

    local service="hermes-serve.service"
    local service_file="$HOME/.config/systemd/user/$service"

    if ! have_user_systemd; then
        WARN "systemd user services not available. Skipping service setup."
        WARN "To keep the server running, use:"
        WARN "  tmux new-session -d -s hermes-serve 'hermes serve --host $HOST --port $PORT'"
        WARN "or re-run this wizard from a login session: sudo -iu $(id -un)"
        return 0
    fi

    mkdir -p "$HOME/.config/systemd/user"

    local hermes_bin
    hermes_bin=$(command -v hermes)

    # Port is baked into the unit (and into Description) so two instances on
    # one host are easy to tell apart: `systemctl --user list-units | grep hermes`
    cat > "$service_file" <<EOF
[Unit]
Description=Hermes Backend Server on port $PORT (powers the Desktop app)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart="$hermes_bin" serve --host $HOST --port $PORT
Restart=always
RestartSec=5
Environment="HOME=$HOME"
Environment="HERMES_HOME=$HOME/.hermes"
Environment="PATH=$(dirname "$hermes_bin"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-serve

[Install]
WantedBy=default.target
EOF

    OK "Service file created: $service_file (port $PORT)"

    systemctl --user daemon-reload || WARN "daemon-reload failed"

    # A nohup copy left from an earlier run holds the port and makes the unit
    # fail with "address already in use" + restart-loop. Stop our own leftovers.
    local svc_active=0
    if systemctl --user is-active "$service" &>/dev/null; then
        svc_active=1
    fi
    if [[ $svc_active -eq 0 ]] && port_owned_by_me "$PORT"; then
        INFO "Stopping a manually started instance on port $PORT ..."
        pkill -u "$(id -u)" -f "hermes serve .*--port $PORT" 2>/dev/null || true
        sleep 1
    fi

    systemctl --user enable "$service" || WARN "Could not enable $service"
    # restart (not just start) so a changed port/Path actually takes effect
    systemctl --user restart "$service" || WARN "Could not (re)start $service"

    local waited=0
    while [[ $waited -lt 30 ]]; do
        if systemctl --user is-active "$service" &>/dev/null && port_listening "$PORT"; then
            OK "Service is active and listening on port $PORT"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    WARN "Service did not come up on port $PORT within 30 s."
    WARN "  systemctl --user status $service"
    WARN "  journalctl --user -u $service -n 50 --no-pager"
    return 1
}

# ── Enable linger ─────────────────────────────────────────────────
setup_linger() {
    HEADING "Login Linger"

    local user
    user="$(id -un)"

    if ! command -v loginctl &>/dev/null; then
        WARN "loginctl not found. Skipping linger setup."
        return 0
    fi

    if loginctl show-user "$user" 2>/dev/null | grep -q "Linger=yes"; then
        OK "Linger already enabled for $user"
        return 0
    fi

    if [[ "${INTERACTIVE:-0}" == "1" ]]; then
        echo -n "  Enable linger so the server starts on boot? [Y/n] "
        read -r -t 10 ANSWER 2>/dev/null || true
        ANSWER="${ANSWER:-Y}"
        if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
            WARN "Server won't auto-start on boot without linger."
            return 0
        fi
    fi

    # FIX (6): a polkit refusal must not kill the run before the summary.
    if loginctl enable-linger "$user" 2>/dev/null; then
        OK "Linger enabled — the gateway starts on boot, without an active login"
    else
        WARN "Could not enable linger for $user (needs polkit/root)."
        WARN "Ask root to run:  sudo loginctl enable-linger $user"
        WARN "Without linger the service starts only after $user logs in."
    fi
    return 0
}

# ── Print final instructions ─────────────────────────────────────
print_final_instructions() {
    HEADING "🎉 Setup Complete!"

    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Your next step: Connect the Hermes Desktop app              ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    echo -e "${BOLD}1️⃣  Open the Hermes Desktop app → Settings → Gateway${NC}\n"

    echo -e "${BOLD}2️⃣  Enter these connection details:${NC}"
    echo ""
    echo -e "  ${BOLD}Remote gateway URL:${NC}"
    case "$HOST" in
        127.0.0.1|localhost|::1)
            echo -e "    http://127.0.0.1:$PORT  (loopback on this host — use an ssh tunnel)"
            echo -e "    ${DIM}ssh -N -L $PORT:127.0.0.1:$PORT $(id -un)@<vps-address>${NC}"
            echo -e "    ${DIM}then open http://127.0.0.1:$PORT locally${NC}"
            ;;
        *)
            if [[ -n "$LAN_IP" ]]; then
                echo -e "    http://$LAN_IP:$PORT  (LAN — fastest)"
            else
                echo -e "    (LAN IP not detected — run: hostname -I)"
            fi
            if [[ -n "$TAILSCALE_IP" ]]; then
                echo -e "    http://$TAILSCALE_IP:$PORT  (Tailscale — from anywhere)"
            fi
            ;;
    esac
    echo ""
    echo -e "  ${BOLD}Bind address:${NC} $HOST"
    echo -e "  ${BOLD}Username:${NC}    $USERNAME"
    echo -e "  ${BOLD}Password:${NC}    $PASSWORD"
    echo ""

    echo -e "${BOLD}3️⃣  Click 'Sign in', then 'Save and reconnect'${NC}\n"

    echo -e "${DIM}Run on: $(id -un)@$HOSTNAME, port $PORT.${NC}"
    echo -e "${DIM}Every account on this host runs its own wizard + its own port (9119, 9120, …);${NC}"
    echo -e "${DIM}credentials, unit and log all live in that account's home directory.${NC}\n"

    echo -e "${BOLD}🔧 Manage this instance (as $(id -un)):${NC}"
    echo "  systemctl --user status hermes-serve.service   # status"
    echo "  systemctl --user restart hermes-serve.service  # restart"
    echo "  journalctl --user -u hermes-serve.service -f   # live logs"
    echo "  tail -f $LOG_FILE   # nohup fallback log (if used)"
    echo ""
    if [[ "$HOST" == "127.0.0.1" || "$HOST" == "::1" || "$HOST" == "localhost" ]]; then
        echo -e "${DIM}Loopback bind: no firewall rule needed, reach the gateway through:"
        echo -e "  ssh -N -L localhost:$PORT:127.0.0.1:$PORT $(id -un)@<vps-address>${NC}"
        echo ""
    else
        echo -e "${DIM}Firewall reminder: allow port $PORT for the account that owns it."
        echo -e "  sudo ufw allow $PORT/tcp${NC}"
        echo ""
    fi

    echo -e "${DIM}Setup completed on $(date).${NC}"
    echo ""
    echo -e "Follow me on X: ${BOLD}https://x.com/MiaAI_lab${NC}"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║   Mia's Hermes Gateway Desktop Setup Wizard              ║"
    echo "║   Configure a remote backend for the Desktop app         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    detect_ips
    if [[ -n "$HOST_ARG" ]]; then
        HOST="$HOST_ARG"
    fi
    check_prereqs
    if [[ $KEEP_CREDS -eq 1 ]]; then
        if [[ -n "$ARG_USERNAME$ARG_PASSWORD" ]]; then
            WARN "--keep-creds: ignoring LOGIN/PASSWORD from the command line."
        fi
        load_existing_credentials || exit 1
    else
        check_existing_config || exit 0
        setup_credentials "${ARG_USERNAME:-}" "${ARG_PASSWORD:-}"
    fi
    setup_port "${ARG_PORT:-}"
    setup_logs
    start_backend || WARN "The backend was not started by the wizard — see the commands below."
    setup_systemd || WARN "The systemd unit did not come up — see the commands below."
    setup_linger
    print_final_instructions
}

main "$@"
