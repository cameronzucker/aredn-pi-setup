#!/bin/bash
#
# pi5-greenfield-setup.sh
# Post-imaging setup for Raspberry Pi 5 on Raspberry Pi OS Trixie (Desktop, arm64)
#
# What this does (roughly in order):
#   1. Bootstraps gum (Charm.sh) for interactive UI
#   2. Prompts for hotspot credentials up front so the rest can run unattended
#   3. Updates apt & installs prerequisites
#   4. Enables VNC, I2C, UART via raspi-config (non-interactive)
#   5. Writes usb_max_current_enable=1 and dtparam=pciex1_gen=3 to config.txt
#   6. Disables fake-hwclock (Pi 5 has a native RTC powered by CR2032 on the HAT)
#   7. Warns about RTC battery charging settings
#   8. Installs base quality-of-life packages (tmux, git, gh, jq, rg, etc.)
#   9. Configures UFW firewall (early — limits unprotected exposure window)
#  10. Installs gpsd, chrony, btop, kdiskmark, nvme-cli
#  11. Installs CAD tools: KiCad, FreeCAD, OpenSCAD, Inkscape
#  12. Installs VS Code from Microsoft's apt repo
#  13. Installs VS Code extensions: Claude Code (anthropic.claude-code),
#       Codex (openai.chatgpt)
#  14. Installs Node.js and the Claude Code + Codex CLIs via npm
#  15. Installs Tailscale
#  16. Creates a WiFi hotspot (eth0 WAN -> wlan0 AP) via NetworkManager
#  17. Sets dark mode preference via GTK settings
#  18. Offers to run `tailscale up` and reboot at the end
#
# Run with: sudo ./pi5-greenfield-setup.sh
# Re-running is safe — most steps are idempotent.

set -o pipefail

# ============================================================================
# Output helpers — defined here, require gum (bootstrapped below)
# ============================================================================
say()  { gum style --foreground 4 "==> $*"; }
ok()   { gum style --foreground 2 " ✓  $*"; }
warn() { gum style --foreground 3 " ⚠  $*" >&2; }
err()  { gum style --foreground 1 " ✗  $*" >&2; }
hr()   { gum style --foreground 8 "────────────────────────────────────────────────────────────"; }

# Track failures so we can summarize at the end rather than halt on first hiccup.
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

# Run a command as the target user, preserving their environment
as_user() { sudo -u "$USER_NAME" -H "$@"; }

# ============================================================================
# Bootstrap gum (Charm.sh) — required for all interactive UI below
# ============================================================================
_bootstrap_gum() {
    command -v gum >/dev/null 2>&1 && return 0
    printf 'Installing gum (required for interactive UI)...\n'
    # Try system apt cache first — gum is in Debian Trixie/Sid repos
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gum \
            >/dev/null 2>&1; then
        return 0
    fi
    # Fallback: Charm's official apt repo
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
# Pi / OS checks (gum now available)
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
# Collect interactive input up front
# ============================================================================
hr
gum style --bold --foreground 4 "  Pi 5 Greenfield Setup  "
printf '\n'
say "Collecting config up front so the rest can run unattended."
say "Target user: $USER_NAME  (home: $USER_HOME)"
printf '\n'

HOTSPOT_SSID=$(gum input \
    --header "Hotspot SSID" \
    --placeholder "PiField" \
    --value "PiField") \
    || { printf 'Aborted.\n'; exit 0; }

HOTSPOT_CHANNEL=$(gum input \
    --header "Hotspot channel (2.4 GHz, 1–11)" \
    --placeholder "6" \
    --value "6") \
    || { printf 'Aborted.\n'; exit 0; }

if ! [[ "$HOTSPOT_CHANNEL" =~ ^[0-9]+$ ]] || (( HOTSPOT_CHANNEL < 1 || HOTSPOT_CHANNEL > 11 )); then
    err "Hotspot channel must be 1–11 (got: '$HOTSPOT_CHANNEL')"
    exit 1
fi

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

printf '\n'
gum style \
    --border rounded \
    --border-foreground 4 \
    --padding "1 2" \
    "$(printf 'User:    %s\nSSID:    %s\nChannel: %s (2.4 GHz)\nPSK:     [%d chars]\nSubnet:  10.42.0.0/24' \
        "$USER_NAME" "$HOTSPOT_SSID" "$HOTSPOT_CHANNEL" "${#HOTSPOT_PSK}")"
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
    gum spin --spinner dot --title "Installing prerequisites..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            lsb-release curl wget gpg apt-transport-https ca-certificates \
            software-properties-common gnupg \
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

    # Helper: ensure a line exists (append if missing).
    # Uses ${line%=*} (strip last =value) so dtparam=pciex1_gen=3 produces key
    # "dtparam=pciex1_gen", not "dtparam" — preventing clobber of other dtparam= lines.
    _ensure_line() {
        local line="$1"
        local key="${line%=*}"
        # Escape regex metacharacters in the key for safe use in grep/sed
        local re_key
        re_key=$(printf '%s' "$key" | sed 's/[[\.*^$()+?{|]/\\&/g')
        if grep -qE "^\s*${re_key}=" "$cfg"; then
            # Replace any existing value for this exact key
            sed -i -E "s|^\s*${re_key}=.*|${line}|" "$cfg"
        else
            echo "$line" >> "$cfg"
        fi
    }

    # Append a marker comment once
    if ! grep -q "# Greenfield setup additions" "$cfg"; then
        {
            echo ""
            echo "# Greenfield setup additions"
        } >> "$cfg"
    fi

    _ensure_line "usb_max_current_enable=1"
    _ensure_line "dtparam=pciex1_gen=3"

    ok "config.txt updated (backup saved)"
}

disable_fake_hwclock() {
    hr
    say "Disabling fake-hwclock (Pi 5 has a real hardware RTC)..."
    systemctl disable --now fake-hwclock.service 2>/dev/null || true
    apt-get purge -y fake-hwclock 2>/dev/null || true
    ok "fake-hwclock removed"
}

check_rtc_charging() {
    hr
    say "Checking RTC battery charging setting (CR2032 is NOT rechargeable)..."
    if command -v rpi-eeprom-config >/dev/null 2>&1; then
        local cfg
        cfg=$(rpi-eeprom-config 2>/dev/null || true)
        if echo "$cfg" | grep -qE "^POWER_OFF_ON_HALT=1"; then
            ok "POWER_OFF_ON_HALT=1 (RTC charging not active)"
        else
            warn "Current EEPROM config does NOT have POWER_OFF_ON_HALT=1 set."
            warn "If a CR2032 is installed, you should set it to prevent charge attempts."
            warn "Run: sudo -E rpi-eeprom-config --edit"
            warn "and add 'POWER_OFF_ON_HALT=1' (do NOT set PSU_MAX_CURRENT if using CR2032)."
        fi
    else
        warn "rpi-eeprom-config not found; can't verify RTC battery setting"
    fi
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
    gum spin --spinner dot --title "Installing gpsd, gpsd-clients, pps-tools, chrony..." -- \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            gpsd gpsd-clients pps-tools chrony \
        || record_fail "gpsd/chrony"
    # Leave services as installed; user will configure them for their GPS setup
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

    # Import Microsoft signing key
    gum spin --spinner dot --title "Fetching Microsoft GPG key..." -- \
        sh -c 'wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg' \
        || { record_fail "MS GPG key download"; return 1; }

    # Add the repo
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

    # Extensions are installed per-user, so run as the target user
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

    # Install CLIs globally. Note: this puts them in /usr/local/bin
    # (or wherever npm is configured), accessible to all users.
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
    say "Creating '$HOTSPOT_SSID' WiFi hotspot (eth0 WAN -> wlan0 AP)..."

    if ! command -v nmcli >/dev/null 2>&1; then
        err "NetworkManager (nmcli) not found — can't configure hotspot"
        record_fail "hotspot (no nmcli)"
        return 1
    fi

    # Bail early if wlan0 doesn't exist — Pi may not have WiFi enabled yet
    if ! ip link show wlan0 >/dev/null 2>&1; then
        warn "wlan0 interface not found — skipping hotspot setup"
        warn "Enable WiFi in raspi-config or via 'rfkill unblock wifi', then re-run"
        warn "Or activate later with: sudo nmcli con up '$HOTSPOT_SSID'"
        record_fail "hotspot (wlan0 missing)"
        return 1
    fi

    # Unblock WiFi if rfkill has it soft-blocked
    if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
        say "WiFi is soft-blocked — unblocking via rfkill..."
        rfkill unblock wifi || warn "rfkill unblock failed; hotspot activation may fail"
    fi

    # Remove our own profile for a clean slate, then find and remove any other
    # AP-mode profiles — a manually configured hotspot with a different name
    # will block activation even if ours is created successfully.
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

    # ipv4.method shared: NetworkManager automatically sets up dnsmasq for DHCP,
    # enables IP forwarding, and adds MASQUERADE rules to route traffic out
    # the default-route interface (eth0 for a PoE build).
    nmcli con add \
        type wifi \
        ifname wlan0 \
        con-name "$HOTSPOT_SSID" \
        autoconnect yes \
        ssid "$HOTSPOT_SSID" \
        -- \
        mode ap \
        ipv4.method shared \
        ipv4.addresses 10.42.0.1/24 \
        wifi.band bg \
        wifi.channel "$HOTSPOT_CHANNEL" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$HOTSPOT_PSK" \
        wifi-sec.pmf disable \
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

    # GTK-3
    as_user mkdir -p "$USER_HOME/.config/gtk-3.0"
    as_user tee "$USER_HOME/.config/gtk-3.0/settings.ini" >/dev/null <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

    # GTK-4
    as_user mkdir -p "$USER_HOME/.config/gtk-4.0"
    as_user tee "$USER_HOME/.config/gtk-4.0/settings.ini" >/dev/null <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

    # Also try gsettings for apps that read from there. This may fail under
    # SSH without an active session — that's fine, the settings.ini files
    # above handle the persistent case.
    as_user dbus-launch gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true

    ok "Dark mode set (takes effect at next graphical login)"
    warn "On Pi OS Desktop, run 'pi-appearance' to pick a specific dark theme if the default doesn't look right"
}

setup_firewall() {
    hr
    say "Configuring UFW firewall..."

    # Reset to a known state first
    ufw --force reset >/dev/null 2>&1 || true

    ufw default deny incoming
    ufw default allow outgoing
    # Allow forwarded traffic — needed for the hotspot NAT to work
    ufw default allow routed 2>/dev/null || true

    # Core services
    ufw allow ssh                  comment 'SSH'
    ufw allow 80/tcp               comment 'HTTP'
    ufw allow 443/tcp              comment 'HTTPS'
    ufw allow 5900/tcp             comment 'VNC'

    # Hotspot clients — trust the AP subnet
    ufw allow from 10.42.0.0/24    comment 'Hotspot clients'

    # Tailscale manages its own interface; allow anything over tailscale0
    ufw allow in on tailscale0     comment 'Tailscale VPN' 2>/dev/null || true

    ufw --force enable >/dev/null
    ok "UFW enabled (ssh, http/s, vnc, hotspot, tailscale)"
}

# ============================================================================
# Main flow
# ============================================================================
update_apt
enable_interfaces
config_txt_tweaks
disable_fake_hwclock
check_rtc_charging
install_base_packages
setup_firewall        # early — closes exposure window before long downloads
install_time_gps
install_kdiskmark
install_cad_tools
install_vscode
install_vscode_extensions
install_node_and_clis
install_tailscale
setup_hotspot
set_dark_mode

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
    for f in "${FAILURES[@]}"; do
        _failure_list+="  • $f"$'\n'
    done
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

if gum confirm --default=false "Run 'sudo tailscale up' now?"; then
    tailscale up || warn "tailscale up didn't complete — run it again manually"
fi

printf '\n'
if gum confirm --affirmative "Reboot" --negative "Later" \
        "Reboot now to apply config.txt changes?"; then
    say "Rebooting in 3 seconds..."
    sleep 3
    reboot
fi
