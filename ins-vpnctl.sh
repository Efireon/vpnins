#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="openconnect-auto.service"
ENV_DIR="/etc/openconnect"
ENV_FILE="${ENV_DIR}/auto.env"
WRAPPER="/usr/local/bin/openconnect-auto.sh"
VPNCTL="/usr/local/bin/vpnctl"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
DISPATCHER_FILE="${DISPATCHER_DIR}/90-openconnect-auto"
POLKIT_DIR="/etc/polkit-1/rules.d"
POLKIT_FILE="${POLKIT_DIR}/49-openconnect-auto.rules"
LOCK_FILE="/run/openconnect-auto.manual-stop"

# Пути старого билда с именем "paradise", которые нужно почистить при апгрейде.
LEGACY_SERVICE="openconnect-paradise.service"
LEGACY_ENV="/etc/openconnect/paradise.env"
LEGACY_WRAPPER="/usr/local/bin/openconnect-paradise.sh"
LEGACY_UNIT="/etc/systemd/system/openconnect-paradise.service"
LEGACY_DISPATCHER="/etc/NetworkManager/dispatcher.d/90-openconnect-paradise"
LEGACY_POLKIT="/etc/polkit-1/rules.d/49-openconnect-paradise.rules"
LEGACY_LOCK="/run/openconnect-paradise.manual-stop"

VPN_SERVER=""
VPN_SERVER_TEMPLATE=""
VPN_SERVER_REG=""
VPN_CERT=""
VPN_PASSWORD=""
VPN_PASSWORD_MODE=""
VPN_TARGET_USER=""
OPENCONNECT_BIN=""

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
}

# Ищем остатки старого билда "paradise" и предлагаем их убрать.
cleanup_legacy() {
    local found=()

    [[ -f "$LEGACY_ENV" ]]        && found+=("$LEGACY_ENV")
    [[ -f "$LEGACY_WRAPPER" ]]    && found+=("$LEGACY_WRAPPER")
    [[ -f "$LEGACY_UNIT" ]]       && found+=("$LEGACY_UNIT")
    [[ -f "$LEGACY_DISPATCHER" ]] && found+=("$LEGACY_DISPATCHER")
    [[ -f "$LEGACY_POLKIT" ]]     && found+=("$LEGACY_POLKIT")
    [[ -e "$LEGACY_LOCK" ]]       && found+=("$LEGACY_LOCK")

    [[ "${#found[@]}" -eq 0 ]] && return 0

    warn "Found legacy 'paradise' build artifacts:"
    for f in "${found[@]}"; do
        printf '    %s\n' "$f"
    done

    read -r -p "Remove them now? [Y/n]: " ans
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Nn]$ ]] && return 0

    if systemctl is-active "$LEGACY_SERVICE" >/dev/null 2>&1; then
        log "Stopping legacy service: $LEGACY_SERVICE"
        systemctl stop "$LEGACY_SERVICE" || true
    fi
    if systemctl is-enabled "$LEGACY_SERVICE" >/dev/null 2>&1; then
        log "Disabling legacy service: $LEGACY_SERVICE"
        systemctl disable "$LEGACY_SERVICE" || true
    fi

    for f in "${found[@]}"; do
        rm -f "$f" && log "Removed: $f"
    done

    systemctl daemon-reload
    ok "Legacy artifacts removed."
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

backup_if_exists() {
    local file="$1"
    if [[ -e "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

is_steamdeck() {
    [[ -f /etc/os-release ]] && grep -q '^ID=steamos' /etc/os-release
}

# На Steam Deck рутовая ФС read-only. Снимаем блокировку и инициализируем
# ключи pacman если нужно. Пакеты слетят при следующем обновлении SteamOS.
steamdeck_prepare() {
    warn "Steam Deck (SteamOS) detected."
    warn "Packages installed via pacman will be wiped on SteamOS system updates."
    warn "Re-run this installer after each OS update to restore openconnect."
    if have_cmd steamos-readonly; then
        log "Disabling read-only filesystem"
        steamos-readonly disable </dev/null || die "Failed to disable read-only filesystem."
    fi
    if [[ ! -f /etc/pacman.d/gnupg/trustdb.gpg ]]; then
        log "Initializing pacman keyring"
        pacman-key --init </dev/null
        pacman-key --populate archlinux </dev/null
    fi
    # Синкаем базу пакетов заранее, чтобы в install_missing_packages не делать -u.
    # -Syu на Steam Deck тянет обновление системных пакетов SteamOS — это плохо.
    pacman -Sy --noconfirm </dev/null
}

# Определяем пакетный менеджер. Порядок проверки задаёт приоритет.
detect_pkg_manager() {
    if have_cmd dnf; then
        echo dnf
    elif have_cmd zypper; then
        echo zypper
    elif have_cmd apt-get; then
        echo apt
    elif have_cmd pacman; then
        echo pacman
    else
        echo none
    fi
}

install_missing_packages() {
    local pm="$1"
    shift
    local pkgs=("$@")

    [[ "${#pkgs[@]}" -eq 0 ]] && return 0

    case "$pm" in
        dnf)
            dnf -y install "${pkgs[@]}"
            ;;
        zypper)
            zypper --non-interactive install "${pkgs[@]}"
            ;;
        apt)
            apt-get update
            apt-get install -y "${pkgs[@]}"
            ;;
        pacman)
            if is_steamdeck; then
                # На Steam Deck -Syu обновляет системные пакеты SteamOS — нежелательно.
                # База уже синкнута в steamdeck_prepare, ставим только нужное.
                pacman -S --needed --noconfirm "${pkgs[@]}"
            else
                # -Sy без -u на Arch это partial upgrade, поэтому ставим полное -Syu.
                pacman -Syu --needed --noconfirm "${pkgs[@]}"
            fi
            ;;
        *)
            warn "No supported package manager detected. Install manually: ${pkgs[*]}"
            return 1
            ;;
    esac
}

# Проверяем наличие нужных команд и при согласии пользователя доставляем пакеты.
check_and_install_requirements() {
    local pm missing=()
    pm="$(detect_pkg_manager)"

    if [[ "$pm" == "pacman" ]] && is_steamdeck; then
        steamdeck_prepare
    fi

    have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || missing+=("openconnect")
    have_cmd nmcli || missing+=("NetworkManager")
    have_cmd systemctl || missing+=("systemd")
    have_cmd awk || missing+=("gawk")

    if [[ "${#missing[@]}" -eq 0 ]]; then
        ok "Required commands are already present."
        return 0
    fi

    warn "Missing requirements: ${missing[*]}"
    read -r -p "Try to install missing packages automatically? [Y/n]: " ans || true
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Nn]$ ]] && die "Missing packages were not installed."

    local pkgs=()
    case "$pm" in
        dnf)
            have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || pkgs+=("openconnect")
            have_cmd nmcli || pkgs+=("NetworkManager")
            have_cmd awk || pkgs+=("gawk")
            ;;
        zypper)
            have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || pkgs+=("openconnect")
            have_cmd nmcli || pkgs+=("NetworkManager")
            have_cmd awk || pkgs+=("gawk")
            ;;
        apt)
            have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || pkgs+=("openconnect")
            have_cmd nmcli || pkgs+=("network-manager")
            have_cmd awk || pkgs+=("gawk")
            ;;
        pacman)
            have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || pkgs+=("openconnect")
            have_cmd nmcli || pkgs+=("networkmanager")
            have_cmd awk || pkgs+=("gawk")
            ;;
        *)
            die "Cannot auto-install dependencies on this system."
            ;;
    esac

    install_missing_packages "$pm" "${pkgs[@]}"

    have_cmd systemctl || die "systemctl is still missing after installation."
    have_cmd nmcli || die "nmcli is still missing after installation."
    have_cmd awk || die "awk is still missing after installation."

    resolve_openconnect_bin
    ok "Required packages are installed."
}

# Ищем бинарь openconnect в PATH и в типичных системных путях.
resolve_openconnect_bin() {
    local candidates=()

    [[ -n "${OPENCONNECT_BIN:-}" ]] && candidates+=("$OPENCONNECT_BIN")

    if have_cmd openconnect; then
        candidates+=("$(command -v openconnect)")
    fi

    for p in \
        /usr/sbin/openconnect \
        /usr/bin/openconnect \
        /sbin/openconnect \
        /bin/openconnect \
        /usr/local/sbin/openconnect \
        /usr/local/bin/openconnect
    do
        candidates+=("$p")
    done

    local p
    for p in "${candidates[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -x "$p" ]] || continue
        OPENCONNECT_BIN="$p"
        ok "Using openconnect binary: $OPENCONNECT_BIN"
        return 0
    done

    die "openconnect binary not found. Checked PATH and common system paths."
}

load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    VPN_SERVER=""
    VPN_SERVER_TEMPLATE=""
    VPN_SERVER_REG=""
    VPN_CERT=""
    VPN_PASSWORD=""
    VPN_PASSWORD_MODE=""
    VPN_TARGET_USER=""
    OPENCONNECT_BIN=""

    # shellcheck disable=SC1090
    source "$file"

    return 0
}

prompt_default() {
    local var_name="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -r -p "$prompt: " value
    fi

    printf -v "$var_name" '%s' "$value"
}

# Читаем секрет без эха. Если секрет уже есть в env, предлагаем оставить его.
prompt_secret_with_default() {
    local var_name="$1"
    local prompt="$2"
    local current="${3:-}"
    local value keep

    if [[ -n "$current" ]]; then
        read -r -p "$prompt: keep existing secret? [Y/n]: " keep
        keep="${keep:-Y}"
        if [[ ! "$keep" =~ ^[Nn]$ ]]; then
            printf -v "$var_name" '%s' "$current"
            return 0
        fi
    fi

    read -r -s -p "$prompt: " value
    echo
    printf -v "$var_name" '%s' "$value"
}

show_existing_install_state() {
    echo
    echo "Detected existing installation state:"
    [[ -f "$ENV_FILE" ]] && echo "  env:        yes ($ENV_FILE)" || echo "  env:        no"
    [[ -f "$WRAPPER" ]] && echo "  wrapper:    yes ($WRAPPER)" || echo "  wrapper:    no"
    [[ -f "$VPNCTL" ]] && echo "  vpnctl:     yes ($VPNCTL)" || echo "  vpnctl:     no"
    [[ -f "$UNIT_FILE" ]] && echo "  unit:       yes ($UNIT_FILE)" || echo "  unit:       no"
    [[ -f "$DISPATCHER_FILE" ]] && echo "  dispatcher: yes ($DISPATCHER_FILE)" || echo "  dispatcher: no"
    [[ -f "$POLKIT_FILE" ]] && echo "  polkit:     yes ($POLKIT_FILE)" || echo "  polkit:     no"
    echo
}

choose_env_mode() {
    if [[ -f "$ENV_FILE" ]]; then
        warn "Existing environment file detected: $ENV_FILE"
        read -r -p "Use existing env as base? [Y/n]: " ans
        ans="${ans:-Y}"
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            if load_env_file "$ENV_FILE"; then
                ok "Loaded existing env."
            else
                warn "Failed to load existing env, will ask interactively."
            fi
        fi
    fi
}

# Собираем настройки интерактивно. Дефолты берём из существующего env.
collect_settings() {
    local default_user default_cert current_mode

    default_user="${VPN_TARGET_USER:-${SUDO_USER:-}}"
    if [[ -z "$default_user" || "$default_user" == "root" ]]; then
        default_user="$(logname 2>/dev/null || true)"
    fi
    # root плохой target для --setuid, поэтому сбрасываем. Если никого не нашли,
    # оставляем пусто и спросим явно.
    [[ "$default_user" == "root" ]] && default_user=""

    prompt_default TARGET_USER "Target local user for --setuid" "$default_user"
    id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."

    local server_mode_default=1
    [[ -n "${VPN_SERVER_TEMPLATE:-}" ]] && server_mode_default=2
    echo
    echo 'VPN server mode:'
    echo '  1) static   - one fixed URL'
    echo '  2) template - URL with {$REG} placeholder (switch later with vpnctl set-server)'
    read -r -p "Choose [1/2] (default $server_mode_default): " server_mode_choice
    server_mode_choice="${server_mode_choice:-$server_mode_default}"

    VPN_SERVER_TEMPLATE_NEW=""
    case "$server_mode_choice" in
        1)
            prompt_default VPN_SERVER_NEW "VPN server URL" "${VPN_SERVER:-}"
            [[ -n "$VPN_SERVER_NEW" ]] || die "VPN server URL cannot be empty."
            ;;
        2)
            prompt_default VPN_SERVER_TEMPLATE_NEW \
                'Server template, e.g. {$REG}.nixen.online/?path' \
                "${VPN_SERVER_TEMPLATE:-}"
            [[ -n "$VPN_SERVER_TEMPLATE_NEW" ]] || die "Template cannot be empty."
            prompt_default initial_reg 'Initial {$REG} value' "${VPN_SERVER_REG:-}"
            [[ -n "$initial_reg" ]] || die "Region value cannot be empty."
            local _ph='{$REG}'
            VPN_SERVER_NEW="${VPN_SERVER_TEMPLATE_NEW//$_ph/$initial_reg}"
            ;;
        *)
            die "Invalid server mode."
            ;;
    esac

    default_cert="${VPN_CERT:-/home/${TARGET_USER}/.config/openconnect/client.p12}"
    while true; do
        prompt_default VPN_CERT_NEW "Path to certificate/p12 file" "$default_cert"
        [[ -n "$VPN_CERT_NEW" ]] || die "Certificate path cannot be empty."

        [[ -f "$VPN_CERT_NEW" ]] && break

        warn "Certificate file does not currently exist: $VPN_CERT_NEW"
        read -r -p "Continue with this path [y], re-enter [n], abort [a]: " ans
        case "${ans:-n}" in
            [Yy]) break ;;
            [Aa]) die "Installation aborted." ;;
            *)    default_cert="$VPN_CERT_NEW" ;;
        esac
    done

    current_mode="${VPN_PASSWORD_MODE:-key}"
    echo
    echo "Password mode:"
    echo "  1) key  - password is for certificate/private key (--key-password)"
    echo "  2) vpn  - password is regular VPN password (--passwd-on-stdin)"
    if [[ "$current_mode" == "vpn" ]]; then
        read -r -p "Choose mode [1/2] (default 2): " mode_choice
        mode_choice="${mode_choice:-2}"
    else
        read -r -p "Choose mode [1/2] (default 1): " mode_choice
        mode_choice="${mode_choice:-1}"
    fi

    case "$mode_choice" in
        1) PASSWORD_MODE="key" ;;
        2) PASSWORD_MODE="vpn" ;;
        *) die "Invalid password mode." ;;
    esac

    prompt_secret_with_default VPN_PASSWORD_NEW "VPN password / key password" "${VPN_PASSWORD:-}"

    read -r -p "Create/update polkit rule for user '${TARGET_USER}' if polkit is available? [Y/n]: " INSTALL_POLKIT
    INSTALL_POLKIT="${INSTALL_POLKIT:-Y}"

    read -r -p "Enable service in systemd? [Y/n]: " ENABLE_SERVICE
    ENABLE_SERVICE="${ENABLE_SERVICE:-Y}"

    read -r -p "Run 'vpnctl enable' after install/update? [Y/n]: " START_AUTO
    START_AUTO="${START_AUTO:-Y}"

    VPN_SERVER="$VPN_SERVER_NEW"
    VPN_SERVER_TEMPLATE="${VPN_SERVER_TEMPLATE_NEW:-}"
    VPN_SERVER_REG="${initial_reg:-}"
    VPN_CERT="$VPN_CERT_NEW"
    VPN_PASSWORD="$VPN_PASSWORD_NEW"
    VPN_PASSWORD_MODE="$PASSWORD_MODE"
    VPN_TARGET_USER="$TARGET_USER"
}

write_env() {
    log "Writing environment file: $ENV_FILE"
    install -d -m 700 "$ENV_DIR"
    backup_if_exists "$ENV_FILE"

    {
        printf 'VPN_SERVER=%q\n' "$VPN_SERVER"
        [[ -n "$VPN_SERVER_TEMPLATE" ]] && printf 'VPN_SERVER_TEMPLATE=%q\n' "$VPN_SERVER_TEMPLATE"
        [[ -n "$VPN_SERVER_REG" ]] && printf 'VPN_SERVER_REG=%q\n' "$VPN_SERVER_REG"
        printf 'VPN_CERT=%q\n' "$VPN_CERT"
        printf 'VPN_PASSWORD=%q\n' "$VPN_PASSWORD"
        printf 'VPN_PASSWORD_MODE=%q\n' "$VPN_PASSWORD_MODE"
        printf 'VPN_TARGET_USER=%q\n' "$VPN_TARGET_USER"
        printf 'OPENCONNECT_BIN=%q\n' "$OPENCONNECT_BIN"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    ok "Environment file written."
}

# Обёртка вокруг openconnect. systemd запускает её, она подставляет ключ/пароль.
write_wrapper() {
    log "Writing wrapper: $WRAPPER"
    backup_if_exists "$WRAPPER"

    cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${VPN_SERVER:?VPN_SERVER is not set}"
: "${VPN_CERT:?VPN_CERT is not set}"
: "${VPN_PASSWORD:?VPN_PASSWORD is not set}"
: "${VPN_PASSWORD_MODE:?VPN_PASSWORD_MODE is not set}"
: "${VPN_TARGET_USER:?VPN_TARGET_USER is not set}"

OPENCONNECT_BIN="${OPENCONNECT_BIN:-}"

if [[ -z "$OPENCONNECT_BIN" ]]; then
    for p in \
        /usr/sbin/openconnect \
        /usr/bin/openconnect \
        /sbin/openconnect \
        /bin/openconnect \
        /usr/local/sbin/openconnect \
        /usr/local/bin/openconnect
    do
        if [[ -x "$p" ]]; then
            OPENCONNECT_BIN="$p"
            break
        fi
    done
fi

if [[ -z "$OPENCONNECT_BIN" ]]; then
    OPENCONNECT_BIN="$(command -v openconnect || true)"
fi

[[ -n "$OPENCONNECT_BIN" ]] || {
    echo "openconnect binary not found" >&2
    exit 127
}
[[ -x "$OPENCONNECT_BIN" ]] || {
    echo "openconnect binary is not executable: $OPENCONNECT_BIN" >&2
    exit 127
}

case "$VPN_PASSWORD_MODE" in
    key)
        exec "$OPENCONNECT_BIN" \
            --certificate="$VPN_CERT" \
            --key-password="$VPN_PASSWORD" \
            --setuid="$VPN_TARGET_USER" \
            "$VPN_SERVER"
        ;;
    vpn)
        # Пароль подаём here-string, чтобы exec заменил главный процесс,
        # а не субшелл в правой части пайпа.
        exec "$OPENCONNECT_BIN" \
            --certificate="$VPN_CERT" \
            --passwd-on-stdin \
            --setuid="$VPN_TARGET_USER" \
            "$VPN_SERVER" <<<"$VPN_PASSWORD"
        ;;
    *)
        echo "Unsupported VPN_PASSWORD_MODE: $VPN_PASSWORD_MODE" >&2
        exit 2
        ;;
esac
EOF

    chmod 755 "$WRAPPER"
    chown root:root "$WRAPPER"
    ok "Wrapper written."
}

# vpnctl это обёртка над systemctl. Файл-замок отличает ручную остановку от авто.
write_vpnctl() {
    log "Writing controller: $VPNCTL"
    backup_if_exists "$VPNCTL"

    cat > "$VPNCTL" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

unit="${SERVICE_NAME}"
lock="${LOCK_FILE}"
env_file="${ENV_FILE}"

usage() {
    cat <<'USAGE'
Usage:
  vpnctl enable             - enable auto VPN and start
  vpnctl disable            - disable auto VPN and stop
  vpnctl start              - start VPN manually
  vpnctl stop               - stop VPN manually
  vpnctl restart            - restart VPN
  vpnctl status             - show service status
  vpnctl auto               - show auto mode
  vpnctl set-server <reg>   - substitute {\$REG} in template and restart
USAGE
    exit 2
}

cmd="\${1:-}"
[[ -n "\$cmd" ]] || usage

need_root() {
    [[ "\$EUID" -eq 0 ]] || {
        echo "This action needs root." >&2
        exit 1
    }
}

case "\$cmd" in
    enable)
        need_root
        rm -f "\$lock"
        systemctl reset-failed "\$unit" >/dev/null 2>&1 || true
        exec systemctl start "\$unit"
        ;;
    disable)
        need_root
        touch "\$lock"
        exec systemctl stop "\$unit"
        ;;
    start)
        systemctl reset-failed "\$unit" >/dev/null 2>&1 || true
        exec systemctl start "\$unit"
        ;;
    stop)
        exec systemctl stop "\$unit"
        ;;
    restart)
        systemctl reset-failed "\$unit" >/dev/null 2>&1 || true
        exec systemctl restart "\$unit"
        ;;
    status)
        exec systemctl status "\$unit" --no-pager
        ;;
    auto)
        if [[ -e "\$lock" ]]; then
            echo "auto: disabled"
        else
            echo "auto: enabled"
        fi
        ;;
    set-server)
        need_root
        reg="\${2:-}"
        [[ -n "\$reg" ]] || { echo "Usage: vpnctl set-server <region>" >&2; exit 2; }
        # shellcheck disable=SC1090
        source "\$env_file" 2>/dev/null || { echo "Cannot read \$env_file" >&2; exit 1; }
        if [[ -n "\${VPN_SERVER_TEMPLATE:-}" ]]; then
            placeholder='{\$REG}'
            new_server="\${VPN_SERVER_TEMPLATE//\$placeholder/\$reg}"
        else
            new_server="\$reg"
        fi
        tmpfile="\$(mktemp)"
        grep -v -e '^VPN_SERVER=' -e '^VPN_SERVER_REG=' "\$env_file" > "\$tmpfile"
        printf 'VPN_SERVER=%q\n' "\$new_server" >> "\$tmpfile"
        printf 'VPN_SERVER_REG=%q\n' "\$reg" >> "\$tmpfile"
        chmod 600 "\$tmpfile"
        mv "\$tmpfile" "\$env_file"
        chown root:root "\$env_file"
        echo "Server set to: \$new_server"
        systemctl reset-failed "\$unit" >/dev/null 2>&1 || true
        exec systemctl restart "\$unit"
        ;;
    *)
        usage
        ;;
esac
EOF

    chmod 755 "$VPNCTL"
    chown root:root "$VPNCTL"
    ok "vpnctl written."
}

write_unit() {
    log "Writing systemd unit: $UNIT_FILE"
    backup_if_exists "$UNIT_FILE"

    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OpenConnect VPN
After=network-online.target NetworkManager.service
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${WRAPPER}

Restart=on-failure
RestartSec=10

KillSignal=SIGINT
TimeoutStopSec=20

User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$UNIT_FILE"
    chown root:root "$UNIT_FILE"
    ok "systemd unit written."
}

# Dispatcher поднимает VPN при появлении аплинка и гасит при его пропаже.
write_dispatcher() {
    log "Writing NetworkManager dispatcher: $DISPATCHER_FILE"
    install -d -m 755 "$DISPATCHER_DIR"
    backup_if_exists "$DISPATCHER_FILE"

    cat > "$DISPATCHER_FILE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

action="\${2:-}"
unit="${SERVICE_NAME}"
lock="${LOCK_FILE}"

has_uplink() {
    nmcli -t -f TYPE,STATE device status | awk -F: '
        (\$1 == "wifi" || \$1 == "ethernet") && \$2 == "connected" { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

case "\$action" in
    up|dhcp4-change|dhcp6-change|reapply|connectivity-change)
        [[ -e "\$lock" ]] && exit 0
        if has_uplink; then
            systemctl reset-failed "\$unit" >/dev/null 2>&1 || true
            systemctl start --no-block "\$unit"
        fi
        ;;
    down|pre-down)
        if ! has_uplink; then
            systemctl stop --no-block "\$unit"
        fi
        ;;
esac
EOF

    chmod 755 "$DISPATCHER_FILE"
    chown root:root "$DISPATCHER_FILE"
    ok "dispatcher written."
}

# Polkit разрешает целевому пользователю управлять только этим юнитом без sudo.
write_polkit() {
    if [[ ! "$INSTALL_POLKIT" =~ ^[Yy]$ ]]; then
        warn "Skipping polkit rule by user choice."
        return 0
    fi

    if [[ ! -d "$POLKIT_DIR" ]] || ! have_cmd pkaction; then
        warn "Polkit does not seem available. Skipping polkit rule."
        return 0
    fi

    log "Writing polkit rule: $POLKIT_FILE"
    backup_if_exists "$POLKIT_FILE"

    cat > "$POLKIT_FILE" <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user !== "${TARGET_USER}") {
        return polkit.Result.NOT_HANDLED;
    }

    if (action.id !== "org.freedesktop.systemd1.manage-units") {
        return polkit.Result.NOT_HANDLED;
    }

    var unit = action.lookup("unit");
    var verb = action.lookup("verb");

    if (unit === "${SERVICE_NAME}" &&
        (verb === "start" ||
         verb === "stop" ||
         verb === "restart")) {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
EOF

    chmod 644 "$POLKIT_FILE"
    chown root:root "$POLKIT_FILE"
    ok "polkit rule written."
}

# SELinux есть не везде (на Arch обычно нет), поэтому всё тихо пропускаем.
apply_selinux_contexts() {
    if have_cmd restorecon; then
        log "Applying SELinux contexts"
        restorecon -v "$WRAPPER" 2>/dev/null || true
        restorecon -v "$VPNCTL" 2>/dev/null || true
        restorecon -v "$DISPATCHER_FILE" 2>/dev/null || true
        restorecon -v "$UNIT_FILE" 2>/dev/null || true
        restorecon -v "$POLKIT_FILE" 2>/dev/null || true
        restorecon -Rv "$ENV_DIR" 2>/dev/null || true
    fi
}

reload_services() {
    log "Reloading systemd"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    if systemctl is-enabled NetworkManager >/dev/null 2>&1 || systemctl is-active NetworkManager >/dev/null 2>&1; then
        log "Restarting NetworkManager"
        systemctl restart NetworkManager
    else
        warn "NetworkManager is not active. Dispatcher will not work until NetworkManager is running."
    fi

    if [[ "$ENABLE_SERVICE" =~ ^[Yy]$ ]]; then
        systemctl enable "$SERVICE_NAME"
        ok "Service enabled."
    else
        warn "Service was not enabled."
    fi

    if [[ "$START_AUTO" =~ ^[Yy]$ ]]; then
        rm -f "$LOCK_FILE"
        "$VPNCTL" enable || warn "Initial 'vpnctl enable' failed. Check logs."
    else
        warn "Initial start skipped."
    fi
}

final_summary() {
    cat <<EOF

Done.

Installed/updated files:
  $ENV_FILE
  $WRAPPER
  $VPNCTL
  $UNIT_FILE
  $DISPATCHER_FILE
$( [[ -f "$POLKIT_FILE" ]] && printf '  %s\n' "$POLKIT_FILE" )

Useful commands:
  sudo vpnctl enable
  sudo vpnctl disable
  sudo vpnctl start
  sudo vpnctl stop
  sudo vpnctl status
  sudo vpnctl set-server <region>
  journalctl -u NetworkManager -u ${SERVICE_NAME} -f

Current settings:
  VPN_SERVER=$VPN_SERVER
$( [[ -n "$VPN_SERVER_TEMPLATE" ]] && printf '  VPN_SERVER_TEMPLATE=%s\n' "$VPN_SERVER_TEMPLATE" )  VPN_CERT=$VPN_CERT
  VPN_PASSWORD_MODE=$VPN_PASSWORD_MODE
  VPN_TARGET_USER=$VPN_TARGET_USER
  OPENCONNECT_BIN=${OPENCONNECT_BIN:-<not set>}

If the service was previously rate-limited by systemd, this installer already ran:
  systemctl reset-failed ${SERVICE_NAME}

EOF
}

main() {
    require_root
    cleanup_legacy
    check_and_install_requirements
    resolve_openconnect_bin
    show_existing_install_state
    choose_env_mode
    collect_settings
    resolve_openconnect_bin
    write_env
    write_wrapper
    write_vpnctl
    write_unit
    write_dispatcher
    write_polkit
    apply_selinux_contexts
    reload_services
    final_summary
}

main "$@"
