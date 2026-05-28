# ==============================================================================
# KVM-Blacksmith: Inventory and Manifest Parsing Helpers
# ==============================================================================

# Fetch and validate manifest from a target anvil
fetch_remote_manifest() {
    local host="$1"
    local port="$2"
    local user="$3"
    local key_arg="$4"
    local out_file="$5"

    local remote_cmd
    remote_cmd='
        if command -v kvm-forge-cli &>/dev/null; then
            realpath "$(dirname "$(command -v kvm-forge-cli)")/../config/manifest.yaml" 2>/dev/null
        elif [ -f ~/KVM-Forge/config/manifest.yaml ]; then
            realpath ~/KVM-Forge/config/manifest.yaml 2>/dev/null
        elif [ -f ~/Documents/git/KVM-Forge/config/manifest.yaml ]; then
            realpath ~/Documents/git/KVM-Forge/config/manifest.yaml 2>/dev/null
        elif [ -f /opt/KVM-Forge/config/manifest.yaml ]; then
            realpath /opt/KVM-Forge/config/manifest.yaml 2>/dev/null
        else
            echo ""
        fi
    '

    local remote_path
    remote_path=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_cmd" 2>/dev/null | tr -d '\r\n')
    
    if [ -z "$remote_path" ]; then
        log_err "Could not locate KVM-Forge manifest file on remote host $host."
        log_err "Looked in PATH for 'kvm-forge-cli', and in standard fallback directories: ~/KVM-Forge, ~/Documents/git/KVM-Forge, /opt/KVM-Forge."
        return 1
    fi

    local cat_err
    cat_err=$(mktemp)

    ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; cat '$remote_path'" > "$out_file" 2> "$cat_err"
    local rc=$?

    if [ $rc -ne 0 ] || [ ! -s "$out_file" ]; then
        log_err "Failed to read remote manifest file at '$remote_path' on $host."
        if [ -s "$cat_err" ]; then
            log_err "Details: $(cat "$cat_err")"
        fi
        rm -f "$cat_err"
        return 1
    fi
    rm -f "$cat_err"

    # Validate fetched YAML using yq locally
    local yq_err
    set +e
    yq_err=$(yq eval '.' "$out_file" 2>&1 >/dev/null)
    local yq_rc=$?
    set -e
    if [ $yq_rc -ne 0 ]; then
        log_err "Fetched manifest file from $host is malformed or invalid YAML at '$remote_path'."
        if [ -n "$yq_err" ]; then
            log_err "Parser Error:\n$yq_err"
        fi
        return 1
    fi

    return 0
}

# Resolves the absolute path to the kvm-forge-cli on the target host
resolve_remote_cli_path() {
    local host="$1"
    local port="$2"
    local user="$3"
    local key_arg="$4"

    local remote_cmd
    remote_cmd='
        if command -v kvm-forge-cli &>/dev/null; then
            realpath "$(command -v kvm-forge-cli)" 2>/dev/null
        elif [ -f ~/KVM-Forge/bin/kvm-forge-cli ]; then
            realpath ~/KVM-Forge/bin/kvm-forge-cli 2>/dev/null
        elif [ -f ~/Documents/git/KVM-Forge/bin/kvm-forge-cli ]; then
            realpath ~/Documents/git/KVM-Forge/bin/kvm-forge-cli 2>/dev/null
        elif [ -f /opt/KVM-Forge/bin/kvm-forge-cli ]; then
            realpath /opt/KVM-Forge/bin/kvm-forge-cli 2>/dev/null
        else
            echo "kvm-forge-cli"
        fi
    '

    local res
    res=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_cmd" 2>/dev/null | tr -d '\r\n')
    if [ -z "$res" ]; then
        echo "kvm-forge-cli"
    else
        echo "$res"
    fi
}

# Validate inventory configuration file
validate_manifest() {
    check_yq
    if [ ! -f "$CONFIG_FILE" ]; then
        log_err "Manifest file not found at: $CONFIG_FILE"
        exit 1
    fi
    set +e
    local yq_err
    yq_err=$(yq eval '.' "$CONFIG_FILE" 2>&1 >/dev/null)
    local yq_status=$?
    set -e
    if [ $yq_status -ne 0 ]; then
        log_err "Manifest file is malformed or invalid YAML: $CONFIG_FILE"
        if [ -n "$yq_err" ]; then
            log_err "Parser Error:\n$yq_err"
        fi
        exit 1
    fi
}

# Get a field value for a specific anvil from the YAML manifest
get_anvil_field() {
    local anvil="$1"
    local field="$2"
    local val
    val=$(yq ".anvils.${anvil}.${field}" "$CONFIG_FILE" 2>/dev/null || echo "null")
    if [ "$val" = "null" ]; then
        echo ""
    else
        echo "$val"
    fi
}

# Get a list of all anvils defined in the manifest
get_anvils() {
    yq '.anvils | keys | .[]' "$CONFIG_FILE" 2>/dev/null || true
}
