#!/usr/bin/env bash
# ============================================================
# bitbucket_extract.sh
#
# PURPOSE:
#   For every project mnemonic and its services defined in the
#   config file, this script fetches:
#     1. baseImage     — from  Platformfile
#     2. micronVersion — from  gradle.properties
#   It then writes the results to a CSV file.
#
# USAGE:
#   ./bitbucket_extract.sh [-c config_file] [-o output_csv]
#
# OPTIONS:
#   -c <file>   Path to config file (default: ./bitbucket.conf)
#   -o <file>   Override CSV output path from config
#   -h          Show this help
#
# DEPENDENCIES:
#   curl, jq   (install via: sudo apt install curl jq)
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────────
# Default values (can be overridden by flags)
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/bitbucket.conf"
OVERRIDE_CSV=""

# ──────────────────────────────────────────────
# Coloured output helpers
# ──────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m';    NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
while getopts ":c:o:h" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG" ;;
        o) OVERRIDE_CSV="$OPTARG" ;;
        h)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        :) die "Option -$OPTARG requires an argument." ;;
       \?) die "Unknown option: -$OPTARG" ;;
    esac
done

# ──────────────────────────────────────────────
# Load and validate configuration
# ──────────────────────────────────────────────
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    [[ -n "${BB_USERNAME:-}" ]] || die "BB_USERNAME is not set in $CONFIG_FILE"
    [[ -n "${BB_TOKEN:-}"    ]] || die "BB_TOKEN is not set in $CONFIG_FILE"
    [[ -n "${BB_URL:-}"      ]] || die "BB_URL is not set in $CONFIG_FILE"
    [[ -n "${BB_MNEMONICS:-}" ]] || die "BB_MNEMONICS is not set in $CONFIG_FILE"

    # CLI -o flag overrides the config value
    [[ -n "$OVERRIDE_CSV" ]] && BB_CSV_OUTPUT="$OVERRIDE_CSV"
    BB_CSV_OUTPUT="${BB_CSV_OUTPUT:-./service_versions.csv}"

    BB_API_BASE="${BB_URL}${BB_API_PATH:-/rest/api/latest}"
    BB_TIMEOUT="${BB_TIMEOUT:-15}"
}

# ──────────────────────────────────────────────
# Generic file fetcher via Bitbucket browse API
#
# The Bitbucket browse endpoint returns JSON like:
# { "lines": [ {"text": "line content"}, ... ] }
# We use jq to extract all lines and join them.
#
# Usage: fetch_file_content <project> <repo> <filepath>
# Returns: raw text content of the file, or empty string on failure
# ──────────────────────────────────────────────
fetch_file_content() {
    local project="$1"
    local repo="$2"
    local filepath="$3"

    local url="${BB_API_BASE}/projects/${project}/repos/${repo}/browse/${filepath}"

    local response
    response=$(
        curl --silent \
             --max-time "${BB_TIMEOUT}" \
             --header "Authorization: Bearer ${BB_TOKEN}" \
             --header "Accept: application/json" \
             "${url}" 2>/dev/null
    ) || { warn "    curl failed for: ${url}"; echo ""; return; }

    # Check for Bitbucket error response (e.g. 404 not found)
    local has_errors
    has_errors=$(echo "$response" | jq 'has("errors")' 2>/dev/null || echo "true")
    if [[ "$has_errors" == "true" ]]; then
        warn "    File not found or access denied: ${filepath}"
        echo ""
        return
    fi

    # Extract text from each line object and join with newlines
    echo "$response" | jq -r '.lines[].text' 2>/dev/null || echo ""
}

# ──────────────────────────────────────────────
# Parse baseImage from Platformfile
#
# Expects a line like:  baseImage=amazoncorretto:17
# or Docker-style:      FROM amazoncorretto:17 AS base
# ──────────────────────────────────────────────
parse_base_image() {
    local file_content="$1"

    local value=""

    # Try key=value format first (e.g. baseImage=amazoncorretto:17)
    value=$(echo "$file_content" \
        | grep -i '^baseImage\s*=' \
        | head -1 \
        | sed 's/^[^=]*=\s*//' \
        | tr -d '[:space:]')

    # Fallback: Docker FROM line (e.g. FROM amazoncorretto:17)
    if [[ -z "$value" ]]; then
        value=$(echo "$file_content" \
            | grep -i '^FROM ' \
            | head -1 \
            | awk '{print $2}')
    fi

    echo "${value:-NOT_FOUND}"
}

# ──────────────────────────────────────────────
# Parse micronVersion from gradle.properties
#
# Expects a line like:  micronVersion=4.2.3
# ──────────────────────────────────────────────
parse_micron_version() {
    local file_content="$1"

    local value
    value=$(echo "$file_content" \
        | grep -i '^micronVersion\s*=' \
        | head -1 \
        | sed 's/^[^=]*=\s*//' \
        | tr -d '[:space:]')

    echo "${value:-NOT_FOUND}"
}

# ──────────────────────────────────────────────
# Write CSV header
# ──────────────────────────────────────────────
init_csv() {
    local csv_file="$1"
    local dir
    dir="$(dirname "$csv_file")"
    [[ -d "$dir" ]] || mkdir -p "$dir"

    echo "mnemonic,service_name,base_image,micron_version" > "$csv_file"
    success "CSV initialised: ${csv_file}"
}

# ──────────────────────────────────────────────
# Append one row to the CSV
# ──────────────────────────────────────────────
append_csv_row() {
    local csv_file="$1"
    local mnemonic="$2"
    local service="$3"
    local base_image="$4"
    local micron_version="$5"

    printf '%s,%s,%s,%s\n' \
        "$mnemonic" "$service" "$base_image" "$micron_version" \
        >> "$csv_file"
}

# ──────────────────────────────────────────────
# Process a single service
# ──────────────────────────────────────────────
process_service() {
    local mnemonic="$1"
    local service="$2"
    local csv_file="$3"

    info "  Service: ${BOLD}${service}${NC}"

    # ---- Fetch Platformfile ----
    local platform_content
    platform_content=$(fetch_file_content "$mnemonic" "$service" "Platformfile")

    local base_image
    base_image=$(parse_base_image "$platform_content")
    info "    baseImage     → ${base_image}"

    # ---- Fetch gradle.properties ----
    local gradle_content
    gradle_content=$(fetch_file_content "$mnemonic" "$service" "gradle.properties")

    local micron_version
    micron_version=$(parse_micron_version "$gradle_content")
    info "    micronVersion → ${micron_version}"

    # ---- Write to CSV ----
    append_csv_row "$csv_file" "$mnemonic" "$service" "$base_image" "$micron_version"
    success "    Written to CSV ✓"
}

# ──────────────────────────────────────────────
# Main entry point
# ──────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Bitbucket Service Version Extractor${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    load_config

    echo ""
    info "API Base  : ${BB_API_BASE}"
    info "Mnemonics : ${BB_MNEMONICS}"
    info "Output CSV: ${BB_CSV_OUTPUT}"
    echo ""

    # Initialise a fresh CSV (overwrites previous run)
    init_csv "$BB_CSV_OUTPUT"
    echo ""

    # Iterate over each mnemonic (project)
    for mnemonic in $BB_MNEMONICS; do

        # Look up the services variable for this mnemonic, e.g. BB_SERVICES_ded
        local services_var="BB_SERVICES_${mnemonic}"
        local services="${!services_var:-}"

        if [[ -z "$services" ]]; then
            warn "No services defined for mnemonic '${mnemonic}' (${services_var} not set). Skipping."
            continue
        fi

        echo -e "${BOLD}Project mnemonic: ${mnemonic}${NC}"

        for service in $services; do
            process_service "$mnemonic" "$service" "$BB_CSV_OUTPUT"
        done

        echo ""
    done

    echo -e "${GREEN}${BOLD}Done.${NC} Results saved to: ${BOLD}${BB_CSV_OUTPUT}${NC}"
    echo ""
}

main "$@"
