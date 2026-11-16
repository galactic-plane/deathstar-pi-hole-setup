#!/bin/bash
#===============================================================================
# File: update.sh
# Project: Death Star Pi-hole Setup
# Description: Update script for Pi-hole, Grafana, Prometheus and all
#              internet-monitoring components. Works even if setup was never
#              run - will only update what's currently installed.
#
# Target Environment:
#   OS: Raspberry Pi OS aarch64
#   Host: Raspberry Pi 5 Model B Rev 1.1
#   Shell: bash
#   Dependencies: Multiple (see individual update functions)
#
# Author: galactic-plane
# Repository: https://github.com/galactic-plane/deathstar-pi-hole-setup
# License: See LICENSE file
#===============================================================================

# Remove the exit on error for more resilient operation
# set -e  # Exit on any error

# Source the Rich installer utility first to ensure enhanced terminal output
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/rich_installer.sh"

# Ensure Rich library is available for enhanced terminal output
ensure_rich_available

# Load advanced logging system
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/log_handler.sh"

# Load shared configuration
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/config_loader.sh"

# Load stack hardening helpers (passwords in .env files, Pi-hole settings,
# Grafana first-start password cleanup, playbook lock)
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/stack_hardening.sh"

# Initialize logging for this script
log_init "update"

# Colors for output (for backward compatibility)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Rich helper functions
RICH_HELPER="$(dirname "${BASH_SOURCE[0]}")/lib/rich_helper.py"

# Check if Rich is available and use it, otherwise fallback to basic colors
use_rich_if_available() {
# shellcheck disable=SC2312
    if [[ -f "${RICH_HELPER}" ]] && command -v python3 >/dev/null 2>&1; then
        if python3 -c "import rich" >/dev/null 2>&1; then
            return 0  # Rich is available
        fi
    fi
    return 1  # Rich not available, use fallback
}

rich_header() {
    if use_rich_if_available; then
        python3 "${RICH_HELPER}" header --title "$1" --subtitle "${2:-}"
    else
        echo -e "\n${PURPLE}══════════════════════════════════════════════════════════════${NC}"
        echo -e "                    ${CYAN}$1${NC}                    "
        [[ -n "${2:-}" ]] && echo -e "                    ${2}                    "
        echo -e "${PURPLE}══════════════════════════════════════════════════════════════${NC}\n"
    fi
}

rich_section() {
    if use_rich_if_available; then
        python3 "${RICH_HELPER}" section --title "$1"
    else
        echo -e "\n${CYAN}▶ $1${NC}"
    fi
}

rich_status() {
    local message="$1"
    local style="${2:-info}"
    
    if use_rich_if_available; then
        python3 "${RICH_HELPER}" status --message "${message}" --style "${style}"
    else
        case "${style}" in
            "success") echo -e "${GREEN}[SUCCESS]${NC} ${message}" ;;
            "warning") echo -e "${YELLOW}[WARNING]${NC} ${message}" ;;
            "error") echo -e "${RED}[ERROR]${NC} ${message}" ;;
            *) echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        esac
    fi
}

rich_disclaimer() {
    local disclaimer_type="${1:-legal}"
    
    if use_rich_if_available; then
        python3 "${RICH_HELPER}" disclaimer --type "${disclaimer_type}"
    else
        # Fallback to manual box drawing
        if [[ "${disclaimer_type}" == "legal" ]]; then
            echo -e "${RED}"
            echo "══════════════════════════════════════════════════════════════════"
            echo "                        ⚠️  LEGAL DISCLAIMER ⚠️                   "
            echo ""
            echo "  This script is provided 'AS IS' without warranty of any kind.  "
            echo "  The author(s) cannot be held responsible for any damage,        "
            echo "  data loss, system instability, or other issues that may         "
            echo "  result from running this script.                                "
            echo ""
            echo "  YOU RUN THIS SCRIPT ENTIRELY AT YOUR OWN RISK.                 "
            echo ""
            echo "  By proceeding, you acknowledge that you:                        "
            echo "  • Understand the risks involved                                 "
            echo "  • Have backups of important data                                "
            echo "  • Accept full responsibility for any consequences               "
            echo "  • Release the author(s) from any liability                      "
            echo ""
            echo "══════════════════════════════════════════════════════════════════"
            echo -e "${NC}"
        fi
    fi
}

# Function to show disclaimer and get user acceptance
show_disclaimer() {
    # Show legal disclaimer
    rich_disclaimer "legal"
    echo
    read -p "Do you accept these terms and wish to proceed? (yes/no): " -r
    echo
    if [[ ! ${REPLY} =~ ^[Yy][Ee][Ss]$ ]]; then
        echo -e "${YELLOW}Operation cancelled by user. Exiting safely.${NC}"
        exit 0
    fi
    echo -e "${GREEN}Terms accepted. Proceeding with script execution...${NC}"
    echo
}

# Configuration variables (from config)
# These variables are loaded from config.json via the config_loader.sh script sourced above
# DS_CONFIG_DIR: Base directory where Docker Compose configurations are stored (from config.json: system.paths.config_dir)
# DS_INTERNET_PI_DIR: Directory containing the internet-pi Ansible repository (from config.json: system.paths.internet_pi_dir)  
# DS_NEW_HOSTNAME: The configured hostname for the Pi (from config.json: system.hostnames.new_hostname)
# shellcheck disable=SC2154  # DS_CONFIG_DIR is defined in sourced config_loader.sh
CONFIG_DIR="${DS_CONFIG_DIR}"
# shellcheck disable=SC2154  # DS_INTERNET_PI_DIR is defined in sourced config_loader.sh
INTERNET_PI_DIR="${DS_INTERNET_PI_DIR}"
# shellcheck disable=SC2154  # DS_NEW_HOSTNAME is defined in sourced config_loader.sh
NEW_HOSTNAME="${DS_NEW_HOSTNAME}"
# shellcheck disable=SC2154  # DS_GRAFANA_PORT/DS_PROMETHEUS_PORT come from config_loader.sh
GRAFANA_PORT="${DS_GRAFANA_PORT:-3030}"
# shellcheck disable=SC2154
PROMETHEUS_PORT="${DS_PROMETHEUS_PORT:-9090}"
# Ansible is installed by setup.sh into this virtual environment
ANSIBLE_VENV="${HOME}/.local/venv-ansible"
REBOOT_REQUIRED=false

# Hardware detection (with better error handling)
if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "Unknown Hardware")
else
    PI_MODEL="Unknown Hardware"
fi
if PI_MEMORY_OUTPUT=$(free -m 2>/dev/null | awk 'NR==2{printf "%.0f", $2/1024}' || true); then
    PI_MEMORY="${PI_MEMORY_OUTPUT:-Unknown}"
else
    PI_MEMORY="Unknown"
fi

# Detect if running on Raspberry Pi 5
if [[ "${PI_MODEL}" =~ "Raspberry Pi 5" ]]; then
    PI5_DETECTED=true
else
    PI5_DETECTED=false
fi

# Print functions for output formatting (using new logging system)
# Print functions for output formatting (using rich helpers only)
print_status() {
    rich_status "$1" "info"
}

print_success() {
    rich_status "$1" "success"
}

print_warning() {
    rich_status "$1" "warning"
}

print_error() {
    rich_status "$1" "error"
}

# Function to check if directory exists
check_directory() {
    local dir="$1"
    local service="$2"
    
    if [[ -d "${dir}" ]]; then
        return 0
    else
        print_warning "⚠️ ${service} directory not found at ${dir}"
        return 1
    fi
}

# Function to detect installed services
update_fastfetch() {
    print_status "🔧 Checking/Installing Fastfetch..."
    
    # Fastfetch release assets are named by CPU, e.g. fastfetch-linux-aarch64.deb
    local arch github_arch release_json latest_ver current_ver url tmp_deb
    arch=$(dpkg --print-architecture)
    case "${arch}" in
        "arm64") github_arch="aarch64" ;;
        "armhf") github_arch="armv7l" ;;
        *) github_arch="${arch}" ;;
    esac
    
    if ! release_json=$(curl -s --fail --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest); then
        print_warning "⚠️ Could not reach GitHub to check Fastfetch - skipping"
        return 0
    fi
    latest_ver=$(echo "${release_json}" | grep -m1 '"tag_name":' | cut -d '"' -f4 || true)
    latest_ver="${latest_ver#v}"
    
    current_ver=""
    if command -v fastfetch >/dev/null 2>&1; then
        current_ver=$(fastfetch --version 2>/dev/null | awk '{print $2}' || true)
    fi
    
    if [[ -n "${latest_ver}" && "${latest_ver}" == "${current_ver}" ]]; then
        print_success "✅ Fastfetch is already up to date (version ${current_ver})"
        return 0
    fi
    
    url=$(echo "${release_json}" | grep -o "https://[^\"]*linux-${github_arch}\.deb" | head -n 1 || true)
    if [[ -z "${url}" ]]; then
        url=$(echo "${release_json}" | grep -o "https://[^\"]*linux-${arch}\.deb" | head -n 1 || true)
    fi
    if [[ -z "${url}" ]]; then
        print_warning "⚠️ No Fastfetch package found for ${arch} - skipping"
        return 0
    fi
    
    print_status "⬇️ Installing Fastfetch ${latest_ver} (current: ${current_ver:-none})..."
    # apt only accepts local packages whose name ends in .deb
    tmp_deb=$(mktemp --suffix=.deb)
    chmod 644 "${tmp_deb}"
    if wget -qO "${tmp_deb}" "${url}" && sudo apt install -y "${tmp_deb}"; then
        print_success "✅ Fastfetch ${latest_ver} installed successfully"
    else
        print_warning "⚠️ Fastfetch update failed - keeping version ${current_ver:-none}"
    fi
    rm -f "${tmp_deb}"
    return 0
}

# Function to update (and if needed rebuild) the Ansible virtual environment.
# An OS upgrade (e.g. Debian bookworm -> trixie) changes the Python version
# the venv was built with, which leaves it broken until it is recreated.
update_ansible_venv() {
    local log_file
    if [[ ! -d "${ANSIBLE_VENV}" ]]; then
        if command -v ansible >/dev/null 2>&1; then
            print_warning "⚠️ Ansible found outside ${ANSIBLE_VENV} - leaving it to apt/pip"
        else
            print_warning "⚠️ Ansible not found - will skip Ansible-related updates"
        fi
        return 0
    fi
    
    log_file=$(mktemp)
    # Healthy only if its Python can actually load pip and Ansible. After an OS
    # upgrade the venv's python may still start but point at a newer Python
    # whose site-packages folder is empty.
    if ! "${ANSIBLE_VENV}/bin/python" -c "import pip, ansible" >/dev/null 2>&1; then
        print_warning "⚠️ Ansible's virtual environment is broken (usually after an OS upgrade changed the Python version) - rebuilding it..."
        if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import venv" >/dev/null 2>&1; then
            sudo apt install -y python3-venv python3-full >/dev/null 2>&1 || true
        fi
        rm -rf "${ANSIBLE_VENV}"
        if python3 -m venv "${ANSIBLE_VENV}" >>"${log_file}" 2>&1 && \
           "${ANSIBLE_VENV}/bin/pip" install --upgrade pip >>"${log_file}" 2>&1 && \
           "${ANSIBLE_VENV}/bin/pip" install "resolvelib>=0.5.3,<1.1.0" ansible >>"${log_file}" 2>&1; then
            sudo ln -sf "${ANSIBLE_VENV}/bin/ansible" /usr/local/bin/ansible
            sudo ln -sf "${ANSIBLE_VENV}/bin/ansible-playbook" /usr/local/bin/ansible-playbook
            sudo ln -sf "${ANSIBLE_VENV}/bin/ansible-galaxy" /usr/local/bin/ansible-galaxy
            print_success "✅ Ansible virtual environment rebuilt"
        else
            print_warning "⚠️ Could not rebuild Ansible's virtual environment. Last output:"
            tail -n 15 "${log_file}"
        fi
        rm -f "${log_file}"
        return 0
    fi
    
    print_status "📦 Updating Ansible in ${ANSIBLE_VENV}..."
    if "${ANSIBLE_VENV}/bin/pip" install --upgrade ansible "resolvelib>=0.5.3,<1.1.0" >"${log_file}" 2>&1; then
        print_success "✅ Ansible updated (virtual environment)"
    else
        print_warning "⚠️ Ansible update failed, continuing. Last output:"
        tail -n 15 "${log_file}"
    fi
    rm -f "${log_file}"
    return 0
}

detect_installed_services() {
    print_status "🔍 Detecting installed services..."
    
    # Check Pi-hole
    if check_directory "${CONFIG_DIR}/pi-hole" "Pi-hole" >/dev/null 2>&1; then
        PIHOLE_INSTALLED=true
        print_success "✅ Pi-hole detected"
    else
        PIHOLE_INSTALLED=false
        print_status "ℹ️  Pi-hole not installed"
    fi
    
    # Check Internet Monitoring
    if check_directory "${CONFIG_DIR}/internet-monitoring" "Internet Monitoring" >/dev/null 2>&1; then
        MONITORING_INSTALLED=true
        print_success "✅ Internet Monitoring detected"
    else
        MONITORING_INSTALLED=false
        print_status "ℹ️  Internet Monitoring not installed"
    fi
    
    # Check Shelly Plug
    if check_directory "${CONFIG_DIR}/shelly-plug-prometheus" "Shelly Plug" >/dev/null 2>&1; then
        SHELLY_INSTALLED=true
        print_success "✅ Shelly Plug Monitoring detected"
    else
        SHELLY_INSTALLED=false
        print_status "ℹ️  Shelly Plug Monitoring not installed"
    fi
    
    # Check Starlink
    if check_directory "${CONFIG_DIR}/starlink-exporter" "Starlink" >/dev/null 2>&1; then
        STARLINK_INSTALLED=true
        print_success "✅ Starlink Monitoring detected"
    else
        STARLINK_INSTALLED=false
        print_status "ℹ️  Starlink Monitoring not installed"
    fi
    
    # Check AirGradient
    if check_directory "${CONFIG_DIR}/airgradient-prometheus" "AirGradient" >/dev/null 2>&1; then
        AIRGRADIENT_INSTALLED=true
        print_success "✅ AirGradient Monitoring detected"
    else
        AIRGRADIENT_INSTALLED=false
        print_status "ℹ️  AirGradient Monitoring not installed"
    fi
    
    echo
    print_status "📋 Installed Services Summary:"
    [[ "${PIHOLE_INSTALLED}" = true ]] && PIHOLE_STATUS="✅ Installed" || PIHOLE_STATUS="❌ Not installed"
    echo -e "  �️  Pi-hole: ${PIHOLE_STATUS}"
    [[ "${MONITORING_INSTALLED}" = true ]] && MONITORING_STATUS="✅ Installed" || MONITORING_STATUS="❌ Not installed"
    echo -e "  � Internet Monitoring: ${MONITORING_STATUS}"
    [[ "${SHELLY_INSTALLED}" = true ]] && SHELLY_STATUS="✅ Installed" || SHELLY_STATUS="❌ Not installed"
    echo -e "  � Shelly Plug: ${SHELLY_STATUS}"
    [[ "${STARLINK_INSTALLED}" = true ]] && STARLINK_STATUS="✅ Installed" || STARLINK_STATUS="❌ Not installed"
    echo -e "  🛰️  Starlink: ${STARLINK_STATUS}"
    [[ "${AIRGRADIENT_INSTALLED}" = true ]] && AIRGRADIENT_STATUS="✅ Installed" || AIRGRADIENT_STATUS="❌ Not installed"
    echo -e "  🌡️  AirGradient: ${AIRGRADIENT_STATUS}"
    echo
}

# Function to update a Docker Compose service
update_service() {
    local service_dir="$1"
    local service_name="$2"
    
    if check_directory "${service_dir}" "${service_name}"; then
        print_status "🔄 Updating ${service_name}..."
        cd "${service_dir}" || {
            print_error "❌ Cannot access ${service_dir}"
            return 1
        }
        
        # Pull latest images
        print_status "📥 Pulling latest ${service_name} images..."
        if docker compose pull 2>/dev/null; then
            print_success "✅ Successfully pulled latest ${service_name} images"
        else
            print_warning "⚠️ Failed to pull ${service_name} images, continuing..."
            return 1
        fi
        
        # Restart containers with new images
        print_status "🚀 Restarting ${service_name} containers..."
        if docker compose up -d --no-deps 2>/dev/null; then
            print_success "✅ Successfully restarted ${service_name}"
        else
            print_warning "⚠️ Failed to restart ${service_name}, continuing..."
            return 1
        fi
        
        # Give containers time to start
        sleep 5
        
        # Verify containers are running
        COMPOSE_STATUS=$(docker compose ps)
        if echo "${COMPOSE_STATUS}" | grep -q "Up"; then
            print_success "✅ ${service_name} containers are running"
        else
            print_warning "⚠️ Some ${service_name} containers may not be running properly"
        fi
    else
        print_warning "⚠️ Skipping ${service_name} (not installed or directory not found)"
        return 1
    fi
}

# Function to clean up unused Docker resources
cleanup_docker() {
    print_status "🧹 Cleaning up unused Docker resources..."
    
    # Remove unused images only. (docker system prune would also delete any
    # stopped containers and unused networks, including ones you stopped on
    # purpose.)
    if docker image prune --all -f; then
        print_success "✅ Cleaned up unused Docker images"
    else
        print_warning "⚠️ Some Docker cleanup operations may have failed"
    fi
    
    # Show disk space saved
    print_status "💾 Current Docker disk usage:"
    docker system df
}

# Function to refresh PADD installation
refresh_padd() {
    print_status "📊 Refreshing PADD installation..."
    
    # Check if Pi-hole container is running
    DOCKER_PS_OUTPUT=$(docker ps)
    if echo "${DOCKER_PS_OUTPUT}" | grep -q pihole; then
        # Download and install PADD script directly to ensure latest version
        if docker exec pihole bash -c 'curl -sSL https://raw.githubusercontent.com/pi-hole/PADD/master/padd.sh -o /usr/local/bin/padd.sh && chmod +x /usr/local/bin/padd.sh' >/dev/null 2>&1; then
            print_success "✅ PADD refreshed successfully"
            
            # Create improved PADD alias that works properly in TTY
            PADD_ALIAS='alias padd="docker exec -it pihole /usr/local/bin/padd.sh"'
            PADD_ALIAS_FALLBACK='alias padd-simple="docker exec pihole pihole -c -e"'
            
            if ! grep -q "alias padd=" "${HOME}/.bashrc" 2>/dev/null; then
                {
                    echo ""
                    echo "# Pi-hole PADD aliases"
                    echo "${PADD_ALIAS}"
                    echo "${PADD_ALIAS_FALLBACK}"
                    echo "# Use 'padd' for full dashboard or 'padd-simple' for basic stats"
                } >> "${HOME}/.bashrc"
                print_success "✅ PADD aliases added to ~/.bashrc"
            fi
            
        else
            print_warning "⚠️ PADD refresh failed - container may not be ready"
        fi
    else
        print_warning "⚠️ Pi-hole container not running - skipping PADD refresh"
    fi
}

# Function to verify and update Pi 5 optimizations
verify_pi5_optimizations() {
    if [[ "${PI5_DETECTED}" == "true" ]]; then
        print_status "🎯 Verifying Raspberry Pi 5 optimizations..."
        
        # Check memory cgroups
        CMDLINE_PATH="/boot/firmware/cmdline.txt"
        if [[ ! -f "${CMDLINE_PATH}" ]]; then
            CMDLINE_PATH="/boot/cmdline.txt"  # Fallback for older Pi OS versions
        fi
        
        if [[ -f "${CMDLINE_PATH}" ]]; then
            if ! grep -q "cgroup_memory=1 cgroup_enable=memory" "${CMDLINE_PATH}"; then
                print_warning "⚠️ Memory cgroups not enabled - performance may be suboptimal"
                echo
                while true; do
                    read -p "Would you like to enable memory cgroups for better Docker performance? (Y/n): " -n 1 -r
                    echo
                    if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
                        print_status "🔧 Enabling memory cgroups..."
                        sudo sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' "${CMDLINE_PATH}"
                        print_success "✅ Memory cgroups enabled (reboot required)"
                        REBOOT_REQUIRED=true
                        break
                        elif [[ ${REPLY} =~ ^[Nn]$ ]]; then
                        print_status "Skipping memory cgroups configuration"
                        break
                    else
                        echo "Please answer y or n."
                    fi
                done
            else
                print_success "✅ Memory cgroups already enabled"
            fi
        fi
        
        # Check GPU memory split
        if [[ -f "/boot/firmware/config.txt" ]]; then
            if ! grep -q "gpu_mem=16" /boot/firmware/config.txt; then
                print_status "🎮 Optimizing GPU memory split for headless operation..."
                echo "gpu_mem=16" | sudo tee -a /boot/firmware/config.txt >/dev/null
                print_success "✅ GPU memory optimized (reboot required)"
                REBOOT_REQUIRED=true
            else
                print_success "✅ GPU memory already optimized"
            fi
        fi
        
        print_success "✅ Pi 5 optimization check complete"
        echo
    fi
}

# Function to update internet-pi repository and re-run playbook
update_via_playbook() {
    print_status "🔄 Updating via Ansible playbook method..."
    
    if [[ -d "${INTERNET_PI_DIR}" ]]; then
        cd "${INTERNET_PI_DIR}" || return 1
        
        # Update the repository
        print_status "📥 Updating internet-pi repository..."
        if git pull; then
            print_success "✅ Repository updated"
        else
            print_warning "⚠️ Repository update failed, continuing with existing version"
        fi
        
        # Prefer the Ansible virtual environment created by setup.sh
        local galaxy_cmd="ansible-galaxy"
        local playbook_cmd="ansible-playbook"
        if [[ -x "${ANSIBLE_VENV}/bin/ansible-playbook" ]]; then
            galaxy_cmd="${ANSIBLE_VENV}/bin/ansible-galaxy"
            playbook_cmd="${ANSIBLE_VENV}/bin/ansible-playbook"
        fi
        
        # Update Ansible collections
        print_status "📚 Updating Ansible collections..."
        if [[ -f "requirements.yml" ]]; then
            "${galaxy_cmd}" collection install -r requirements.yml --upgrade
        fi
        
        # Never let the playbook overwrite the hardened Pi-hole compose file
        if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
            ds_lock_internet_pi_pihole
        fi
        
        # Re-run the playbook (setup.sh writes the inventory file)
        local -a inventory_args=()
        [[ -f "inventory" ]] && inventory_args=(-i inventory)
        print_status "🚀 Re-running Ansible playbook..."
        if "${playbook_cmd}" "${inventory_args[@]}" main.yml; then
            print_success "✅ Playbook completed successfully"
            # The playbook re-renders Grafana and Shelly files (with default
            # passwords and 0644 permissions) - clean them up again
            ds_apply_stack_hardening --wait || print_warning "⚠️ Some hardening steps need attention (see above)"
            return 0
        else
            print_error "❌ Playbook failed"
            return 1
        fi
    else
        print_error "❌ Internet-pi directory not found at ${INTERNET_PI_DIR}"
        return 1
    fi
}

# Function to handle non-Docker updates when Docker is not available
check_non_docker_updates() {
    local exit_code=0
    
    print_status "🔍 Checking for non-Docker updates..."
    
    # --- Update Git repositories if they exist ---
    if [[ -d "${INTERNET_PI_DIR}" ]]; then
        print_status "📦 Updating internet-pi repository..."
        if cd "${INTERNET_PI_DIR}" && git pull --ff-only >/dev/null 2>&1; then
            print_success "✅ Internet-pi repository updated"
        else
            print_warning "⚠️ Failed to update internet-pi repository"
            exit_code=1
        fi
    fi
    
    # --- Update Ansible collections if available ---
    if command -v ansible-galaxy >/dev/null 2>&1; then
        print_status "📦 Updating Ansible collections..."
        if ansible-galaxy collection install --upgrade community.general community.docker; then
            print_success "✅ Ansible collections updated"
        else
            print_warning "⚠️ Failed to update Ansible collections"
            exit_code=1
        fi
    fi
    
    # --- Display current firmware and kernel info ---
    print_status "🔧 Checking Raspberry Pi firmware and kernel..."
    local current_firmware current_kernel
    if current_firmware_temp=$(vcgencmd version 2>/dev/null | head -1 || true); then
        current_firmware="${current_firmware_temp:-unknown}"
    else
        current_firmware="unknown"
    fi
    current_kernel=$(uname -r)
    
    print_status "📋 Current firmware: ${current_firmware}"
    print_status "📋 Current kernel: ${current_kernel}"
    
    # Show installed firmware revision if available
    local firmware_rev_file="/boot/firmware/.firmware_revision"
    if [[ -f "${firmware_rev_file}" ]]; then
        local installed_fw_rev
        installed_fw_rev=$(<"${firmware_rev_file}")
        print_status "📋 Firmware revision: ${installed_fw_rev:0:7}"
    fi
    
    # --- Safe EEPROM firmware check ---
    print_status "🔍 Checking EEPROM firmware updates..."
    if command -v rpi-eeprom-update >/dev/null 2>&1; then
        local eeprom_output
        if eeprom_output=$(sudo rpi-eeprom-update 2>&1); then
            if echo "${eeprom_output}" | grep -qi "update"; then
                print_warning "⚠️ EEPROM firmware update available!"
                echo -e "${BLUE}💡 To apply the EEPROM firmware update:${NC}"
                echo -e "   ${BLUE}sudo rpi-eeprom-update -a${NC}"
                echo -e "   ${YELLOW}• This will safely update the bootloader firmware${NC}"
                echo -e "   ${YELLOW}• Reboot will be required after the update${NC}"
                echo -e "   ${YELLOW}• Much safer than rpi-update${NC}"
                exit_code=2
            else
                print_success "✅ EEPROM firmware is up to date"
            fi
        else
            print_warning "⚠️ Unable to check EEPROM firmware status"
            exit_code=1
        fi
    else
        print_warning "⚠️ rpi-eeprom-update not available - cannot check firmware updates"
        print_status "💡 This tool is available on newer Raspberry Pi OS versions"
        exit_code=1
    fi
    
    print_status "💡 To enable full Death Star Pi functionality, please run the setup script."
    echo
    return "${exit_code}"
}

# Main update function
main() {
    # Start performance monitoring for entire script
    log_performance_start "update_total"
    
    # Show disclaimer and get user acceptance first
    show_disclaimer
    
    # Show main header
    rich_header "🚀 Death Star Pi Update" "Updating installed Death Star Pi components"
    
    print_status "This script will update any installed Death Star Pi components"
    if [[ "${PI5_DETECTED}" == "true" ]]; then
        print_status "🎯 Raspberry Pi 5 detected (${PI_MEMORY} GB RAM)"
    fi
    echo
    
    # Check if running as root
    if [[ ${EUID} -eq 0 ]]; then
        print_error "This script should not be run as root"
        exit 1
    fi
    
    # Update system packages first (continue even if this fails)
    print_status "📦 Updating system packages..."
    if sudo apt update && sudo apt full-upgrade -y; then
        print_success "✅ System packages updated"
    else
        print_warning "⚠️ System package update failed, continuing..."
    fi
    
    # Update Fastfetch if installed or install if not present
    update_fastfetch
    
    # Update Ansible (setup.sh installs it in a virtual environment)
    print_status "🔧 Checking Ansible installation..."
    update_ansible_venv
    
    # Tailscale is updated by apt (above) or by its own auto-update
    if command -v tailscale >/dev/null 2>&1; then
        local ts_version
        ts_version=$(tailscale version 2>/dev/null | head -n 1 || true)
        if tailscale status >/dev/null 2>&1; then
            print_success "✅ Tailscale ${ts_version} is connected"
        else
            print_warning "⚠️ Tailscale ${ts_version} is installed but not connected (check: tailscale status)"
        fi
    fi
    echo
    
    # Check if Docker is available (continue without Docker if not found)
    if ! command -v docker >/dev/null 2>&1; then
        print_warning "⚠️ Docker not found. Skipping Docker-related updates."
        print_status "💡 If you need Docker services, please run the setup script first."
        # Skip to non-Docker updates
        check_non_docker_updates
        return
    fi
    
    # Check Docker permissions
    if ! docker ps >/dev/null 2>&1; then
        print_error "❌ Cannot access Docker. You may need to add your user to the docker group:"
        print_error "    sudo usermod -aG docker \${USER}"
        print_error "    Then log out and log back in, or reboot."
        exit 1
    fi
    
    # Show current running containers
    print_status "📋 Current running containers:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo
    
    # Detect installed services
    detect_installed_services
    
    # Check if any services are installed
    if [[ "${PIHOLE_INSTALLED}" != "true" && "${MONITORING_INSTALLED}" != "true" && \
          "${SHELLY_INSTALLED}" != "true" && "${STARLINK_INSTALLED}" != "true" && \
          "${AIRGRADIENT_INSTALLED}" != "true" ]]; then
        print_error "❌ No Death Star Pi services detected!"
        print_status "💡 Make sure you've run the setup script first: ./setup.sh"
        exit 1
    fi
    
    # Ask user for update method
    echo -e "${YELLOW}Choose update method:${NC}"
    echo "1. 🐳 Docker Compose method (faster, component-by-component)"
    echo "2. 📦 Ansible Playbook method (complete refresh)"
    echo "3. ❌ Cancel"
    echo
    
    while true; do
        read -r -p "Enter your choice (1-3): " choice
        case ${choice} in
            1)
                UPDATE_METHOD="docker"
                break
            ;;
            2)
                UPDATE_METHOD="playbook"
                break
            ;;
            3)
                print_status "Update cancelled by user"
                exit 0
            ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, or 3."
            ;;
        esac
    done
    
    echo
    
    if [[ "${UPDATE_METHOD}" == "docker" ]]; then
        # Docker Compose update method
        print_status "🐳 Using Docker Compose update method"
        echo
        
        # Verify Pi 5 optimizations
        verify_pi5_optimizations
        
        # Keep passwords out of config files and Pi-hole hardened before the
        # containers are recreated (safe to run every time; --no-restart
        # because update_service recreates the containers anyway)
        if ! ds_apply_stack_hardening --no-restart; then
            print_warning "⚠️ Some hardening steps need attention (see above) - continuing with the update"
        fi
        echo
        
        # Update Pi-hole
        if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
            update_service "${CONFIG_DIR}/pi-hole" "Pi-hole"
            print_status "🔎 Waiting for Pi-hole DNS to answer..."
            if ds_wait_for_pihole_dns; then
                print_success "✅ Pi-hole is answering DNS queries"
            else
                print_error "❌ Pi-hole is not answering DNS - devices using it (including your tailnet) cannot resolve names"
                print_status "💡 Check: cd ${CONFIG_DIR}/pi-hole && docker compose logs --tail 50"
            fi
            echo
        fi
        
        # Update Internet Monitoring (Grafana, Prometheus, etc.)
        if [[ "${MONITORING_INSTALLED}" == "true" ]]; then
            update_service "${CONFIG_DIR}/internet-monitoring" "Internet Monitoring"
            echo
        fi
        
        # Update optional services only if they're installed
        if [[ "${SHELLY_INSTALLED}" == "true" ]]; then
            update_service "${CONFIG_DIR}/shelly-plug-prometheus" "Shelly Plug Monitoring"
            echo
        fi
        
        if [[ "${STARLINK_INSTALLED}" == "true" ]]; then
            update_service "${CONFIG_DIR}/starlink-exporter" "Starlink Monitoring"
            echo
        fi
        
        if [[ "${AIRGRADIENT_INSTALLED}" == "true" ]]; then
            update_service "${CONFIG_DIR}/airgradient-prometheus" "AirGradient Monitoring"
            echo
        fi
        
        # Clean up unused Docker resources
        cleanup_docker
        
        # Refresh PADD installation
        refresh_padd
        
        elif [[ "${UPDATE_METHOD}" == "playbook" ]]; then
        # Ansible playbook method
        print_status "📦 Using Ansible Playbook update method"
        echo
        
        # Verify Pi 5 optimizations before playbook
        verify_pi5_optimizations
        
        if update_via_playbook; then
            print_success "✅ Playbook update completed"
        else
            print_error "❌ Playbook update failed"
            exit 1
        fi
    fi
    
    echo
    print_status "🔍 Checking updated services..."
    
    # Check service status
    sleep 10  # Give services time to fully start
    
    # Get Pi's IP address
    if PI_IP_TEMP=$(hostname -I | awk '{print $1}' || true); then
        if [[ -z "${PI_IP_TEMP}" ]]; then
            PI_IP="<YOUR_PI_IP>"
        else
            PI_IP="${PI_IP_TEMP}"
        fi
    else
        PI_IP="<YOUR_PI_IP>"
    fi
    
    # Check Pi-hole
    if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
        DOCKER_PS_PIHOLE=$(docker ps)
        if echo "${DOCKER_PS_PIHOLE}" | grep -q pihole; then
            print_success "✅ Pi-hole is running"
        else
            print_warning "⚠️ Pi-hole container not found"
        fi
    fi
    
    # Check Grafana
    if [[ "${MONITORING_INSTALLED}" == "true" ]]; then
        DOCKER_PS_MONITORING=$(docker ps)
        if echo "${DOCKER_PS_MONITORING}" | grep -q grafana; then
            print_success "✅ Grafana is running"
        else
            print_warning "⚠️ Grafana container not found"
        fi
        
        # Check Prometheus
        if echo "${DOCKER_PS_MONITORING}" | grep -q prometheus; then
            print_success "✅ Prometheus is running"
        else
            print_warning "⚠️ Prometheus container not found"
        fi
    fi
    
    # Final status
    echo
    print_success "🎉 Death Star Pi Update Complete!"
    
    # Check if reboot is required
    if [[ "${REBOOT_REQUIRED}" == "true" ]]; then
        echo
        echo -e "${YELLOW}⚠️  System optimizations were applied that require a reboot.${NC}"
        echo
        while true; do
            read -p "Would you like to reboot now? (Y/n): " -n 1 -r
            echo
            if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
                echo -e "${BLUE}🔄 Rebooting in 5 seconds... (Ctrl+C to cancel)${NC}"
                sleep 5
                sudo reboot
                exit 0
                elif [[ ${REPLY} =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}⏭️  Skipping reboot. Please reboot later for optimizations to take effect.${NC}"
                break
            else
                echo "Please enter Y or N"
            fi
        done
    fi
    
    echo
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                 🌟 DEATH STAR UPDATED & OPERATIONAL 🌟         ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${GREEN}Your updated services are accessible at:${NC}"
    if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
        echo -e "  🕳️  Pi-hole Admin:  http://${NEW_HOSTNAME}/admin"
    fi
    if [[ "${MONITORING_INSTALLED}" == "true" ]]; then
        echo -e "  📊 Grafana:        http://${NEW_HOSTNAME}:${GRAFANA_PORT}"
        echo -e "  📈 Prometheus:     http://${NEW_HOSTNAME}:${PROMETHEUS_PORT}"
    fi
    echo
    echo -e "${GREEN}Alternative access via IP:${NC}"
    if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
        echo -e "  🕳️  Pi-hole Admin:  http://${PI_IP}/admin"
    fi
    if [[ "${MONITORING_INSTALLED}" == "true" ]]; then
        echo -e "  📊 Grafana:        http://${PI_IP}:${GRAFANA_PORT}"
        echo -e "  📈 Prometheus:     http://${PI_IP}:${PROMETHEUS_PORT}"
    fi
    echo
    echo -e "${BLUE}📊 Updated Components:${NC}"
    echo -e "  • System packages (apt update/upgrade)"
    echo -e "  • Ansible (latest version, in its virtual environment)"
    if [[ "${PI5_DETECTED}" == "true" ]]; then
        echo -e "  • Raspberry Pi 5 optimizations verified"
    fi
    if [[ "${UPDATE_METHOD}" == "docker" ]]; then
        if [[ "${PIHOLE_INSTALLED}" == "true" ]]; then
            echo -e "  • Pi-hole (latest Docker images)"
        fi
        if [[ "${MONITORING_INSTALLED}" == "true" ]]; then
            echo -e "  • Grafana (latest Docker images)"
            echo -e "  • Prometheus (latest Docker images)"
            echo -e "  • Internet monitoring exporters"
        fi
        if [[ "${SHELLY_INSTALLED}" == "true" ]]; then
            echo -e "  • Shelly Plug monitoring"
        fi
        if [[ "${STARLINK_INSTALLED}" == "true" ]]; then
            echo -e "  • Starlink monitoring"
        fi
        if [[ "${AIRGRADIENT_INSTALLED}" == "true" ]]; then
            echo -e "  • AirGradient monitoring"
        fi
        echo -e "  • PADD (Pi-hole Admin Dashboard Display)"
    else
        echo -e "  • Complete system refresh via Ansible"
        echo -e "  • All components updated to latest versions"
        echo -e "  • Configuration files refreshed"
        echo -e "  • internet-pi repository updated"
    fi
    echo
    echo -e "${YELLOW}💡 Post-Update Tips:${NC}"
    echo -e "  • Check Grafana dashboards for any layout changes"
    echo -e "  • Verify Pi-hole blocklists are still active"
    echo -e "  • Monitor logs for any issues: ${BLUE}docker logs <container_name>${NC}"
    echo -e "  • System packages have been updated to latest versions"
    echo -e "  • Ansible has been updated to latest version"
    if [[ "${PI5_DETECTED}" == "true" ]]; then
        echo -e "  • Use ${BLUE}padd${NC} command to view updated Pi-hole dashboard"
        echo -e "  • Monitor Pi 5 performance: ${BLUE}htop${NC} or ${BLUE}iotop${NC}"
        echo -e "  • Pi 5 optimizations verified and current"
    fi
    if [[ "${REBOOT_REQUIRED}" == "true" ]]; then
        echo -e "  • ${YELLOW}Reboot when convenient to apply system optimizations${NC}"
    fi
    echo -e "  • Consider running this update script monthly for best security"
    echo
    
    # End performance monitoring
    log_performance_end "update_total"
    
    echo -e "${GREEN}May the Force continue to be with you! 🌟${NC}"
}

# Run main function
main "$@"
