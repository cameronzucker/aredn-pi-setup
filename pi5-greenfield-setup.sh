#!/bin/bash
#
# pi5-greenfield-setup.sh
# Post-imaging setup for Raspberry Pi 5 on Raspberry Pi OS Trixie (Desktop, arm64)
#
# What this does (roughly in order):
#   1. Prompts for hotspot credentials up front so the rest can run unattended
#   2. Updates apt & installs prerequisites
#   3. Enables VNC, I2C, UART via raspi-config (non-interactive)
#   4. Writes usb_max_current_enable=1 and dtparam=pciex1_gen=3 to config.txt
#   5. Disables fake-hwclock (Pi 5 has a native RTC powered by CR2032 on the HAT)
#   6. Warns about RTC battery charging settings
#   7. Installs base quality-of-life packages (tmux, git, gh, jq, rg, etc.)
#   8. Configures UFW firewall (early — limits unprotected exposure window)
#   9. Installs gpsd, chrony, btop, kdiskmark, nvme-cli
#  10. Installs CAD tools: KiCad, FreeCAD, OpenSCAD, Inkscape
#  11. Installs VS Code from Microsoft's apt repo
#  12. Installs VS Code extensions: Claude Code (anthropic.claude-code),
#       Codex (openai.chatgpt)
#  13. Installs Node.js and the Claude Code + Codex CLIs via npm
#  14. Installs Tailscale
#  15. Creates a WiFi hotspot (eth0 WAN -> wlan0 AP) via NetworkManager
#  16. Sets dark mode preference via GTK settings
#  17. Offers to run `tailscale up` and reboot at the end
#
# Run with: sudo ./pi5-greenfield-setup.sh
# Re-running is safe — most steps are idempotent.

set -o pipefail

# ============================================================================
# Output helpers
# ============================================================================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

say()  { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
err()  { printf '%s[err]%s %s\n' "$RED" "$RESET" "$*" >&2; }
hr()   { printf '%s%s%s\n' "$BOLD" "------------------------------------------------------------" "$RESET"; }

# Track failures so we can summarize at the end rather than halt on first hiccup.
FAILURES=()
record_fail() { FAILURES+=("$1"); }

# ============================================================================
# Pre-flight checks
# ============================================================================
if [[ $EUID -ne 0 ]]; then
    err "This script must be run with sudo."
    exit 1
fi

if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
    err "Run this with 'sudo ./pi5-greenfield-setup.sh' as a normal user,"
    err "not directly as root — we need to configure user-level settings."
    exit 1
fi

USER_NAME="$SUDO_USER"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

if [[ ! -d "$USER_HOME" ]]; then
    err "Couldn't determine home directory for user $USER_NAME"
    exit 1
fi

# Run a command as the target user, preserving their environment
as_user() { sudo -u "$USER_NAME" -H "$@"; }

# Check we're on a Pi 5
if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null \
   && ! grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null; then
    warn "This doesn't look like a Raspberry Pi 5."
    read -r -p "Continue anyway? [y/N]: " resp
    [[ "$resp" =~ ^[Yy]$ ]] || exit 1
fi

# Check we're on Trixie
if ! grep -q "trixie" /etc/os-release 2>/dev/null; then
    warn "This doesn't appear to be Debian Trixie."
    read -r -p "Continue anyway? [y/N]: " resp
    [[ "$resp" =~ ^[Yy]$ ]] || exit 1
fi

# ============================================================================
# Collect interactive input up front
# ============================================================================
hr
printf '%s=== Pi 5 Greenfield Setup ===%s\n\n' "$BOLD" "$RESET"
echo "Collecting config up front so the rest can run unattended."
echo "Target user: $USER_NAME (home: $USER_HOME)"
echo

read -r -p "Hotspot SSID [PiField]: " HOTSPOT_SSID
HOTSPOT_SSID=${HOTSPOT_SSID:-PiField}

read -r -p "Hotspot channel (2.4GHz: 1-11) [6]: " HOTSPOT_CHANNEL
HOTSPOT_CHANNEL=${HOTSPOT_CHANNEL:-6}
if ! [[ "$HOTSPOT_CHANNEL" =~ ^[0-9]+$ ]] || (( HOTSPOT_CHANNEL < 1 || HOTSPOT_CHANNEL > 11 )); then
    err "Hotspot channel must be 1-11 (got: '$HOTSPOT_CHANNEL')"
    exit 1
fi

while true; do
    read -r -s -p "Hotspot WPA2 passphrase (min 8 chars): " HOTSPOT_PSK
    echo
    if [[ ${#HOTSPOT_PSK} -lt 8 ]]; then
        warn "Passphrase must be at least 8 characters."
        continue
    fi
    read -r -s -p "Confirm passphrase: " HOTSPOT_PSK2
    echo
    if [[ "$HOTSPOT_PSK" != "$HOTSPOT_PSK2" ]]; then
        warn "Passphrases don't match, try again."
        continue
    fi
    break
done

echo
printf '%sConfiguration summary:%s\n' "$BOLD" "$RESET"
echo "  User:            $USER_NAME"
echo "  Hotspot SSID:    $HOTSPOT_SSID"
echo "  Hotspot channel: $HOTSPOT_CHANNEL (2.4GHz)"
echo "  Hotspot PSK:     [${#HOTSPOT_PSK} chars]"
echo "  Hotspot subnet:  10.42.0.0/24 (NetworkManager default)"
echo
read -r -p "Proceed? [Y/n]: " resp
[[ "$resp" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ============================================================================
# Step functions
# ============================================================================

update_apt() {
    hr
    say "Updating apt and installing prerequisites..."
    apt update || { record_fail "apt update"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt install -y \
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
    apt purge -y fake-hwclock 2>/dev/null || true
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
    DEBIAN_FRONTEND=noninteractive apt install -y \
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
    DEBIAN_FRONTEND=noninteractive apt install -y \
        gpsd gpsd-clients pps-tools chrony \
        || record_fail "gpsd/chrony"
    # Leave services as installed; user will configure them for their GPS setup
    ok "gpsd + chrony installed (manual configuration required for GPS NTP)"
}

install_kdiskmark() {
    hr
    say "Installing KDiskMark..."
    DEBIAN_FRONTEND=noninteractive apt install -y kdiskmark \
        || record_fail "kdiskmark"
    ok "kdiskmark done"
}

install_cad_tools() {
    hr
    say "Installing CAD tools: KiCad, FreeCAD, OpenSCAD, Inkscape..."
    say "  (KiCad + FreeCAD libraries are ~1GB combined; this takes a while)"
    DEBIAN_FRONTEND=noninteractive apt install -y \
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
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        > /usr/share/keyrings/packages.microsoft.gpg \
        || { record_fail "MS GPG key download"; return 1; }

    # Add the repo
    cat > /etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

    apt update || { record_fail "apt update for vscode"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt install -y code \
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
    DEBIAN_FRONTEND=noninteractive apt install -y nodejs npm \
        || { record_fail "nodejs/npm"; return 1; }

    # Install CLIs globally. Note: this puts them in /usr/local/bin
    # (or wherever npm is configured), accessible to all users.
    npm install -g @anthropic-ai/claude-code \
        || record_fail "claude-code CLI"
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
    curl -fsSL https://tailscale.com/install.sh | sh \
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
echo
hr
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    printf '%s%s=== Setup complete with no failures ===%s\n' "$BOLD" "$GREEN" "$RESET"
else
    printf '%s%s=== Setup complete with %d warning(s) ===%s\n' "$BOLD" "$YELLOW" "${#FAILURES[@]}" "$RESET"
    echo "The following steps had issues — you may want to run them manually:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
fi
echo
echo "Manual follow-ups:"
echo "  1. Verify PCIe Gen 3 after reboot:  lspci -vv | grep -iE 'lnksta|speed'"
echo "  2. Verify USB current setting:       vcgencmd get_config usb_max_current_enable"
echo "  3. Check RTC after reboot:           timedatectl  (look for 'RTC time')"
echo "  4. Verify hotspot:                   nmcli device status"
echo "  5. Sign into VS Code extensions on first open (Claude Code, Codex)"
echo "  6. Run 'claude' and 'codex' in a terminal to authenticate CLIs"
echo "  7. Configure chrony+gpsd if you want GPS-disciplined NTP"
echo
hr

read -r -p "Run 'sudo tailscale up' now? [y/N]: " resp
if [[ "$resp" =~ ^[Yy]$ ]]; then
    tailscale up || warn "tailscale up didn't complete — run it again manually"
fi

echo
read -r -p "Reboot now to apply config.txt changes? [Y/n]: " resp
if [[ ! "$resp" =~ ^[Nn]$ ]]; then
    echo "Rebooting in 3 seconds... Ctrl+C to cancel"
    sleep 3
    reboot
fi
