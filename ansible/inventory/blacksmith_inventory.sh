#!/usr/bin/env bash
# ==============================================================================
# KVM-Blacksmith: Ansible Dynamic Inventory Script
# ==============================================================================
set -euo pipefail

# Resolve script directory and config path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLACKSMITH_ROOT="$(realpath "${SCRIPT_DIR}/../..")"
CONFIG_FILE="${CONFIG_FILE:-$BLACKSMITH_ROOT/config/anvils.yaml}"

# If yq is not installed, output error to stderr and exit
if ! command -v yq &>/dev/null; then
    echo "[ERROR] Required command 'yq' is missing. Please install it first." >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Fetch list of anvils
anvils=$(yq '.anvils | keys | .[]' "$CONFIG_FILE" 2>/dev/null || true)

print_list() {
    local first_host=true
    local first_var=true

    # Start the JSON object
    echo "{"
    echo '  "anvils": {'
    echo '    "hosts": ['

    # Print hosts list
    for anvil in $anvils; do
        if [ "$first_host" = true ]; then
            first_host=false
        else
            echo ","
        fi
        echo -n "      \"$anvil\""
    done
    echo ""
    echo '    ]'
    echo '  },'
    echo '  "_meta": {'
    echo '    "hostvars": {'

    # Print hostvars
    for anvil in $anvils; do
        if [ "$first_var" = true ]; then
            first_var=false
        else
            echo ","
        fi

        local host port user ssh_key
        host=$(yq ".anvils.${anvil}.host" "$CONFIG_FILE" 2>/dev/null)
        port=$(yq ".anvils.${anvil}.port" "$CONFIG_FILE" 2>/dev/null)
        user=$(yq ".anvils.${anvil}.user" "$CONFIG_FILE" 2>/dev/null)
        ssh_key=$(yq ".anvils.${anvil}.ssh_key" "$CONFIG_FILE" 2>/dev/null)

        [ "$host" = "null" ] && host=""
        [ "$port" = "null" ] && port=""
        [ "$user" = "null" ] && user=""
        [ "$ssh_key" = "null" ] && ssh_key=""

        [ -z "$port" ] && port=22
        [ -z "$user" ] && user="root"

        echo "      \"$anvil\": {"
        echo "        \"ansible_host\": \"$host\","
        echo "        \"ansible_port\": $port,"
        echo -n "        \"ansible_user\": \"$user\""
        if [ -n "$ssh_key" ]; then
            # Expand tilde if any
            local expanded_key="${ssh_key/#\~/$HOME}"
            echo ","
            echo -n "        \"ansible_ssh_private_key_file\": \"$expanded_key\""
        fi
        echo ""
        echo -n "      }"
    done
    echo ""
    echo '    }'
    echo '  }'
    echo '}'
}

# Parse command line arguments
case "${1:-}" in
    --list)
        print_list
        ;;
    --host)
        echo "{}"
        ;;
    *)
        echo "Usage: $0 --list | --host <hostname>" >&2
        exit 1
        ;;
esac
