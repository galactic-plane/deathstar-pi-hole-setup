#!/bin/bash
#===============================================================================
# File: stack_hardening.sh
# Project: Death Star Pi-hole Setup
# Description: Keeps the Docker stacks deployed by internet-pi free of
#              plain-text passwords and in a hardened layout. Every function
#              is safe to run any number of times.
#
#              Pi-hole (~/pi-hole)
#                - Admin password only in ~/pi-hole/.env (mode 600); the
#                  compose file reads it as ${PIHOLE_PASSWORD} for Pi-hole
#                  and pihole-exporter.
#                - DNS listening mode 'all' (answers VPN/Tailscale clients),
#                  no DHCP port, TZ follows the system time zone.
#                - pihole-exporter's port is bound to 127.0.0.1 (Prometheus
#                  scrapes it over the Docker network).
#              Grafana (~/internet-monitoring)
#                - GF_SECURITY_ADMIN_PASSWORD is only read on Grafana's very
#                  first start. Once Grafana has created its database (which
#                  stores a hashed copy), the plain-text copies are removed
#                  from grafana/config.monitoring and config.yml.
#              Shelly plug exporter (~/shelly-plug-prometheus)
#                - HTTP password only in ~/shelly-plug-prometheus/.env; the
#                  compose file reads it as ${SHELLY_HTTP_PASSWORD}.
#              internet-pi config.yml
#                - pihole_enable: false once Pi-hole exists, so the playbook
#                  never overwrites ~/pi-hole again; the Prometheus scrape
#                  job for pihole-exporter is kept via
#                  prometheus_extra_scrape_configs; no plain-text passwords;
#                  mode 600.
#
#              Should be sourced by other scripts (setup.sh, update.sh,
#              status.sh). Uses print_* helpers when the caller has them.
#
# Target Environment:
#   OS: Raspberry Pi OS aarch64
#   Host: Raspberry Pi 5 Model B Rev 1.1
#   Shell: bash
#   Dependencies: docker compose, sed, grep
#
# Author: galactic-plane
# Repository: https://github.com/galactic-plane/deathstar-pi-hole-setup
# License: See LICENSE file
#===============================================================================

# Pipelines in command substitutions are intentional and guarded
# shellcheck disable=SC2312
# Literal ${VAR} placeholders in single quotes are intentional throughout
# shellcheck disable=SC2016

# Set to "true" by the ds_harden_* functions when they changed a file
DSH_CHANGED="false"

#-------------------------------------------------------------------------------
# Output helpers (fall back to plain echo when the caller has no print_*)
#-------------------------------------------------------------------------------
_dsh_info() { if declare -F print_status  >/dev/null; then print_status "$1";  else echo "[INFO] $1"; fi; }
_dsh_ok()   { if declare -F print_success >/dev/null; then print_success "$1"; else echo "[OK] $1"; fi; }
_dsh_warn() { if declare -F print_warning >/dev/null; then print_warning "$1"; else echo "[WARN] $1"; fi; }
_dsh_err()  { if declare -F print_error   >/dev/null; then print_error "$1";   else echo "[ERROR] $1" >&2; fi; }
_dsh_fix()  { if declare -F print_fix     >/dev/null; then print_fix "$1";     else echo "   Fix: $1"; fi; }

#-------------------------------------------------------------------------------
# Paths
#-------------------------------------------------------------------------------
_dsh_base()                  { echo "${DS_CONFIG_DIR:-${HOME}}"; }
ds_pihole_dir()              { echo "$(_dsh_base)/pi-hole"; }
ds_monitoring_dir()          { echo "$(_dsh_base)/internet-monitoring"; }
ds_shelly_dir()              { echo "$(_dsh_base)/shelly-plug-prometheus"; }
ds_internet_pi_config()      { echo "${DS_INTERNET_PI_DIR:-${HOME}/Repo/internet-pi}/config.yml"; }
ds_grafana_env_file()        { echo "$(ds_monitoring_dir)/grafana/config.monitoring"; }

# Run docker, falling back to sudo when the docker group is not active yet
_dsh_docker() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

#-------------------------------------------------------------------------------
# Small text helpers
#-------------------------------------------------------------------------------

# Remove one pair of matching surrounding quotes from a value
_dsh_unquote() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]] || \
           [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf '%s' "${value}"
}

# Print the (unquoted) value of "key: value" from a YAML/compose file.
# Returns 1 if the key is not present.
_dsh_yaml_value() {
    local file="$1"
    local key="$2"
    local line value
    line=$(grep -m1 -E "^[[:space:]]*${key}:" "${file}" 2>/dev/null) || return 1
    value="${line#*:}"
    value="${value#"${value%%[![:space:]]*}"}"   # trim leading spaces
    value="${value%"${value##*[![:space:]]}"}"   # trim trailing spaces
    _dsh_unquote "${value}"
}

# Replace a file's contents with a temp file's, keeping the original owner
# and mode. Removes the temp file. Returns 0 if the content changed.
_dsh_replace_if_changed() {
    local tmp="$1"
    local target="$2"
    if cmp -s "${tmp}" "${target}"; then
        rm -f "${tmp}"
        return 1
    fi
    cat "${tmp}" > "${target}"
    rm -f "${tmp}"
    return 0
}

# A password is usable in .env/YAML here if it has no single quote
ds_password_is_valid() {
    [[ "$1" != *"'"* ]]
}

#-------------------------------------------------------------------------------
# .env helpers (files are parsed, never sourced)
#-------------------------------------------------------------------------------

# Function: ds_env_read <dir> <VAR>
# Prints the value of VAR from <dir>/.env. Returns 1 if the file or VAR is
# missing. An empty value counts as present.
ds_env_read() {
    local env_file="$1/.env"
    local var="$2"
    local line
    [[ -f "${env_file}" ]] || return 1
    line=$(grep -E "^[[:space:]]*${var}=" "${env_file}" 2>/dev/null | tail -n 1) || return 1
    _dsh_unquote "${line#*=}"
}

# Function: ds_env_write <dir> <VAR> <value> [allow-empty]
# Stores VAR='value' in <dir>/.env with mode 600, keeping other variables.
ds_env_write() {
    local dir="$1"
    local var="$2"
    local value="$3"
    local allow_empty="${4:-}"
    local env_file="${dir}/.env"
    local tmp

    if [[ -z "${value}" && "${allow_empty}" != "allow-empty" ]]; then
        _dsh_err "Refusing to store an empty ${var}"
        return 1
    fi
    if ! ds_password_is_valid "${value}"; then
        _dsh_err "Values containing a single quote (') are not supported in .env files - please choose another"
        return 1
    fi

    mkdir -p "${dir}" || return 1
    tmp=$(mktemp "${dir}/.env.XXXXXX") || return 1
    chmod 600 "${tmp}"
    if [[ -f "${env_file}" ]]; then
        grep -v -E "^[[:space:]]*${var}=" "${env_file}" > "${tmp}" || true
    else
        {
            echo "# Private settings for this Docker Compose project."
            echo "# Managed by deathstar-pi-hole-setup - keep this file private (chmod 600)."
        } > "${tmp}"
    fi
    printf "%s='%s'\n" "${var}" "${value}" >> "${tmp}"
    mv -f "${tmp}" "${env_file}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${env_file}"

    # Keep .env out of git status when the folder is a git clone
    if [[ -d "${dir}/.git/info" ]] && ! grep -qxF ".env" "${dir}/.git/info/exclude" 2>/dev/null; then
        echo ".env" >> "${dir}/.git/info/exclude"
    fi
}

# Function: ds_env_ensure <dir> <VAR> <label> <compose-key> [allow-empty]
# Makes sure <dir>/.env holds VAR. In order: keep an existing value; move a
# plain-text value out of <dir>/docker-compose.yml (<compose-key>); use the
# caller's $VAR; or prompt (interactive shells only).
ds_env_ensure() {
    local dir="$1"
    local var="$2"
    local label="$3"
    local compose_key="$4"
    local allow_empty="${5:-}"
    local compose="${dir}/docker-compose.yml"
    local literal first second

    if ds_env_read "${dir}" "${var}" >/dev/null; then
        chmod 600 "${dir}/.env" 2>/dev/null || true
        return 0
    fi

    # Migrate a value that internet-pi wrote into docker-compose.yml
    if [[ -f "${compose}" ]] && literal=$(_dsh_yaml_value "${compose}" "${compose_key}"); then
        if [[ "${literal}" != *'${'"${var}"* ]]; then
            literal="${literal//\$\$/\$}"   # undo Compose's $$ escaping
            if [[ -n "${literal}" || "${allow_empty}" == "allow-empty" ]]; then
                if ds_env_write "${dir}" "${var}" "${literal}" "${allow_empty}"; then
                    _dsh_ok "Moved the ${label} out of docker-compose.yml into ${dir}/.env"
                    return 0
                fi
                return 1
            fi
        fi
    fi

    # Use a value provided by the caller (e.g. collected by setup.sh)
    if [[ -n "${!var:-}" ]]; then
        ds_env_write "${dir}" "${var}" "${!var}" "${allow_empty}"
        return $?
    fi

    if [[ -t 0 ]]; then
        while true; do
            read -r -s -p "Enter the ${label} to store in ${dir}/.env: " first
            echo
            read -r -s -p "Confirm: " second
            echo
            if [[ "${first}" != "${second}" ]]; then
                _dsh_warn "Entries did not match - try again"
            elif [[ -z "${first}" && "${allow_empty}" != "allow-empty" ]]; then
                _dsh_warn "A value is required - try again"
            elif ds_env_write "${dir}" "${var}" "${first}" "${allow_empty}"; then
                return 0
            fi
        done
    fi

    _dsh_err "No ${label} found. Create ${dir}/.env containing: ${var}='...'"
    return 1
}

# Point "<key>: ..." at '${VAR}' in a compose file. Validates with Docker
# Compose and restores a timestamped backup if the result is rejected.
# Usage: _dsh_compose_rewrite <dir> <sed -E expression>...
_dsh_compose_rewrite() {
    local dir="$1"
    shift
    local compose="${dir}/docker-compose.yml"
    local backup tmp
    local -a sed_args=()
    local expr

    for expr in "$@"; do
        sed_args+=(-e "${expr}")
    done

    tmp=$(mktemp) || return 1
    sed -E "${sed_args[@]}" "${compose}" > "${tmp}"
    if cmp -s "${tmp}" "${compose}"; then
        rm -f "${tmp}"
        return 0
    fi

    backup="${compose}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "${compose}" "${backup}" || { rm -f "${tmp}"; return 1; }
    cat "${tmp}" > "${compose}"     # keep the original owner and mode
    rm -f "${tmp}"

    if ! (cd "${dir}" && _dsh_docker compose config -q) >/dev/null 2>&1; then
        cp -p "${backup}" "${compose}"
        _dsh_err "Docker Compose rejected the updated ${compose} - original restored from ${backup}"
        return 1
    fi

    DSH_CHANGED="true"
    _dsh_ok "Updated ${compose} (backup: ${backup})"
    return 0
}

# Restart a compose project after a change (unless --no-restart was given)
_dsh_restart_if_changed() {
    local dir="$1"
    local name="$2"
    local flag="${3:-}"
    if [[ "${DSH_CHANGED}" != "true" || "${flag}" == "--no-restart" ]]; then
        return 0
    fi
    _dsh_info "Restarting ${name} to apply the updated configuration..."
    if (cd "${dir}" && _dsh_docker compose up -d); then
        _dsh_ok "${name} restarted"
    else
        _dsh_err "${name} failed to restart - check: cd ${dir} && docker compose logs"
        return 1
    fi
}

#===============================================================================
# Pi-hole
#===============================================================================

# Compatibility wrappers used by setup.sh
ds_read_env_password()  { ds_env_read "$(ds_pihole_dir)" "PIHOLE_PASSWORD"; }
ds_write_env_password() { ds_env_write "$(ds_pihole_dir)" "PIHOLE_PASSWORD" "$1"; }

#-------------------------------------------------------------------------------
# Function: ds_harden_pihole [--no-restart]
#-------------------------------------------------------------------------------
ds_harden_pihole() {
    local dir compose tz password_ref
    dir="$(ds_pihole_dir)"
    compose="${dir}/docker-compose.yml"
    DSH_CHANGED="false"

    [[ -f "${compose}" ]] || return 0

    if grep -qE '^[[:space:]]*-[[:space:]]*"?(FTLCONF_|PIHOLE_PASSWORD)' "${compose}"; then
        _dsh_warn "${compose} uses list-style environment entries; please convert it to 'KEY: value' form by hand"
        return 1
    fi

    ds_env_ensure "${dir}" "PIHOLE_PASSWORD" "Pi-hole admin password" "FTLCONF_webserver_api_password" || return 1

    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ -z "${tz}" && -f /etc/timezone ]]; then
        tz=$(head -n 1 /etc/timezone)
    fi

    password_ref="'\${PIHOLE_PASSWORD}'"
    local -a exprs=(
        "s|^([[:space:]]*FTLCONF_webserver_api_password:).*\$|\\1 ${password_ref}|"
        "s|^([[:space:]]*PIHOLE_PASSWORD:).*\$|\\1 ${password_ref}|"
        "s|^([[:space:]]*FTLCONF_dns_listeningMode:).*\$|\\1 'all'|"
        '/^[[:space:]]*FTLCONF_dns_interface:/d'
        "/^[[:space:]]*-[[:space:]]*[\"']?67:67\\/udp[\"']?[[:space:]]*\$/d"
        "s|^([[:space:]]*-[[:space:]]*)[\"']?9617:9617[\"']?[[:space:]]*\$|\\1\"127.0.0.1:9617:9617\"|"
    )
    if [[ -n "${tz}" ]]; then
        exprs+=("s|^([[:space:]]*TZ:).*\$|\\1 '${tz}'|")
    fi

    _dsh_compose_rewrite "${dir}" "${exprs[@]}" || return 1
    _dsh_restart_if_changed "${dir}" "Pi-hole" "${1:-}"
}

#===============================================================================
# Shelly plug exporter
#===============================================================================

#-------------------------------------------------------------------------------
# Function: ds_harden_shelly [--no-restart]
#-------------------------------------------------------------------------------
ds_harden_shelly() {
    local dir
    dir="$(ds_shelly_dir)"
    DSH_CHANGED="false"

    [[ -f "${dir}/docker-compose.yml" ]] || return 0

    ds_env_ensure "${dir}" "SHELLY_HTTP_PASSWORD" "Shelly plug HTTP password" "SHELLY_HTTP_PASSWORD" allow-empty || return 1
    _dsh_compose_rewrite "${dir}" \
        "s|^([[:space:]]*SHELLY_HTTP_PASSWORD:).*\$|\\1 '\${SHELLY_HTTP_PASSWORD}'|" || return 1
    _dsh_restart_if_changed "${dir}" "Shelly plug exporter" "${1:-}"
}

#===============================================================================
# Grafana
#===============================================================================

# Returns 0 when Grafana has created its database (admin password is stored
# there, hashed). Optional $1: seconds to wait for it.
ds_grafana_initialized() {
    local wait_seconds="${1:-0}"
    local dir cid waited=0
    dir="$(ds_monitoring_dir)"
    [[ -f "${dir}/docker-compose.yml" ]] || return 1

    while true; do
        cid=$(cd "${dir}" && _dsh_docker compose ps -q grafana 2>/dev/null | head -n 1)
        if [[ -n "${cid}" ]] && _dsh_docker exec "${cid}" test -s /var/lib/grafana/grafana.db >/dev/null 2>&1; then
            return 0
        fi
        [[ "${waited}" -ge "${wait_seconds}" ]] && return 1
        sleep 5
        waited=$((waited + 5))
    done
}

#-------------------------------------------------------------------------------
# Function: ds_harden_grafana [--wait]
# Removes the first-start admin password from grafana/config.monitoring and
# config.yml once Grafana's database exists, and makes the file private.
#-------------------------------------------------------------------------------
ds_harden_grafana() {
    local env_file cfg tmp wait_seconds=0
    env_file="$(ds_grafana_env_file)"
    cfg="$(ds_internet_pi_config)"
    DSH_CHANGED="false"

    [[ -f "${env_file}" ]] || return 0
    chmod 600 "${env_file}" 2>/dev/null || true
    [[ "${1:-}" == "--wait" ]] && wait_seconds=90

    if ! grep -qE '^[[:space:]]*GF_SECURITY_ADMIN_PASSWORD=' "${env_file}" && \
       ! { [[ -f "${cfg}" ]] && grep -qE '^[[:space:]]*monitoring_grafana_admin_password:' "${cfg}"; }; then
        return 0
    fi

    if ! ds_grafana_initialized "${wait_seconds}"; then
        _dsh_warn "Grafana has not finished its first start - leaving its first-start password in place for now (run ./update.sh later)"
        return 0
    fi

    tmp=$(mktemp) || return 1
    grep -v -E '^[[:space:]]*GF_SECURITY_ADMIN_PASSWORD=' "${env_file}" > "${tmp}" || true
    if _dsh_replace_if_changed "${tmp}" "${env_file}"; then
        DSH_CHANGED="true"
        _dsh_ok "Removed the first-start Grafana password from ${env_file} (Grafana keeps its own hashed copy)"
    fi

    if [[ -f "${cfg}" ]]; then
        tmp=$(mktemp) || return 1
        grep -v -E '^[[:space:]]*monitoring_grafana_admin_password:' "${cfg}" > "${tmp}" || true
        if _dsh_replace_if_changed "${tmp}" "${cfg}"; then
            _dsh_ok "Removed the Grafana password from ${cfg}"
        fi
    fi
    # No restart needed: the password is only read on Grafana's first start.
    return 0
}

#===============================================================================
# internet-pi config.yml
#===============================================================================

#-------------------------------------------------------------------------------
# Function: ds_lock_internet_pi_pihole
# Once Pi-hole exists: pihole_enable: false (so the playbook never overwrites
# ~/pi-hole), keep the Prometheus scrape job for pihole-exporter (internet-pi
# only adds it while pihole_enable is true), drop any plain-text Pi-hole
# password, point the Shelly password at its .env, default the ping
# interval to 30s, and make the file private.
#-------------------------------------------------------------------------------
ds_lock_internet_pi_pihole() {
    local cfg tmp
    cfg="$(ds_internet_pi_config)"
    [[ -f "${cfg}" ]] || return 0
    [[ -f "$(ds_pihole_dir)/docker-compose.yml" ]] || return 0

    tmp=$(mktemp) || return 1
    # Drop: legacy internet_pi_* keys from older setup.sh versions (internet-pi
    # ignores them; one held an unsalted password hash), any pihole_enable
    # other than false, any Pi-hole password, and an empty
    # prometheus_extra_scrape_configs placeholder
    grep -v -E \
        -e '^internet_pi_[A-Za-z0-9_]+:' \
        -e '^[[:space:]]*pihole_enable:[[:space:]]*([^f[:space:]]|f[^a])' \
        -e '^[[:space:]]*pihole_password:' \
        -e "^prometheus_extra_scrape_configs:[[:space:]]*(''|\"\")?[[:space:]]*\$" \
        "${cfg}" > "${tmp}" || true

    # Shelly password: always the .env placeholder
    sed -i -E "s|^([[:space:]]*shelly_plug_http_password:).*\$|\\1 '\${SHELLY_HTTP_PASSWORD}'|" "${tmp}"

    if ! grep -qE '^[[:space:]]*pihole_enable:[[:space:]]*false' "${tmp}"; then
        {
            echo "# Pi-hole is managed by deathstar-pi-hole-setup after the first deploy; this stops the playbook overwriting ~/pi-hole."
            echo "pihole_enable: false"
        } >> "${tmp}"
    fi

    if ! grep -qE '^prometheus_extra_scrape_configs:' "${tmp}"; then
        {
            echo "# Keeps Prometheus scraping pihole-exporter (internet-pi only adds this job while pihole_enable is true)."
            echo "prometheus_extra_scrape_configs: |"
            echo "  - job_name: 'pihole'"
            echo "    static_configs:"
            echo "      - targets: ['pihole-exporter:9617']"
        } >> "${tmp}"
    elif ! grep -q "pihole-exporter:9617" "${tmp}"; then
        _dsh_warn "config.yml has custom prometheus_extra_scrape_configs without a pihole-exporter job - add one so Pi-hole metrics survive a playbook run"
    fi

    if ! grep -qE '^[[:space:]]*monitoring_ping_interval:' "${tmp}"; then
        echo "monitoring_ping_interval: 30s" >> "${tmp}"
    fi

    if _dsh_replace_if_changed "${tmp}" "${cfg}"; then
        _dsh_ok "internet-pi config.yml updated (playbook will not manage Pi-hole; no plain-text passwords)"
    fi
    chmod 600 "${cfg}" 2>/dev/null || true
}

#===============================================================================
# Everything
#===============================================================================

#-------------------------------------------------------------------------------
# Function: ds_apply_stack_hardening [--no-restart] [--wait]
# Runs every hardening step for whichever stacks are installed.
#-------------------------------------------------------------------------------
ds_apply_stack_hardening() {
    local restart_flag="" wait_flag="" arg rc=0
    for arg in "$@"; do
        case "${arg}" in
            --no-restart) restart_flag="--no-restart" ;;
            --wait) wait_flag="--wait" ;;
            *) ;;
        esac
    done

    _dsh_info "🔐 Checking that service passwords are kept out of config files..."
    ds_harden_pihole "${restart_flag}" || rc=1
    ds_harden_shelly "${restart_flag}" || rc=1
    ds_harden_grafana "${wait_flag}" || rc=1
    ds_lock_internet_pi_pihole || rc=1

    if [[ "${rc}" -eq 0 ]]; then
        _dsh_ok "Service passwords are stored safely"
    fi
    return "${rc}"
}

#-------------------------------------------------------------------------------
# Function: ds_wait_for_pihole_dns
# Wait up to ~60s for Pi-hole to answer DNS on this host
#-------------------------------------------------------------------------------
ds_wait_for_pihole_dns() {
    local attempt
    for attempt in $(seq 1 12); do
        if command -v dig >/dev/null 2>&1; then
            if dig @127.0.0.1 +time=2 +tries=1 +short pi-hole.net 2>/dev/null | grep -q .; then
                return 0
            fi
        elif nslookup pi-hole.net 127.0.0.1 >/dev/null 2>&1; then
            return 0
        fi
        if [[ "${attempt}" -lt 12 ]]; then
            sleep 5
        fi
    done
    return 1
}

#===============================================================================
# Read-only checks (status.sh)
#===============================================================================

# Warn about a file that should be mode 600. Returns 1 if it is not.
_dsh_check_mode_600() {
    local file="$1"
    local what="$2"
    local mode
    mode=$(stat -c '%a' "${file}" 2>/dev/null || echo "?")
    if [[ "${mode}" == "600" ]]; then
        return 0
    fi
    _dsh_warn "${file} is mode ${mode} - should be 600 (${what})"
    _dsh_fix "chmod 600 ${file}"
    return 1
}

#-------------------------------------------------------------------------------
# Function: ds_check_stack_hardening
# Returns: number of problems found (0 = all good)
#-------------------------------------------------------------------------------
ds_check_stack_hardening() {
    local problems=0
    local dir compose plain running_mode cfg env_file

    # --- Pi-hole ---
    dir="$(ds_pihole_dir)"
    compose="${dir}/docker-compose.yml"
    if [[ -f "${compose}" ]]; then
        if ds_env_read "${dir}" "PIHOLE_PASSWORD" >/dev/null; then
            _dsh_check_mode_600 "${dir}/.env" "it holds the Pi-hole password" && \
                _dsh_ok "Pi-hole password is stored in ${dir}/.env" || problems=$((problems + 1))
        else
            _dsh_warn "No PIHOLE_PASSWORD in ${dir}/.env"
            _dsh_fix "Run ./update.sh (Docker method) to move the password into .env"
            problems=$((problems + 1))
        fi

        plain=$(grep -E '^[[:space:]]*(FTLCONF_webserver_api_password|PIHOLE_PASSWORD):' "${compose}" 2>/dev/null | grep -vF '${PIHOLE_PASSWORD}' || true)
        if [[ -z "${plain}" ]]; then
            _dsh_ok "Pi-hole compose file has no plain-text password"
        else
            _dsh_warn "Pi-hole compose file contains a plain-text password"
            _dsh_fix "Run ./update.sh (Docker method) to move it into .env"
            problems=$((problems + 1))
        fi

        if grep -qE '^[[:space:]]*-[[:space:]]*["'"'"']?9617:9617' "${compose}"; then
            _dsh_warn "pihole-exporter is published on all interfaces (port 9617, no login)"
            _dsh_fix "Run ./update.sh (Docker method) to bind it to 127.0.0.1"
            problems=$((problems + 1))
        fi

        running_mode=$(_dsh_docker exec pihole pihole-FTL --config dns.listeningMode 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "${running_mode^^}" == "ALL" ]]; then
            _dsh_ok "Pi-hole DNS listening mode is ALL (answers tailnet/VPN clients)"
        elif [[ -n "${running_mode}" ]]; then
            _dsh_warn "Pi-hole DNS listening mode is ${running_mode} - clients outside the LAN (e.g. Tailscale) are ignored"
            _dsh_fix "Run ./update.sh (Docker method) to switch it to ALL"
            problems=$((problems + 1))
        else
            _dsh_warn "Could not read Pi-hole's DNS listening mode (is the container running?)"
            problems=$((problems + 1))
        fi
    fi

    # --- Grafana ---
    env_file="$(ds_grafana_env_file)"
    if [[ -f "${env_file}" ]]; then
        if grep -qE '^[[:space:]]*GF_SECURITY_ADMIN_PASSWORD=' "${env_file}"; then
            _dsh_warn "Grafana's first-start password is still stored in ${env_file}"
            _dsh_fix "Run ./update.sh (Docker method) to remove it - Grafana keeps its own hashed copy"
            problems=$((problems + 1))
        else
            _dsh_ok "No Grafana password stored on disk (Grafana keeps a hashed copy in its database)"
        fi
        _dsh_check_mode_600 "${env_file}" "Grafana settings" || problems=$((problems + 1))
    fi

    # --- Shelly ---
    dir="$(ds_shelly_dir)"
    if [[ -f "${dir}/docker-compose.yml" ]]; then
        plain=$(grep -E '^[[:space:]]*SHELLY_HTTP_PASSWORD:' "${dir}/docker-compose.yml" 2>/dev/null | grep -vF '${SHELLY_HTTP_PASSWORD}' || true)
        if [[ -z "${plain}" ]] && ds_env_read "${dir}" "SHELLY_HTTP_PASSWORD" >/dev/null; then
            _dsh_ok "Shelly plug password is stored in ${dir}/.env"
            _dsh_check_mode_600 "${dir}/.env" "it holds the Shelly password" || problems=$((problems + 1))
        else
            _dsh_warn "Shelly plug password is not stored in ${dir}/.env"
            _dsh_fix "Run ./update.sh (Docker method) to move it there"
            problems=$((problems + 1))
        fi
    fi

    # --- internet-pi config.yml ---
    cfg="$(ds_internet_pi_config)"
    if [[ -f "${cfg}" ]]; then
        if [[ -f "${compose}" ]]; then
            if grep -qE '^[[:space:]]*pihole_enable:[[:space:]]*false' "${cfg}"; then
                _dsh_ok "internet-pi playbook will not overwrite the Pi-hole compose file"
            else
                _dsh_warn "internet-pi playbook would overwrite ~/pi-hole/docker-compose.yml on its next run"
                _dsh_fix "Run ./update.sh (Docker method) to set pihole_enable: false"
                problems=$((problems + 1))
            fi
            if grep -qE '^[[:space:]]*pihole_enable:[[:space:]]*false' "${cfg}" && ! grep -q "pihole-exporter:9617" "${cfg}"; then
                _dsh_warn "A playbook run would drop the Prometheus scrape job for Pi-hole metrics"
                _dsh_fix "Run ./update.sh (Docker method) to add it to prometheus_extra_scrape_configs"
                problems=$((problems + 1))
            fi
        fi
        plain=$(grep -E '^[[:space:]]*(pihole_password|shelly_plug_http_password|monitoring_grafana_admin_password):' "${cfg}" 2>/dev/null \
            | grep -vF -e '${PIHOLE_PASSWORD}' -e '${SHELLY_HTTP_PASSWORD}' || true)
        if [[ -z "${plain}" ]]; then
            _dsh_ok "internet-pi config.yml has no plain-text passwords"
        else
            _dsh_warn "internet-pi config.yml still contains a plain-text password"
            _dsh_fix "Run ./update.sh (Docker method) to remove it"
            problems=$((problems + 1))
        fi
        _dsh_check_mode_600 "${cfg}" "internet-pi settings" || problems=$((problems + 1))
    fi

    return "${problems}"
}
