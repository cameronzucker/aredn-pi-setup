#!/bin/bash
#
# pi5-greenfield-setup.sh
# Post-imaging setup for Raspberry Pi 5 on Raspberry Pi OS Trixie (Desktop, arm64)
#
# What this does (roughly in order):
#   1. Bootstraps gum (Charm.sh) for interactive UI
#   2. Component picker — choose which software to install
#   3. Hotspot config (if selected) — SSID, band, channel (auto/scan/manual), PSK
#   4. Updates apt & installs prerequisites
#   5. Enables VNC, I2C, UART via raspi-config (non-interactive)
#   6. Writes usb_max_current_enable=1 and dtparam=pciex1_gen=3 to config.txt
#   7. Disables fake-hwclock (Pi 5 has a native RTC powered by CR2032 on the HAT)
#   8. Configures RTC battery charging (prompts for battery type)
#   9. Configures UFW firewall (always — runs early to close exposure window)
#  10. Installs selected components
#  11. Offers to run `tailscale up` and reboot at the end
#
# Run with: sudo ./pi5-greenfield-setup.sh
# Re-running is safe — most steps are idempotent.

set -o pipefail

# ============================================================================
# Output helpers — require gum (bootstrapped below)
# ============================================================================
say()  { gum style --foreground 4 "==> $*"; }
ok()   { gum style --foreground 2 " ✓  $*"; }
warn() { gum style --foreground 3 " ⚠  $*" >&2; }
err()  { gum style --foreground 1 " ✗  $*" >&2; }
hr()   { gum style --foreground 8 "────────────────────────────────────────────────────────────"; }

FAILURES=()
record_fail() { FAILURES+=("$1"); }

# ============================================================================
# Pre-flight checks (plain printf — gum not yet available)
# ============================================================================
if [[ $EUID -ne 0 ]]; then
    printf '[err] This script must be run with sudo.\n' >&2
    exit 1
fi

if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
    printf '[err] Run with '"'"'sudo ./pi5-greenfield-setup.sh'"'"' as a normal user,\n' >&2
    printf '[err] not directly as root — we need to configure user-level settings.\n' >&2
    exit 1
fi

USER_NAME="$SUDO_USER"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

if [[ ! -d "$USER_HOME" ]]; then
    printf '[err] Could not determine home directory for user %s\n' "$USER_NAME" >&2
    exit 1
fi

as_user() { sudo -u "$USER_NAME" -H "$@"; }

# ============================================================================
# Bootstrap gum (Charm.sh)
# ============================================================================
_bootstrap_gum() {
    command -v gum >/dev/null 2>&1 && return 0
    printf 'Installing gum (required for interactive UI)...\n'
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gum \
            >/dev/null 2>&1; then
        return 0
    fi
    printf 'Not found in apt — adding Charm repo...\n'
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
        || { printf '[err] Could not fetch Charm repo key\n' >&2; exit 1; }
    printf 'deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *\n' \
        > /etc/apt/sources.list.d/charm.list
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y gum \
        || { printf '[err] Could not install gum\n' >&2; exit 1; }
}
_bootstrap_gum

# ============================================================================
# Pi / OS checks
# ============================================================================
if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null \
   && ! grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null; then
    warn "This doesn't look like a Raspberry Pi 5."
    gum confirm "Continue anyway?" || exit 1
fi

if ! grep -q "trixie" /etc/os-release 2>/dev/null; then
    warn "This doesn't appear to be Debian Trixie."
    gum confirm "Continue anyway?" || exit 1
fi

# ============================================================================
# Shared helpers
# ============================================================================

# Write or update a key=value line in a config file.
# Uses ${line%=*} for key extraction so compound keys like dtparam=rtc_bbat_voltage
# are matched precisely, avoiding clobber of other dtparam= lines.
_config_set() {
    local file="$1" line="$2"
    local key="${line%=*}"
    local re_key
    re_key=$(printf '%s' "$key" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if grep -qE "^\s*${re_key}=" "$file"; then
        sed -i -E "s|^\s*${re_key}=.*|${line}|" "$file"
    else
        echo "$line" >> "$file"
    fi
}

# Scan nearby WiFi networks and display a channel congestion table.
# Outputs the recommended channel number on stdout; table goes to stderr.
# Args: band_ghz — "2.4" or "5"
_wifi_scan_channels() {
    local band_ghz="$1"

    # Bring wlan0 up temporarily if needed
    ip link set wlan0 up 2>/dev/null || true

    # Scan into a temp file so we can capture output while showing a spinner
    local tmp; tmp=$(mktemp)
    gum spin --spinner dot --title "Scanning nearby networks…" -- \
        sh -c "iw dev wlan0 scan 2>/dev/null > '$tmp'" 2>/dev/null || true
    local scan_raw; scan_raw=$(cat "$tmp"); rm -f "$tmp"

    # Parse frequencies → per-channel AP counts
    declare -A ch_count
    local freq ch total=0
    while IFS= read -r freq; do
        if [[ "$band_ghz" == "2.4" ]] && (( freq >= 2412 && freq <= 2484 )); then
            ch=$(( (freq - 2407) / 5 ))
            (( ch_count[$ch]++ )) || true; (( total++ )) || true
        elif [[ "$band_ghz" == "5" ]] && (( freq >= 5170 && freq <= 5885 )); then
            ch=$(( (freq - 5000) / 5 ))
            (( ch_count[$ch]++ )) || true; (( total++ )) || true
        fi
    done < <(printf '%s\n' "$scan_raw" | awk '/freq:/ { print $2 }')

    local max_count=1
    for ch in "${!ch_count[@]}"; do
        (( ch_count[$ch] > max_count )) && max_count=${ch_count[$ch]}
    done

    # Build table and pick recommended channel
    local table="" recommended="" min_seen=99999
    local n filled bar i note

    if [[ "$band_ghz" == "2.4" ]]; then
        local preferred=(1 6 11)
        local all_chs=(1 2 3 4 5 6 7 8 9 10 11)

        # Least busy among non-overlapping channels
        for ch in "${preferred[@]}"; do
            n=${ch_count[$ch]:-0}
            (( n < min_seen )) && { min_seen=$n; recommended=$ch; }
        done

        for ch in "${all_chs[@]}"; do
            n=${ch_count[$ch]:-0}
            filled=$(( max_count > 0 ? n * 10 / max_count : 0 ))
            bar=""; for (( i=0; i<10; i++ )); do
                (( i < filled )) && bar+="▓" || bar+="░"
            done
            local pref=" "
            for p in "${preferred[@]}"; do [[ "$p" == "$ch" ]] && pref="*"; done
            note=""; [[ "$ch" == "$recommended" ]] && note="  ← recommended"
            table+=$(printf ' Ch %2d%s  %s  %2d AP%s%s\n' \
                "$ch" "$pref" "$bar" "$n" \
                "$([[ $n -ne 1 ]] && printf 's')" "$note")
        done
        table+=$'\n * = non-overlapping channels — prefer 1, 6, or 11 to minimise interference'

    else  # 5 GHz
        local non_dfs=(36 40 44 48 149 153 157 161 165)
        local dfs=(52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144)

        for ch in "${non_dfs[@]}"; do
            n=${ch_count[$ch]:-0}
            (( n < min_seen )) && { min_seen=$n; recommended=$ch; }
        done

        for ch in "${non_dfs[@]}" "${dfs[@]}"; do
            n=${ch_count[$ch]:-0}
            filled=$(( max_count > 0 ? n * 10 / max_count : 0 ))
            bar=""; for (( i=0; i<10; i++ )); do
                (( i < filled )) && bar+="▓" || bar+="░"
            done
            local dfs_mark="    "
            for d in "${dfs[@]}"; do [[ "$d" == "$ch" ]] && dfs_mark=" DFS"; done
            note=""; [[ "$ch" == "$recommended" ]] && note="  ← recommended"
            table+=$(printf ' Ch %3d%s  %s  %2d AP%s%s\n' \
                "$ch" "$dfs_mark" "$bar" "$n" \
                "$([[ $n -ne 1 ]] && printf 's')" "$note")
        done
        table+=$'\n DFS = radar-detection channels — many Pi drivers restrict AP use on these'
    fi

    # Render table to stderr (visible in terminal, not captured by caller)
    gum style \
        --border rounded \
        --border-foreground 4 \
        --padding "1 2" \
        "$(gum style --bold "  ${band_ghz} GHz channel survey — ${total} network(s) found  ")

$table" >&2
    printf '\n' >&2

    # Return recommended channel on stdout
    printf '%s' "$recommended"
}

# ============================================================================
# Interactive input — component picker + hotspot config
# ============================================================================
hr
gum style --bold --foreground 4 "  Pi 5 Greenfield Setup  "
printf '\n'
say "Target user: $USER_NAME  (home: $USER_HOME)"
printf '\n'

# --- Component picker ---
# Option labels use · instead of commas so --selected parsing (comma-split) is safe
_OPT_BASE="[base]   Base packages       tmux · git · gh · btop · ripgrep · jq · ncdu"
_OPT_GPS="[gps]    GPS / NTP           gpsd · gpsd-clients · pps-tools · chrony"
_OPT_KDISK="[disk]   KDiskMark           disk benchmark"
_OPT_CAD="[cad]    CAD tools           KiCad · FreeCAD · OpenSCAD · Inkscape  (~1 GB)"
_OPT_VSCODE="[code]   VS Code             Microsoft apt repo"
_OPT_VSEXT="[ext]    VS Code extensions  Claude Code · Codex"
_OPT_NODE="[node]   Node.js + AI CLIs   claude · codex"
_OPT_TS="[ts]     Tailscale           VPN"
_OPT_HOTSPOT="[wifi]   WiFi hotspot        eth0 → wlan0 AP"
_OPT_DARK="[dark]   Dark mode           GTK 3 / 4"

mapfile -t INSTALL_SELECTIONS < <(gum choose --no-limit \
    --header "Space to toggle  ·  Enter to confirm" \
    --selected="$_OPT_BASE,$_OPT_GPS,$_OPT_VSCODE,$_OPT_VSEXT,$_OPT_NODE,$_OPT_TS,$_OPT_HOTSPOT,$_OPT_DARK" \
    "$_OPT_BASE" \
    "$_OPT_GPS" \
    "$_OPT_KDISK" \
    "$_OPT_CAD" \
    "$_OPT_VSCODE" \
    "$_OPT_VSEXT" \
    "$_OPT_NODE" \
    "$_OPT_TS" \
    "$_OPT_HOTSPOT" \
    "$_OPT_DARK") || { printf 'Aborted.\n'; exit 0; }

_is_selected() { printf '%s\n' "${INSTALL_SELECTIONS[@]}" | grep -qF "$1"; }

# --- Hotspot config (only if selected) ---
HOTSPOT_SSID="" HOTSPOT_BAND="bg" HOTSPOT_CHANNEL=0 HOTSPOT_PSK=""

if _is_selected "$_OPT_HOTSPOT"; then
    printf '\n'; hr
    say "WiFi hotspot configuration"
    printf '\n'

    HOTSPOT_SSID=$(gum input \
        --header "Hotspot SSID" \
        --placeholder "PiField" \
        --value "PiField") || { printf 'Aborted.\n'; exit 0; }

    # Band
    _band_choice=$(gum choose \
        --header "WiFi band" \
        "2.4 GHz  (b/g/n — better range · broader device compatibility)" \
        "5 GHz    (a/n/ac — faster · less crowded)") \
        || { printf 'Aborted.\n'; exit 0; }

    if [[ "$_band_choice" == 5* ]]; then
        HOTSPOT_BAND="a"; _band_ghz="5"
    else
        HOTSPOT_BAND="bg"; _band_ghz="2.4"
    fi

    # Channel
    _ch_mode=$(gum choose \
        --header "Channel selection" \
        "Auto    (driver picks best available channel)" \
        "Scan    (survey nearby networks and recommend)" \
        "Manual  (enter a specific channel number)") \
        || { printf 'Aborted.\n'; exit 0; }

    case "$_ch_mode" in
        Auto*)
            HOTSPOT_CHANNEL=0
            ok "Channel: auto"
            ;;
        Scan*)
            printf '\n'
            if ip link show wlan0 >/dev/null 2>&1 && command -v iw >/dev/null 2>&1; then
                _recommended=$(_wifi_scan_channels "$_band_ghz")
                if [[ -n "$_recommended" ]]; then
                    if gum confirm --default=true "Use recommended channel $_recommended?"; then
                        HOTSPOT_CHANNEL=$_recommended
                    else
                        HOTSPOT_CHANNEL=$(gum input \
                            --header "Enter channel number" \
                            --value "$_recommended") \
                            || { printf 'Aborted.\n'; exit 0; }
                    fi
                else
                    warn "Scan returned no results — falling back to Auto"
                    HOTSPOT_CHANNEL=0
                fi
            else
                warn "wlan0 not available or 'iw' not installed — falling back to Auto"
                HOTSPOT_CHANNEL=0
            fi
            ;;
        Manual*)
            if [[ "$HOTSPOT_BAND" == "bg" ]]; then
                _ch_hint="1–11 for 2.4 GHz"
            else
                _ch_hint="e.g. 36 · 40 · 44 · 48 · 149 · 153 · 157 · 161 · 165 for 5 GHz"
            fi
            HOTSPOT_CHANNEL=$(gum input \
                --header "Channel ($_ch_hint)" \
                --placeholder "6") \
                || { printf 'Aborted.\n'; exit 0; }
            ;;
    esac

    # PSK
    while true; do
        HOTSPOT_PSK=$(gum input --password \
            --header "Hotspot WPA2 passphrase (min 8 chars)") \
            || { printf 'Aborted.\n'; exit 0; }
        if [[ ${#HOTSPOT_PSK} -lt 8 ]]; then
            warn "Passphrase must be at least 8 characters."
            continue
        fi
        HOTSPOT_PSK2=$(gum input --password \
            --header "Confirm passphrase") \
            || { printf 'Aborted.\n'; exit 0; }
        if [[ "$HOTSPOT_PSK" != "$HOTSPOT_PSK2" ]]; then
            warn "Passphrases don't match — try again."
            continue
        fi
        break
    done
fi

# --- Configuration summary ---
printf '\n'
_ch_display="$([[ "$HOTSPOT_CHANNEL" == "0" ]] && printf 'auto' || printf '%s' "$HOTSPOT_CHANNEL")"
_band_display="$([[ "$HOTSPOT_BAND" == "a" ]] && printf '5 GHz (a/n/ac)' || printf '2.4 GHz (b/g/n)')"

_summary_wifi=""
if _is_selected "$_OPT_HOTSPOT"; then
    _summary_wifi="
SSID:    $HOTSPOT_SSID
Band:    $_band_display
Channel: $_ch_display
PSK:     [${#HOTSPOT_PSK} chars]
Subnet:  10.42.0.0/24"
fi

_summary_components=""
for _s in "${INSTALL_SELECTIONS[@]}"; do
    _summary_components+="  • $_s"$'\n'
done

gum style \
    --border rounded \
    --border-foreground 4 \
    --padding "1 2" \
    "$(printf 'User:    %s%s' "$USER_NAME" "$_summary_wifi")

Installing:
${_summary_components%$'\n'}"
printf '\n'

gum confirm "Proceed with setup?" || { printf 'Aborted.\n'; exit 0; }
printf '\n'

# ============================================================================
# Step functions
# ============================================================================

update_apt() {
    hr
    say "Updating apt and installing prerequisites..."
    gum spin --spinner dot --title "Running apt update..." -- \
        apt-get update \
        || { record_fail "apt update"; return 1; }
    # ufw included here so setup_firewall always has it regardless of component selection
    gum spin --spinner dot --title "Installing prerequisites..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            lsb-release curl wget gpg apt-transport-https ca-certificates \
            software-properties-common gnupg ufw iw \
        || { record_fail "prereq packages"; return 1; }
    ok "apt ready"
}

enable_interfaces() {
    hr
    say "Enabling VNC, I2C, UART..."
    raspi-config nonint do_vnc 0       || record_fail "enable VNC"
    raspi-config nonint do_i2c 0       || record_fail "enable I2C"
    raspi-config nonint do_serial_hw 0 || record_fail "enable UART hardware"
    # Keep the serial console OFF so UART is free for GPS/peripherals
    raspi-config nonint do_serial_cons 1 || record_fail "disable serial console"
    ok "VNC / I2C / UART enabled"
}

config_txt_tweaks() {
    hr
    say "Updating /boot/firmware/config.txt..."
    local cfg="/boot/firmware/config.txt"
    if [[ ! -f "$cfg" ]]; then
        err "$cfg not found"
        record_fail "config.txt not found"
        return 1
    fi

    cp "$cfg" "${cfg}.bak.$(date +%Y%m%d-%H%M%S)"

    if ! grep -q "# Greenfield setup additions" "$cfg"; then
        { echo ""; echo "# Greenfield setup additions"; } >> "$cfg"
    fi

    _config_set "$cfg" "usb_max_current_enable=1"
    _config_set "$cfg" "dtparam=pciex1_gen=3"

    ok "config.txt updated (backup saved)"
}

disable_fake_hwclock() {
    hr
    say "Disabling fake-hwclock (Pi 5 has a real hardware RTC)..."
    systemctl disable --now fake-hwclock.service 2>/dev/null || true
    apt-get purge -y fake-hwclock 2>/dev/null || true
    ok "fake-hwclock removed"
}

configure_rtc_battery() {
    hr
    say "Configuring RTC battery charging..."

    local cfg="/boot/firmware/config.txt"

    # dtparam=rtc_bbat_voltage controls the Pi 5 trickle-charge circuit:
    #   0     = charging disabled (required for non-rechargeable CR2032)
    #   3000  = charge to 3.0 V  (ML-2020 / ML1220 rechargeable cells)
    local choice
    choice=$(gum choose \
        --header "What RTC battery is installed in the J5 connector?" \
        "CR2032 (non-rechargeable) — disable charging" \
        "Rechargeable (ML-2020 / ML1220) — enable charging at 3.0 V" \
        "No battery installed — disable charging" \
        "Skip") \
        || { warn "RTC battery config skipped"; return 0; }

    case "$choice" in
        CR2032*)
            _config_set "$cfg" "dtparam=rtc_bbat_voltage=0"
            ok "RTC charging disabled — safe for CR2032"
            ;;
        Rechargeable*)
            _config_set "$cfg" "dtparam=rtc_bbat_voltage=3000"
            ok "RTC charging enabled at 3.0 V"
            ;;
        "No battery"*)
            _config_set "$cfg" "dtparam=rtc_bbat_voltage=0"
            ok "RTC charging disabled — no battery present"
            ;;
        Skip*)
            warn "RTC battery config skipped"
            warn "If using a CR2032, add 'dtparam=rtc_bbat_voltage=0' to /boot/firmware/config.txt"
            ;;
    esac
}

install_base_packages() {
    hr
    say "Installing base / quality-of-life packages..."
    gum spin --spinner dot --title "Installing base packages..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            tmux git gh ufw jq ripgrep fd-find ncdu iotop nvme-cli \
            htop btop \
            build-essential \
            libglib2.0-bin \
        || record_fail "base packages"
    ok "Base packages installed"
}

install_time_gps() {
    hr
    say "Installing gpsd and chrony..."
    gum spin --spinner dot --title "Installing gpsd · gpsd-clients · pps-tools · chrony..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            gpsd gpsd-clients pps-tools chrony \
        || record_fail "gpsd/chrony"
    ok "gpsd + chrony installed (manual configuration required for GPS NTP)"
}

install_kdiskmark() {
    hr
    say "Installing KDiskMark..."
    gum spin --spinner dot --title "Installing kdiskmark..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y kdiskmark \
        || record_fail "kdiskmark"
    ok "kdiskmark done"
}

install_cad_tools() {
    hr
    say "Installing CAD tools: KiCad, FreeCAD, OpenSCAD, Inkscape..."
    warn "KiCad + FreeCAD libraries are ~1 GB combined — this will take a while."
    gum spin --spinner dot --title "Installing CAD tools (~1 GB — please wait)..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            kicad kicad-libraries \
            freecad \
            openscad \
            inkscape \
        || record_fail "CAD tools"
    ok "CAD tools installed"
}

install_vscode() {
    hr
    say "Installing Visual Studio Code..."
    if command -v code >/dev/null 2>&1; then
        ok "VS Code already installed"
        return 0
    fi

    gum spin --spinner dot --title "Fetching Microsoft GPG key..." -- \
        sh -c 'wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg' \
        || { record_fail "MS GPG key download"; return 1; }

    cat > /etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

    gum spin --spinner dot --title "Updating apt for VS Code..." -- \
        apt-get update \
        || { record_fail "apt update for vscode"; return 1; }
    gum spin --spinner dot --title "Installing VS Code..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y code \
        || { record_fail "vscode install"; return 1; }
    ok "VS Code installed"
}

install_vscode_extensions() {
    hr
    say "Installing VS Code extensions (Claude Code + Codex)..."
    if ! command -v code >/dev/null 2>&1; then
        warn "VS Code not installed; skipping extensions"
        record_fail "VS Code extensions (code not found)"
        return 1
    fi

    as_user code --install-extension anthropic.claude-code --force \
        || record_fail "Claude Code extension"
    as_user code --install-extension openai.chatgpt --force \
        || record_fail "Codex extension"

    ok "VS Code extensions installed (sign in on first launch)"
}

install_node_and_clis() {
    hr
    say "Installing Node.js + Claude Code CLI + Codex CLI..."
    gum spin --spinner dot --title "Installing Node.js and npm..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm \
        || { record_fail "nodejs/npm"; return 1; }

    gum spin --spinner dot --title "Installing claude CLI..." -- \
        npm install -g @anthropic-ai/claude-code \
        || record_fail "claude-code CLI"
    gum spin --spinner dot --title "Installing codex CLI..." -- \
        npm install -g @openai/codex \
        || record_fail "codex CLI"

    ok "CLIs installed (run 'claude' and 'codex' to authenticate)"
}

install_tailscale() {
    hr
    say "Installing Tailscale..."
    if command -v tailscale >/dev/null 2>&1; then
        ok "Tailscale already installed"
        return 0
    fi
    gum spin --spinner dot --title "Installing Tailscale..." -- \
        sh -c 'curl -fsSL https://tailscale.com/install.sh | sh' \
        || record_fail "tailscale install"
    ok "Tailscale installed"
}

setup_hotspot() {
    hr
    say "Creating '$HOTSPOT_SSID' WiFi hotspot..."

    if ! command -v nmcli >/dev/null 2>&1; then
        err "NetworkManager (nmcli) not found — can't configure hotspot"
        record_fail "hotspot (no nmcli)"
        return 1
    fi

    if ! ip link show wlan0 >/dev/null 2>&1; then
        warn "wlan0 interface not found — skipping hotspot setup"
        warn "Enable WiFi in raspi-config or via 'rfkill unblock wifi', then re-run"
        warn "Or activate later with: sudo nmcli con up '$HOTSPOT_SSID'"
        record_fail "hotspot (wlan0 missing)"
        return 1
    fi

    if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
        say "WiFi is soft-blocked — unblocking via rfkill..."
        rfkill unblock wifi || warn "rfkill unblock failed; hotspot activation may fail"
    fi

    nmcli con delete "$HOTSPOT_SSID" 2>/dev/null || true
    mapfile -t _conflicting < <(
        nmcli -t -f NAME,802-11-wireless.mode con show 2>/dev/null \
            | awk -F: 'tolower($2) == "ap" { print $1 }' \
            | grep -Fxv "$HOTSPOT_SSID" || true
    )
    for _con in "${_conflicting[@]}"; do
        [[ -z "$_con" ]] && continue
        say "  Removing conflicting AP profile: '$_con'"
        nmcli con delete "$_con" 2>/dev/null || true
    done

    # Build nmcli property arguments; omit wifi.channel when auto (0)
    # ipv4.method shared: NM sets up dnsmasq DHCP, IP forwarding, and MASQUERADE
    # on the default-route interface (eth0 for PoE builds).
    local nmcli_props=(
        mode ap
        ipv4.method shared
        ipv4.addresses 10.42.0.1/24
        wifi.band "$HOTSPOT_BAND"
        wifi-sec.key-mgmt wpa-psk
        wifi-sec.psk "$HOTSPOT_PSK"
        wifi-sec.pmf disable
    )
    [[ "$HOTSPOT_CHANNEL" != "0" ]] && nmcli_props+=(wifi.channel "$HOTSPOT_CHANNEL")

    local _band_label
    [[ "$HOTSPOT_BAND" == "a" ]] && _band_label="5 GHz" || _band_label="2.4 GHz"
    local _ch_label
    [[ "$HOTSPOT_CHANNEL" == "0" ]] && _ch_label="auto" || _ch_label="ch $HOTSPOT_CHANNEL"
    say "  Band: $_band_label · Channel: $_ch_label · Subnet: 10.42.0.1/24"

    nmcli con add \
        type wifi \
        ifname wlan0 \
        con-name "$HOTSPOT_SSID" \
        autoconnect yes \
        ssid "$HOTSPOT_SSID" \
        -- \
        "${nmcli_props[@]}" \
        || { record_fail "hotspot create"; return 1; }

    if ! nmcli con up "$HOTSPOT_SSID" 2>/dev/null; then
        warn "Hotspot profile created but didn't activate"
        warn "  Check interface:  nmcli device status"
        warn "  Check rfkill:     rfkill list"
        warn "  Activate later:   sudo nmcli con up '$HOTSPOT_SSID'"
    else
        ok "Hotspot '$HOTSPOT_SSID' active on 10.42.0.1/24"
    fi
}

set_dark_mode() {
    hr
    say "Setting dark mode via GTK settings..."

    as_user mkdir -p "$USER_HOME/.config/gtk-3.0"
    as_user tee "$USER_HOME/.config/gtk-3.0/settings.ini" >/dev/null <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

    as_user mkdir -p "$USER_HOME/.config/gtk-4.0"
    as_user tee "$USER_HOME/.config/gtk-4.0/settings.ini" >/dev/null <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

    as_user dbus-launch gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true

    ok "Dark mode set (takes effect at next graphical login)"
    warn "On Pi OS Desktop, run 'pi-appearance' to pick a specific dark theme if needed"
}

setup_firewall() {
    hr
    say "Configuring UFW firewall..."

    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed 2>/dev/null || true

    ufw allow ssh                  comment 'SSH'
    ufw allow 80/tcp               comment 'HTTP'
    ufw allow 443/tcp              comment 'HTTPS'
    ufw allow 5900/tcp             comment 'VNC'
    ufw allow from 10.42.0.0/24    comment 'Hotspot clients'
    ufw allow in on tailscale0     comment 'Tailscale VPN' 2>/dev/null || true

    ufw --force enable >/dev/null
    ok "UFW enabled (ssh · http/s · vnc · hotspot subnet · tailscale)"
}

# ============================================================================
# Main flow
# ============================================================================

# Always: core system configuration
update_apt
enable_interfaces
config_txt_tweaks
disable_fake_hwclock
configure_rtc_battery
setup_firewall

# Optional: selected components
_is_selected "$_OPT_BASE"    && install_base_packages
_is_selected "$_OPT_GPS"     && install_time_gps
_is_selected "$_OPT_KDISK"   && install_kdiskmark
_is_selected "$_OPT_CAD"     && install_cad_tools
_is_selected "$_OPT_VSCODE"  && install_vscode
_is_selected "$_OPT_VSEXT"   && install_vscode_extensions
_is_selected "$_OPT_NODE"    && install_node_and_clis
_is_selected "$_OPT_TS"      && install_tailscale
_is_selected "$_OPT_HOTSPOT" && setup_hotspot
_is_selected "$_OPT_DARK"    && set_dark_mode

# ============================================================================
# Summary
# ============================================================================
printf '\n'
hr
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    gum style \
        --border rounded \
        --border-foreground 2 \
        --padding "1 2" \
        "$(gum style --bold --foreground 2 "Setup complete — no failures.")"
else
    _failure_list=""
    for f in "${FAILURES[@]}"; do _failure_list+="  • $f"$'\n'; done
    gum style \
        --border rounded \
        --border-foreground 3 \
        --padding "1 2" \
        "$(gum style --bold --foreground 3 "Setup complete — ${#FAILURES[@]} step(s) had issues:")
${_failure_list%$'\n'}"
fi

printf '\n'
gum style --bold "Manual follow-ups:"
printf '  1. Verify PCIe Gen 3 after reboot:  lspci -vv | grep -iE '"'"'lnksta|speed'"'"'\n'
printf '  2. Verify USB current setting:       vcgencmd get_config usb_max_current_enable\n'
printf '  3. Check RTC after reboot:           timedatectl  (look for '"'"'RTC time'"'"')\n'
printf '  4. Verify hotspot:                   nmcli device status\n'
printf '  5. Sign into VS Code extensions on first open (Claude Code, Codex)\n'
printf '  6. Run '"'"'claude'"'"' and '"'"'codex'"'"' in a terminal to authenticate CLIs\n'
printf '  7. Configure chrony+gpsd if you want GPS-disciplined NTP\n'
printf '\n'
hr
printf '\n'

if _is_selected "$_OPT_TS"; then
    if gum confirm --default=false "Run 'sudo tailscale up' now?"; then
        tailscale up || warn "tailscale up didn't complete — run it again manually"
    fi
    printf '\n'
fi

if gum confirm --affirmative "Reboot" --negative "Later" \
        "Reboot now to apply config.txt changes?"; then
    say "Rebooting in 3 seconds..."
    sleep 3
    reboot
fi
