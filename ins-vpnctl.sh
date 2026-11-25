#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="openconnect-auto.service"
ENV_DIR="/etc/openconnect"
ENV_FILE="${ENV_DIR}/auto.env"
WRAPPER="/usr/local/bin/openconnect-auto.sh"
VPNCTL="/usr/local/bin/vpnctl"
# На openSUSE и части дистрибутивов /usr/local/bin не входит в secure_path у sudo.
VPNCTL_SYMLINK="/usr/bin/vpnctl"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
DISPATCHER_FILE="${DISPATCHER_DIR}/90-openconnect-auto"
POLKIT_DIR="/etc/polkit-1/rules.d"
POLKIT_FILE="${POLKIT_DIR}/49-openconnect-auto.rules"

# Постоянный каталог состояния, чтобы disable переживал перезагрузку.
STATE_DIR="/var/lib/openconnect-auto"
LOCK_FILE="${STATE_DIR}/disabled"
# Старый путь замка в /run оставлен только для миграции при обновлении.
OLD_LOCK_FILE="/run/openconnect-auto.manual-stop"

# Бэкапы складываем отдельно, чтобы не мусорить в drop-in каталогах вроде dispatcher.d.
BACKUP_ROOT="${ENV_DIR}/backups"
RUN_TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR=""

DEFAULT_UPDATE_URL="https://raw.githubusercontent.com/Efireon/vpnins/refs/heads/main/ins-vpnctl.sh"
UPDATE_URL="${VPNINS_UPDATE_URL:-$DEFAULT_UPDATE_URL}"

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

INSTALL_POLKIT="Y"
ENABLE_AUTO="Y"
START_NOW="Y"

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# При запуске через pipe (wget ... | bash) stdin это сам скрипт, а не терминал.
# Перецепляем stdin к /dev/tty только в интерактивном режиме установки.
ensure_tty() {
    if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
        exec </dev/tty
    fi
}

ensure_backup_dir() {
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="${BACKUP_ROOT}/${RUN_TIMESTAMP}"
        install -d -m 700 -o root -g root "$BACKUP_DIR"
    fi
}

backup_if_exists() {
    local file="$1"
    if [[ -e "$file" ]]; then
        ensure_backup_dir
        local dest="${BACKUP_DIR}/$(basename "$file")"
        cp -a "$file" "$dest"
        chmod 600 "$dest"
        chown root:root "$dest"
    fi
}

# Переносим старые .bak.* из системных каталогов в BACKUP_DIR, чтобы NM их больше не запускал.
cleanup_stale_backups() {
    local had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob

    local stale=(
        "${DISPATCHER_DIR}/90-openconnect-auto.bak."*
        "${DISPATCHER_DIR}/90-openconnect-paradise.bak."*
        "${UNIT_FILE}.bak."*
        "${WRAPPER}.bak."*
        "${VPNCTL}.bak."*
        "${POLKIT_FILE}.bak."*
    )

    (( had_nullglob )) || shopt -u nullglob

    [[ "${#stale[@]}" -eq 0 ]] && return 0

    ensure_backup_dir
    local legacy_baks="${BACKUP_DIR}/legacy-baks"
    install -d -m 700 -o root -g root "$legacy_baks"

    local f dest
    for f in "${stale[@]}"; do
        [[ -e "$f" ]] || continue
        dest="${legacy_baks}/$(basename "$f")"
        mv -f "$f" "$dest"
        chmod 600 "$dest"
        chown root:root "$dest"
        log "Moved stale backup $f to $dest"
    done
}

# Атомарная запись файла из stdin: сначала временный файл с umask 077, потом mv.
install_file_atomic() {
    local target="$1"
    local mode="$2"
    local owner="$3"
    local group="$4"
    local dir base tmp old_umask

    dir="$(dirname "$target")"
    base="$(basename "$target")"
    [[ -d "$dir" ]] || install -d -m 755 -o root -g root "$dir"

    old_umask="$(umask)"
    umask 077
    tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")"
    umask "$old_umask"

    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if ! chmod "$mode" "$tmp" || ! chown "${owner}:${group}" "$tmp" || ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

download_and_verify_script() {
    local url="$1"
    local dest="$2"

    if have_cmd curl; then
        curl -fsSL --connect-timeout 15 --max-time 60 -o "$dest" "$url" \
            || die "Failed to download update from: $url"
    elif have_cmd wget; then
        wget -q --timeout=15 -O "$dest" "$url" \
            || die "Failed to download update from: $url"
    else
        die "Neither curl nor wget is available."
    fi

    [[ -s "$dest" ]] || die "Downloaded update file is empty."
    head -n 1 "$dest" | grep -q '^#!/usr/bin/env bash' \
        || die "Downloaded file does not look like a bash script."
    grep -q 'SERVICE_NAME="openconnect-auto.service"' "$dest" \
        || die "Downloaded file failed vpnins marker check."
    grep -q -- '--apply-update' "$dest" \
        || die "Downloaded file does not support --apply-update."
    bash -n "$dest" || die "Downloaded script has syntax errors."
}

# Ищем остатки старого билда "paradise" и предлагаем их убрать.
cleanup_legacy() {
    local found=()
    local had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob

    [[ -f "$LEGACY_ENV" ]]        && found+=("$LEGACY_ENV")
    [[ -f "$LEGACY_WRAPPER" ]]    && found+=("$LEGACY_WRAPPER")
    [[ -f "$LEGACY_UNIT" ]]       && found+=("$LEGACY_UNIT")
    [[ -f "$LEGACY_DISPATCHER" ]] && found+=("$LEGACY_DISPATCHER")
    [[ -f "$LEGACY_POLKIT" ]]     && found+=("$LEGACY_POLKIT")
    [[ -e "$LEGACY_LOCK" ]]       && found+=("$LEGACY_LOCK")
    found+=("${LEGACY_DISPATCHER}.bak."* "${LEGACY_UNIT}.bak."*)

    (( had_nullglob )) || shopt -u nullglob

    [[ "${#found[@]}" -eq 0 ]] && return 0

    warn "Found legacy 'paradise' build artifacts:"
    local f
    for f in "${found[@]}"; do
        printf '    %s\n' "$f"
    done

    local ans=""
    read -r -p "Remove them now? [Y/n]: " ans || true
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

is_steamdeck() {
    [[ -f /etc/os-release ]] && grep -q '^ID=steamos' /etc/os-release
}

# На Steam Deck снимаем read-only с рутовой ФС только если каталог записи закрыт.
steamdeck_disable_readonly() {
    is_steamdeck || return 0
    have_cmd steamos-readonly || return 0

    if [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
        return 0
    fi

    warn "Steam Deck (SteamOS) detected."
    log "Disabling read-only filesystem"
    steamos-readonly disable </dev/null || die "Failed to disable read-only filesystem."
}

# Чиним кейринг SteamOS только тогда, когда реально нужно ставить пакеты через pacman.
steamdeck_fix_keyring() {
    is_steamdeck || return 0

    warn "Packages installed via pacman will be wiped on SteamOS system updates."
    warn "Re-run this installer after each OS update to restore openconnect."
    log "Fixing SteamOS pacman keyring"

    # holo-keyring содержит ключи Valve/GitLab CI. Для его установки временно
    # отключаем проверку подписей через копию pacman.conf.
    local _tmp_conf
    _tmp_conf="$(mktemp)"
    sed -E 's/^([[:space:]]*)SigLevel[[:space:]]*=.*/\1SigLevel = TrustAll/' /etc/pacman.conf > "$_tmp_conf"
    if ! pacman -Sy --noconfirm --config "$_tmp_conf" </dev/null \
        || ! pacman -S --needed --noconfirm --config "$_tmp_conf" holo-keyring archlinux-keyring </dev/null
    then
        rm -f "$_tmp_conf"
        die "Failed to update SteamOS keyring."
    fi
    rm -f "$_tmp_conf"

    [[ -f /etc/pacman.d/gnupg/trustdb.gpg ]] || pacman-key --init </dev/null
    pacman-key --populate archlinux holo </dev/null
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
                steamdeck_fix_keyring
                # </dev/null чтобы pacman не съел stdin и collect_settings смог читать.
                pacman -S --needed --noconfirm "${pkgs[@]}" </dev/null
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

    steamdeck_disable_readonly

    have_cmd openconnect || [[ -x /usr/sbin/openconnect ]] || [[ -x /usr/bin/openconnect ]] || missing+=("openconnect")
    have_cmd nmcli || missing+=("nmcli")
    have_cmd systemctl || missing+=("systemd")
    have_cmd awk || missing+=("awk")

    if [[ "${#missing[@]}" -eq 0 ]]; then
        ok "Required commands are already present."
        return 0
    fi

    warn "Missing requirements: ${missing[*]}"
    local ans=""
    read -r -p "Try to install missing packages automatically? [Y/n]: " ans || true
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Nn]$ ]] && die "Missing packages were not installed."

    local pkgs=() item
    for item in "${missing[@]}"; do
        case "${pm}:${item}" in
            *:openconnect) pkgs+=("openconnect") ;;
            dnf:nmcli|zypper:nmcli) pkgs+=("NetworkManager") ;;
            apt:nmcli) pkgs+=("network-manager") ;;
            pacman:nmcli) pkgs+=("networkmanager") ;;
            *:awk) pkgs+=("gawk") ;;
            *:systemd) die "systemd is required and cannot be auto-installed here." ;;
            none:*) die "Cannot auto-install dependencies on this system." ;;
        esac
    done

    install_missing_packages "$pm" "${pkgs[@]}"

    have_cmd systemctl || die "systemctl is still missing after installation."
    have_cmd nmcli || die "nmcli is still missing after installation."
    have_cmd awk || die "awk is still missing after installation."

    resolve_openconnect_bin
    ok "Required packages are installed."
}

# Ищем бинарь openconnect в PATH и в типичных системных путях.
resolve_openconnect_bin_soft() {
    local candidates=()

    [[ -n "${OPENCONNECT_BIN:-}" ]] && candidates+=("$OPENCONNECT_BIN")

    if have_cmd openconnect; then
        candidates+=("$(command -v openconnect)")
    fi

    local p
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

    for p in "${candidates[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -x "$p" ]] || continue
        OPENCONNECT_BIN="$p"
        ok "Using openconnect binary: $OPENCONNECT_BIN"
        return 0
    done

    return 1
}

resolve_openconnect_bin() {
    resolve_openconnect_bin_soft || die "openconnect binary not found. Checked PATH and common system paths."
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
    local value=""

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value || die "Input closed."
        value="${value:-$default}"
    else
        read -r -p "$prompt: " value || die "Input closed."
    fi

    printf -v "$var_name" '%s' "$value"
}

# Читаем секрет без эха. Если секрет уже есть в env, предлагаем оставить его.
prompt_secret_with_default() {
    local var_name="$1"
    local prompt="$2"
    local current="${3:-}"
    local value="" keep=""

    if [[ -n "$current" ]]; then
        read -r -p "$prompt: keep existing secret? [Y/n]: " keep || die "Input closed."
        keep="${keep:-Y}"
        if [[ ! "$keep" =~ ^[Nn]$ ]]; then
            printf -v "$var_name" '%s' "$current"
            return 0
        fi
    fi

    read -r -s -p "$prompt: " value || die "Input closed."
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
        local ans=""
        read -r -p "Use existing env as base? [Y/n]: " ans || true
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
    local default_user target_home target_group default_cert current_mode
    local TARGET_USER="" VPN_SERVER_NEW="" VPN_SERVER_TEMPLATE_NEW="" initial_reg=""
    local VPN_CERT_NEW="" PASSWORD_MODE="" VPN_PASSWORD_NEW=""

    default_user="${VPN_TARGET_USER:-${SUDO_USER:-}}"
    if [[ -z "$default_user" || "$default_user" == "root" ]]; then
        default_user="$(logname 2>/dev/null || true)"
    fi
    # root плохой target для --setuid, поэтому сбрасываем. Если никого не нашли,
    # оставляем пусто и спросим явно.
    [[ "$default_user" == "root" ]] && default_user=""

    while true; do
        prompt_default TARGET_USER "Target local user for --setuid" "$default_user"
        id "$TARGET_USER" >/dev/null 2>&1 && break
        warn "User '$TARGET_USER' does not exist. Try again."
        default_user="$TARGET_USER"
    done

    target_home="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
    [[ -n "$target_home" ]] || target_home="/home/${TARGET_USER}"
    target_group="$(id -gn "$TARGET_USER" 2>/dev/null || printf '%s' "$TARGET_USER")"

    local server_mode_default=1
    [[ -n "${VPN_SERVER_TEMPLATE:-}" ]] && server_mode_default=2

    local server_mode_choice=""
    while true; do
        echo
        echo 'VPN server mode:'
        echo '  1) static   - one fixed URL'
        echo '  2) template - URL with {$REG} placeholder (switch later with vpnctl set-server)'
        read -r -p "Choose [1/2] (default $server_mode_default): " server_mode_choice || die "Input closed."
        server_mode_choice="${server_mode_choice:-$server_mode_default}"
        case "$server_mode_choice" in
            1)
                while true; do
                    prompt_default VPN_SERVER_NEW "VPN server URL" "${VPN_SERVER:-}"
                    [[ -n "$VPN_SERVER_NEW" ]] && break
                    warn "URL cannot be empty."
                done
                break
                ;;
            2)
                while true; do
                    prompt_default VPN_SERVER_TEMPLATE_NEW \
                        'Server template, e.g. {$REG}.nixen.online/?path' \
                        "${VPN_SERVER_TEMPLATE:-}"
                    [[ -n "$VPN_SERVER_TEMPLATE_NEW" ]] && break
                    warn "Template cannot be empty."
                done
                while true; do
                    prompt_default initial_reg 'Initial {$REG} value' "${VPN_SERVER_REG:-}"
                    [[ -n "$initial_reg" ]] && break
                    warn "Region value cannot be empty."
                done
                local _ph='{$REG}'
                VPN_SERVER_NEW="${VPN_SERVER_TEMPLATE_NEW//$_ph/$initial_reg}"
                break
                ;;
            *)
                warn "Enter 1 or 2."
                ;;
        esac
    done

    local dest_cert="${target_home}/.config/openconnect/client.p12"
    default_cert="${VPN_CERT:-$dest_cert}"
    local cert_selected=false
    local do_search=""

    read -r -p "Search for certificates (*_modern.p12, *_legacy.p12) in ${target_home}/? [Y/n]: " do_search || true
    do_search="${do_search:-Y}"

    if [[ "$do_search" =~ ^[Yy]$ ]]; then
        local found_certs=()
        mapfile -t found_certs < <(find "${target_home}/" \
            \( -name "*_modern.p12" -o -name "*_legacy.p12" \) 2>/dev/null | sort)

        if [[ "${#found_certs[@]}" -eq 0 ]]; then
            warn "No certificates found. Enter path manually."
        else
            echo "Found certificates:"
            local i
            for (( i=0; i<${#found_certs[@]}; i++ )); do
                printf '  %d) %s\n' "$((i+1))" "${found_certs[$i]}"
            done
            echo "  0) Enter manually"

            local cert_choice=""
            while true; do
                read -r -p "Choose [0-${#found_certs[@]}]: " cert_choice || die "Input closed."
                cert_choice="${cert_choice:-}"
                [[ "$cert_choice" == "0" ]] && break
                if [[ "$cert_choice" =~ ^[0-9]+$ ]] \
                    && (( cert_choice >= 1 && cert_choice <= ${#found_certs[@]} )); then
                    local selected="${found_certs[$((cert_choice-1))]}"
                    if [[ "$selected" == "$dest_cert" ]]; then
                        VPN_CERT_NEW="$dest_cert"
                    elif [[ -f "$dest_cert" ]]; then
                        local overwrite_ans=""
                        read -r -p "Overwrite existing $dest_cert with $selected? [Y/n]: " overwrite_ans || true
                        overwrite_ans="${overwrite_ans:-Y}"
                        if [[ "$overwrite_ans" =~ ^[Yy]$ ]]; then
                            backup_if_exists "$dest_cert"
                            install -d -m 700 -o "$TARGET_USER" -g "$target_group" "$(dirname "$dest_cert")"
                            cp "$selected" "$dest_cert"
                            chown "${TARGET_USER}:${target_group}" "$dest_cert"
                            chmod 600 "$dest_cert"
                            ok "Certificate copied to $dest_cert"
                            VPN_CERT_NEW="$dest_cert"
                        else
                            VPN_CERT_NEW="$selected"
                        fi
                    else
                        install -d -m 700 -o "$TARGET_USER" -g "$target_group" "$(dirname "$dest_cert")"
                        cp "$selected" "$dest_cert"
                        chown "${TARGET_USER}:${target_group}" "$dest_cert"
                        chmod 600 "$dest_cert"
                        ok "Certificate copied to $dest_cert"
                        VPN_CERT_NEW="$dest_cert"
                    fi
                    cert_selected=true
                    break
                fi
                warn "Enter a number between 0 and ${#found_certs[@]}."
            done
        fi
    fi

    if ! "$cert_selected"; then
        local ans=""
        while true; do
            prompt_default VPN_CERT_NEW "Path to certificate/p12 file" "$default_cert"
            [[ -n "$VPN_CERT_NEW" ]] || { warn "Path cannot be empty."; continue; }
            [[ -f "$VPN_CERT_NEW" ]] && break
            warn "Certificate file does not currently exist: $VPN_CERT_NEW"
            read -r -p "Continue with this path [y], re-enter [n], abort [a]: " ans || die "Input closed."
            case "${ans:-n}" in
                [Yy]) break ;;
                [Aa]) die "Installation aborted." ;;
                *)    default_cert="$VPN_CERT_NEW" ;;
            esac
        done
    fi

    current_mode="${VPN_PASSWORD_MODE:-key}"
    local mode_choice=""
    while true; do
        echo
        echo "Password mode:"
        echo "  1) key  - password is for certificate/private key (--key-password)"
        echo "  2) vpn  - password is regular VPN password (--passwd-on-stdin)"
        if [[ "$current_mode" == "vpn" ]]; then
            read -r -p "Choose mode [1/2] (default 2): " mode_choice || die "Input closed."
            mode_choice="${mode_choice:-2}"
        else
            read -r -p "Choose mode [1/2] (default 1): " mode_choice || die "Input closed."
            mode_choice="${mode_choice:-1}"
        fi
        case "$mode_choice" in
            1) PASSWORD_MODE="key"; break ;;
            2) PASSWORD_MODE="vpn"; break ;;
            *) warn "Enter 1 or 2." ;;
        esac
    done

    prompt_secret_with_default VPN_PASSWORD_NEW "VPN password / key password" "${VPN_PASSWORD:-}"

    read -r -p "Create/update polkit rule for user '${TARGET_USER}' if polkit is available? [Y/n]: " INSTALL_POLKIT || true
    INSTALL_POLKIT="${INSTALL_POLKIT:-Y}"

    read -r -p "Enable auto-start on boot and network reconnect? [Y/n]: " ENABLE_AUTO || true
    ENABLE_AUTO="${ENABLE_AUTO:-Y}"

    local start_default="Y"
    local start_prompt="Start VPN now? [Y/n]: "
    if [[ "$ENABLE_AUTO" =~ ^[Nn]$ ]]; then
        start_default="N"
        start_prompt="Start VPN now? [y/N]: "
    fi
    read -r -p "$start_prompt" START_NOW || true
    START_NOW="${START_NOW:-$start_default}"

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
    install -d -m 700 -o root -g root "$ENV_DIR"
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
    } | install_file_atomic "$ENV_FILE" 600 root root

    ok "Environment file written."
}

# Обёртка вокруг openconnect. systemd запускает её, она подставляет ключ/пароль.
write_wrapper() {
    log "Writing wrapper: $WRAPPER"
    backup_if_exists "$WRAPPER"

    {
        cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE}"
EOF
        cat <<'EOF'
# Читаем env через bash, а не systemd EnvironmentFile=, чтобы спецсимволы в пароле работали без потерь.
if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

: "${VPN_SERVER:?VPN_SERVER is not set}"
: "${VPN_CERT:?VPN_CERT is not set}"
: "${VPN_PASSWORD_MODE:?VPN_PASSWORD_MODE is not set}"
: "${VPN_TARGET_USER:?VPN_TARGET_USER is not set}"

[[ -f "$VPN_CERT" ]] || {
    echo "Certificate file not found: $VPN_CERT" >&2
    exit 2
}

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
        cmd=(
            "$OPENCONNECT_BIN"
            --certificate="$VPN_CERT"
            --setuid="$VPN_TARGET_USER"
        )
        [[ -n "${VPN_PASSWORD:-}" ]] && cmd+=(--key-password="$VPN_PASSWORD")
        cmd+=("$VPN_SERVER")
        exec "${cmd[@]}"
        ;;
    vpn)
        : "${VPN_PASSWORD:?VPN_PASSWORD is not set}"
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
    } | install_file_atomic "$WRAPPER" 755 root root

    ok "Wrapper written."
}

# vpnctl это обёртка над systemctl. Постоянный замок и состояние юнита задают авторежим.
write_vpnctl() {
    log "Writing controller: $VPNCTL"
    backup_if_exists "$VPNCTL"

    {
        cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

unit="${SERVICE_NAME}"
state_dir="${STATE_DIR}"
lock="${LOCK_FILE}"
old_lock="${OLD_LOCK_FILE}"
env_file="${ENV_FILE}"
default_update_url="${DEFAULT_UPDATE_URL}"
EOF
        cat <<'EOF'

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
  vpnctl set-server <reg>   - substitute {$REG} in template and restart
  vpnctl update             - update vpnctl, wrapper, unit and dispatcher
USAGE
    exit 2
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage

need_root() {
    [[ "$EUID" -eq 0 ]] || {
        echo "This action needs root." >&2
        exit 1
    }
}

is_auto_enabled() {
    [[ ! -e "$lock" ]] && [[ ! -e "$old_lock" ]] && systemctl is-enabled --quiet "$unit" 2>/dev/null
}

print_auto_state() {
    if is_auto_enabled; then
        echo "auto: enabled"
    else
        echo "auto: disabled"
    fi
}

case "$cmd" in
    enable)
        need_root
        rm -f "$lock" "$old_lock"
        systemctl enable "$unit" >/dev/null 2>&1 || true
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        exec systemctl start "$unit"
        ;;
    disable)
        need_root
        install -d -m 755 -o root -g root "$state_dir"
        : > "$lock"
        chmod 644 "$lock"
        rm -f "$old_lock"
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl stop "$unit"
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        ;;
    start)
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        exec systemctl start "$unit"
        ;;
    stop)
        exec systemctl stop "$unit"
        ;;
    restart)
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        exec systemctl restart "$unit"
        ;;
    status)
        print_auto_state
        exec systemctl status "$unit" --no-pager
        ;;
    auto)
        print_auto_state
        ;;
    set-server)
        need_root
        reg="${2:-}"
        [[ -n "$reg" ]] || { echo "Usage: vpnctl set-server <region>" >&2; exit 2; }
        # shellcheck disable=SC1090
        source "$env_file" 2>/dev/null || { echo "Cannot read $env_file" >&2; exit 1; }
        if [[ -n "${VPN_SERVER_TEMPLATE:-}" ]]; then
            placeholder='{$REG}'
            new_server="${VPN_SERVER_TEMPLATE//$placeholder/$reg}"
        else
            new_server="$reg"
        fi

        env_dir="$(dirname "$env_file")"
        env_base="$(basename "$env_file")"
        old_umask="$(umask)"
        umask 077
        tmpfile="$(mktemp "${env_dir}/.${env_base}.tmp.XXXXXX")"
        umask "$old_umask"
        trap 'rm -f "${tmpfile:-}"' EXIT

        {
            grep -v -e '^VPN_SERVER=' -e '^VPN_SERVER_REG=' "$env_file" || true
            printf 'VPN_SERVER=%q\n' "$new_server"
            [[ -n "${VPN_SERVER_TEMPLATE:-}" ]] && printf 'VPN_SERVER_REG=%q\n' "$reg"
        } > "$tmpfile"
        chmod 600 "$tmpfile"
        chown root:root "$tmpfile"
        mv -f "$tmpfile" "$env_file"
        trap - EXIT

        echo "Server set to: $new_server"
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            exec systemctl restart "$unit"
        elif is_auto_enabled; then
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            exec systemctl start "$unit"
        else
            echo "Config updated; service stays stopped because auto VPN is disabled."
        fi
        ;;
    update)
        need_root
        update_url="${VPNINS_UPDATE_URL:-$default_update_url}"
        tmp_script="$(mktemp /tmp/vpnctl-update.XXXXXX)"
        trap 'rm -f "${tmp_script:-}"' EXIT

        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp_script" "$update_url"
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_script" "$update_url"
        else
            echo "Neither curl nor wget is available." >&2
            exit 1
        fi

        [[ -s "$tmp_script" ]] || { echo "Downloaded update file is empty." >&2; exit 1; }
        head -n 1 "$tmp_script" | grep -q '^#!/usr/bin/env bash' || {
            echo "Downloaded file does not look like a bash script." >&2
            exit 1
        }
        grep -q 'SERVICE_NAME="openconnect-auto.service"' "$tmp_script" || {
            echo "Downloaded file failed vpnins marker check." >&2
            exit 1
        }
        grep -q -- '--apply-update' "$tmp_script" || {
            echo "Downloaded file does not support --apply-update." >&2
            exit 1
        }
        bash -n "$tmp_script" || { echo "Downloaded script has syntax errors." >&2; exit 1; }

        bash "$tmp_script" --apply-update
        ;;
    *)
        usage
        ;;
esac
EOF
    } | install_file_atomic "$VPNCTL" 755 root root

    ok "vpnctl written."

    if [[ -n "$VPNCTL_SYMLINK" && "$VPNCTL_SYMLINK" != "$VPNCTL" ]]; then
        local symlink_dir
        symlink_dir="$(dirname "$VPNCTL_SYMLINK")"
        if [[ -d "$symlink_dir" && -w "$symlink_dir" ]]; then
            if [[ ! -e "$VPNCTL_SYMLINK" || -L "$VPNCTL_SYMLINK" ]]; then
                ln -sfn "$VPNCTL" "$VPNCTL_SYMLINK"
                ok "Symlink created: $VPNCTL_SYMLINK (target: $VPNCTL)"
            else
                warn "Skipping symlink $VPNCTL_SYMLINK: non-symlink file already exists."
            fi
        else
            warn "Skipping symlink $VPNCTL_SYMLINK: directory is not writable."
        fi
    fi
}

write_unit() {
    log "Writing systemd unit: $UNIT_FILE"
    backup_if_exists "$UNIT_FILE"

    install_file_atomic "$UNIT_FILE" 644 root root <<EOF
[Unit]
Description=OpenConnect VPN
After=network-online.target NetworkManager.service
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
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

    ok "systemd unit written."
}

# Dispatcher поднимает VPN при появлении физического аплинка и гасит при его пропаже.
write_dispatcher() {
    log "Writing NetworkManager dispatcher: $DISPATCHER_FILE"
    install -d -m 755 -o root -g root "$DISPATCHER_DIR"
    backup_if_exists "$DISPATCHER_FILE"

    {
        cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

iface="\${1:-}"
action="\${2:-}"
unit="${SERVICE_NAME}"
lock="${LOCK_FILE}"
old_lock="${OLD_LOCK_FILE}"
EOF
        cat <<'EOF'

# Автоподключение разрешено только если нет замка и юнит включён в systemd.
is_auto_enabled() {
    [[ ! -e "$lock" ]] && [[ ! -e "$old_lock" ]] && systemctl is-enabled --quiet "$unit" 2>/dev/null
}

is_uplink_iface() {
    local dev="${1:-}"
    [[ -n "$dev" && "$dev" != "none" ]] || return 1
    case "$dev" in
        lo|tun*|tap*|wg*|vpn*|docker*|veth*|br-*|virbr*|tailscale*)
            return 1
            ;;
    esac
    nmcli -t -f DEVICE,TYPE device status | awk -F: -v dev="$dev" '
        $1 == dev && ($2 == "wifi" || $2 == "ethernet" || $2 == "gsm") { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

has_uplink() {
    nmcli -t -f TYPE,STATE device status | awk -F: '
        ($1 == "wifi" || $1 == "ethernet" || $1 == "gsm") && $2 == "connected" { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

has_other_uplink() {
    local exclude="${1:-}"
    nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: -v ex="$exclude" '
        $1 != ex && ($2 == "wifi" || $2 == "ethernet" || $2 == "gsm") && $3 == "connected" { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

case "$action" in
    up|dhcp4-change|dhcp6-change|reapply)
        is_auto_enabled || exit 0
        is_uplink_iface "$iface" || exit 0
        if has_uplink && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            systemctl start --no-block "$unit"
        fi
        ;;
    connectivity-change)
        # Поднимаем на connectivity-change только из failed (например, после captive portal),
        # чтобы ручной vpnctl stop не отменялся фоновой проверкой сети.
        is_auto_enabled || exit 0
        [[ "${CONNECTIVITY_STATE:-}" == "full" ]] || exit 0
        if has_uplink && systemctl is-failed --quiet "$unit" 2>/dev/null; then
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            systemctl start --no-block "$unit"
        fi
        ;;
    down|pre-down)
        is_uplink_iface "$iface" || exit 0
        if ! has_other_uplink "$iface"; then
            systemctl stop --no-block "$unit"
        fi
        ;;
esac
EOF
    } | install_file_atomic "$DISPATCHER_FILE" 755 root root

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

    install_file_atomic "$POLKIT_FILE" 644 root root <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user !== "${VPN_TARGET_USER}") {
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
         verb === "restart" ||
         verb === "reset-failed")) {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
EOF

    ok "polkit rule written."
}

# SELinux есть не везде (на Arch обычно нет), поэтому всё тихо пропускаем.
apply_selinux_contexts() {
    if have_cmd restorecon; then
        log "Applying SELinux contexts"
        restorecon -v "$WRAPPER" 2>/dev/null || true
        restorecon -v "$VPNCTL" 2>/dev/null || true
        [[ -L "$VPNCTL_SYMLINK" ]] && restorecon -v "$VPNCTL_SYMLINK" 2>/dev/null || true
        restorecon -v "$DISPATCHER_FILE" 2>/dev/null || true
        restorecon -v "$UNIT_FILE" 2>/dev/null || true
        [[ -f "$POLKIT_FILE" ]] && restorecon -v "$POLKIT_FILE" 2>/dev/null || true
        restorecon -Rv "$ENV_DIR" 2>/dev/null || true
        [[ -d "$STATE_DIR" ]] && restorecon -Rv "$STATE_DIR" 2>/dev/null || true
    fi
}

set_auto_disabled_state() {
    install -d -m 755 -o root -g root "$STATE_DIR"
    : > "$LOCK_FILE"
    chmod 644 "$LOCK_FILE"
    rm -f "$OLD_LOCK_FILE"
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

set_auto_enabled_state() {
    rm -f "$LOCK_FILE" "$OLD_LOCK_FILE"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

reload_services() {
    log "Reloading systemd"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        warn "NetworkManager is not active. Dispatcher will not work until NetworkManager is running."
    fi

    if [[ "$ENABLE_AUTO" =~ ^[Yy]$ ]]; then
        set_auto_enabled_state
        ok "Auto-start enabled."
    else
        set_auto_disabled_state
        warn "Auto-start disabled."
    fi

    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl start "$SERVICE_NAME" || warn "Initial start failed. Check logs."
    else
        warn "Initial start skipped."
    fi
}

final_summary() {
    printf '\nDone.\n\nInstalled/updated files:\n'
    printf '  %s\n' "$ENV_FILE" "$WRAPPER" "$VPNCTL" "$UNIT_FILE" "$DISPATCHER_FILE"
    [[ -L "$VPNCTL_SYMLINK" ]] && printf '  %s\n' "$VPNCTL_SYMLINK"
    [[ -f "$POLKIT_FILE" ]] && printf '  %s\n' "$POLKIT_FILE"

    cat <<EOF

Useful commands:
  sudo vpnctl enable
  sudo vpnctl disable
  sudo vpnctl start
  sudo vpnctl stop
  sudo vpnctl status
  sudo vpnctl auto
  sudo vpnctl set-server <region>
  sudo vpnctl update
  journalctl -u NetworkManager -u ${SERVICE_NAME} -f

Current settings:
  VPN_SERVER=${VPN_SERVER}
EOF
    [[ -n "$VPN_SERVER_TEMPLATE" ]] && printf '  VPN_SERVER_TEMPLATE=%s\n' "$VPN_SERVER_TEMPLATE"
    printf '  VPN_CERT=%s\n' "$VPN_CERT"
    printf '  VPN_PASSWORD_MODE=%s\n' "$VPN_PASSWORD_MODE"
    printf '  VPN_TARGET_USER=%s\n' "$VPN_TARGET_USER"
    printf '  OPENCONNECT_BIN=%s\n\n' "${OPENCONNECT_BIN:-<not set>}"
}

# Применяет обновление к уже установленной системе, не трогая auto.env и сертификаты.
apply_update() {
    require_root

    [[ -f "$ENV_FILE" ]] || die "Existing configuration not found: $ENV_FILE. Run installer interactively first."
    load_env_file "$ENV_FILE" || die "Failed to load configuration: $ENV_FILE"

    : "${VPN_SERVER:?VPN_SERVER is missing in $ENV_FILE}"
    : "${VPN_CERT:?VPN_CERT is missing in $ENV_FILE}"
    : "${VPN_PASSWORD_MODE:?VPN_PASSWORD_MODE is missing in $ENV_FILE}"
    : "${VPN_TARGET_USER:?VPN_TARGET_USER is missing in $ENV_FILE}"

    if ! resolve_openconnect_bin_soft; then
        warn "openconnect binary not found; keeping current OPENCONNECT_BIN setting."
    fi

    local was_active=false
    local was_disabled=false
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && was_active=true

    if [[ -e "$LOCK_FILE" || -e "$OLD_LOCK_FILE" ]] || ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        was_disabled=true
    fi

    INSTALL_POLKIT="N"
    [[ -f "$POLKIT_FILE" ]] && INSTALL_POLKIT="Y"

    steamdeck_disable_readonly
    cleanup_stale_backups

    write_wrapper
    write_vpnctl
    write_unit
    write_dispatcher
    write_polkit
    apply_selinux_contexts

    log "Reloading systemd"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    if "$was_disabled"; then
        set_auto_disabled_state
    else
        set_auto_enabled_state
    fi

    if "$was_active"; then
        log "Restarting active service: $SERVICE_NAME"
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl restart "$SERVICE_NAME" || warn "Failed to restart ${SERVICE_NAME}. Check logs."
    fi

    ok "Update applied. Configuration preserved: $ENV_FILE"
    if "$was_disabled"; then
        log "Auto mode: disabled"
    else
        log "Auto mode: enabled"
    fi
}

self_update() {
    require_root

    local tmp_script
    tmp_script="$(mktemp /tmp/ins-vpnctl-update.XXXXXX)"
    # Очищаем временный файл при любом выходе из функции обновления.
    if ! (
        set -Eeuo pipefail
        download_and_verify_script "$UPDATE_URL" "$tmp_script"
    ); then
        rm -f "$tmp_script"
        exit 1
    fi

    local self_path=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    fi

    if [[ -n "$self_path" && -f "$self_path" && "$self_path" != /dev/fd/* && "$self_path" != /proc/self/fd/* ]]; then
        if cmp -s "$tmp_script" "$self_path"; then
            ok "Installer script is already up to date: $self_path"
        else
            local self_dir self_base self_tmp old_umask
            self_dir="$(dirname "$self_path")"
            self_base="$(basename "$self_path")"
            old_umask="$(umask)"
            umask 077
            self_tmp="$(mktemp "${self_dir}/.${self_base}.tmp.XXXXXX")"
            umask "$old_umask"

            if ! cat "$tmp_script" > "$self_tmp"; then
                rm -f "$self_tmp" "$tmp_script"
                die "Failed to copy updated installer script."
            fi
            if ! chmod --reference="$self_path" "$self_tmp" 2>/dev/null && ! chmod 755 "$self_tmp"; then
                rm -f "$self_tmp" "$tmp_script"
                die "Failed to set permissions on updated installer script."
            fi
            chown --reference="$self_path" "$self_tmp" 2>/dev/null || true
            if ! mv -f "$self_tmp" "$self_path"; then
                rm -f "$self_tmp" "$tmp_script"
                die "Failed to replace installer script: $self_path"
            fi
            ok "Updated installer script: $self_path"
        fi
    fi

    if [[ -f "$ENV_FILE" ]]; then
        if ! bash "$tmp_script" --apply-update; then
            rm -f "$tmp_script"
            exit 1
        fi
    else
        log "No existing configuration at $ENV_FILE; only installer script was updated."
    fi

    rm -f "$tmp_script"
}

usage() {
    cat <<'USAGE'
Usage:
  ins-vpnctl.sh                 - interactive install or reconfigure
  ins-vpnctl.sh update          - download latest script, self-replace and update installed files
  ins-vpnctl.sh --update        - same as update
  ins-vpnctl.sh --apply-update  - update wrapper, vpnctl, unit and dispatcher keeping auto.env
  ins-vpnctl.sh -h | --help     - show this help
USAGE
}

main() {
    local mode="${1:-}"

    case "$mode" in
        -h|--help)
            usage
            return 0
            ;;
        --apply-update)
            apply_update
            return 0
            ;;
        update|--update)
            self_update
            return 0
            ;;
        "")
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac

    ensure_tty
    require_root
    cleanup_legacy
    cleanup_stale_backups
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

if [[ -z "${VPNINS_SKIP_MAIN:-}" ]]; then
    main "$@"
fi
