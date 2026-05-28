# ==============================================================================
# KVM-Blacksmith: tui Subcommand Logic
# ==============================================================================

cmd_tui() {
    check_gum
    validate_manifest

    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_err "No Anvils defined in inventory manifest."
        exit 1
    fi

    # Step 1: Query all active Anvils to build selection options with capacity indicators
    log_info "Probing cluster hypervisors for capacity details..."
    
    local choices=()
    
    # We run probes wrapped in a gum spin for premium UX
    local probe_tmp
    probe_tmp=$(mktemp)
    trap 'rm -f "$probe_tmp"' EXIT

    gum spin --spinner dot --title "Analyzing cluster capacity..." -- bash -c '
        anvils="'"$anvils"'"
        for anvil in $anvils; do
            host=$(yq ".anvils.${anvil}.host" "'"$CONFIG_FILE"'")
            port=$(yq ".anvils.${anvil}.port" "'"$CONFIG_FILE"'")
            user=$(yq ".anvils.${anvil}.user" "'"$CONFIG_FILE"'")
            key=$(yq ".anvils.${anvil}.ssh_key" "'"$CONFIG_FILE"'")
            max_ram=$(yq ".anvils.${anvil}.max_ram_mb" "'"$CONFIG_FILE"'")
            
            [ "$port" = "null" ] || [ -z "$port" ] && port=22
            [ "$user" = "null" ] || [ -z "$user" ] && user="root"

            key_arg=""
            if [ -n "$key" ] && [ "$key" != "null" ]; then
                # expand tilde
                expanded_key="${key/#\~/$HOME}"
                if [ -f "$expanded_key" ]; then
                    key_arg="-i $expanded_key"
                fi
            fi

            # Check reachability
            ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=accept-new $key_arg -p "$port" "$user@$host" "echo OK" &>/dev/null
            if [ $? -eq 0 ]; then
                # Query free RAM
                free_out=$(ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=accept-new $key_arg -p "$port" "$user@$host" "free -m" 2>/dev/null)
                cols=$(echo "$free_out" | grep -E "^Mem:" | awk "{print NF}" || echo "0")
                if [ "$cols" -ge 7 ]; then
                    r_free=$(echo "$free_out" | grep -E "^Mem:" | awk "{print \$7}" || echo "0")
                else
                    r_free=$(echo "$free_out" | grep -E "^Mem:" | awk "{print \$4}" || echo "0")
                fi
                echo "$anvil|$host|ONLINE|$r_free|$max_ram" >> "'"$probe_tmp"'"
            else
                echo "$anvil|$host|OFFLINE|0|0" >> "'"$probe_tmp"'"
            fi
        done
    '

    # Auto option
    choices+=("Auto (Capacity Scheduler)")
    
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        local a h status rf maxr
        a=$(echo "$line" | cut -d'|' -f1)
        h=$(echo "$line" | cut -d'|' -f2)
        status=$(echo "$line" | cut -d'|' -f3)
        rf=$(echo "$line" | cut -d'|' -f4)
        maxr=$(echo "$line" | cut -d'|' -f5)

        if [ "$status" = "ONLINE" ]; then
            choices+=("$a ($h - $rf MB free / $maxr MB max)")
        else
            choices+=("$a ($h - OFFLINE)")
        fi
    done < "$probe_tmp"

    local selected_choice
    selected_choice=$(printf "%s\n" "${choices[@]}" | gum choose --header "Choose a target Anvil Node:")
    
    if [ -z "$selected_choice" ]; then
        log_info "Operation cancelled by user."
        exit 0
    fi

    local selected_anvil=""
    if [[ "$selected_choice" == "Auto"* ]]; then
        selected_anvil="AUTO"
    else
        selected_anvil=$(echo "$selected_choice" | awk '{print $1}')
    fi

    # Determine which anvil to pull the manifest from
    local manifest_anvil=""
    if [ "$selected_anvil" = "AUTO" ]; then
        # Find first online anvil in probe results
        manifest_anvil=$(grep "|ONLINE|" "$probe_tmp" | head -n1 | cut -d'|' -f1 || echo "")
        if [ -z "$manifest_anvil" ]; then
            log_err "No ONLINE Anvils found in the cluster to fetch profile definitions."
            exit 1
        fi
    else
        # Verify selected anvil is online
        if ! grep -q "^$selected_anvil|.*|ONLINE|" "$probe_tmp"; then
            log_err "Selected Anvil '$selected_anvil' is OFFLINE. Cannot provision."
            exit 1
        fi
        manifest_anvil="$selected_anvil"
    fi

    # Fetch manifest from the manifest_anvil dynamically
    local m_host m_port m_user m_key m_key_arg
    m_host=$(get_anvil_field "$manifest_anvil" "host")
    m_port=$(get_anvil_field "$manifest_anvil" "port")
    m_user=$(get_anvil_field "$manifest_anvil" "user")
    m_key=$(get_anvil_field "$manifest_anvil" "ssh_key")
    [ -z "$m_port" ] && m_port=22
    [ -z "$m_user" ] && m_user="root"
    m_key_arg=""
    if [ -n "$m_key" ] && [ "$m_key" != "null" ]; then
        local exp_k
        exp_k=$(expand_path "$m_key")
        [ -f "$exp_k" ] && m_key_arg="-i $exp_k"
    fi

    local local_manifest
    local_manifest=$(mktemp)
    trap 'rm -f "$local_manifest"' EXIT

    log_info "Retrieving distro manifest from $manifest_anvil..."
    if ! fetch_remote_manifest "$m_host" "$m_port" "$m_user" "$m_key_arg" "$local_manifest"; then
        log_err "Failed to fetch OS profile definitions from Anvil $manifest_anvil."
        exit 1
    fi

    # Step 2: OS Distro Selector
    local distros=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && distros+=("$line")
    done < <(yq '.distros | keys | .[]' "$local_manifest" 2>/dev/null)

    local selected_distro
    selected_distro=$(printf "%s\n" "${distros[@]}" | gum choose --header "Select Operating System Distro:")
    [ -z "$selected_distro" ] && { log_info "Operation cancelled."; exit 0; }

    # Step 3: Version Selector
    local default_version
    default_version=$(yq ".distros.${selected_distro}.default_version" "$local_manifest" 2>/dev/null)
    
    local versions=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && versions+=("$line")
    done < <(yq ".distros.${selected_distro}.supported_versions | .[]" "$local_manifest" 2>/dev/null)

    local selected_version
    selected_version=$(printf "%s\n" "${versions[@]}" | gum choose --header "Select Distro Version (Default: $default_version):")
    [ -z "$selected_version" ] && { log_info "Operation cancelled."; exit 0; }

    # Step 4: Profile Selector
    local profiles=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && profiles+=("$line")
    done < <(yq ".distros.${selected_distro}.profiles | .[]" "$local_manifest" 2>/dev/null)

    local selected_profile
    selected_profile=$(printf "%s\n" "${profiles[@]}" | gum choose --header "Select Hardware/Provisioning Profile:")
    [ -z "$selected_profile" ] && { log_info "Operation cancelled."; exit 0; }

    # Step 5: Hardware Allocations (vCPUs, RAM, Disk Size) via gum input
    local cpus
    cpus=$(gum input --placeholder "Number of vCPUs (e.g. 4)" --value "4" --header "Allocated vCPUs:")
    [ -z "$cpus" ] && { log_info "Operation cancelled."; exit 0; }
    if ! [[ "$cpus" =~ ^[1-9][0-9]*$ ]]; then
        log_err "vCPUs must be a positive integer."
        exit 1
    fi

    local memory
    memory=$(gum input --placeholder "Memory size in MB (e.g. 8192)" --value "8192" --header "Allocated Memory (MB):")
    [ -z "$memory" ] && { log_info "Operation cancelled."; exit 0; }
    if ! [[ "$memory" =~ ^[1-9][0-9]*$ ]]; then
        log_err "Memory must be a positive integer."
        exit 1
    fi

    local disk_size
    disk_size=$(gum input --placeholder "Disk volume size in GB (e.g. 30)" --value "30" --header "Allocated Disk Size (GB):")
    [ -z "$disk_size" ] && { log_info "Operation cancelled."; exit 0; }
    if ! [[ "$disk_size" =~ ^[1-9][0-9]*$ ]]; then
        log_err "Disk size must be a positive integer."
        exit 1
    fi

    # Step 6: Confirmation Screen
    echo -e "\n\033[1;36m┌────────────────────────────────────────────────────────┐\033[0m"
    echo -e "│            PROVISIONING SPECIFICATION SUMMARY          │"
    echo -e "├────────────────────────────────────────────────────────┤"
    echo -e "  Anvil Target: \033[1;33m$selected_anvil\033[0m"
    echo -e "  OS Distro:    \033[1;32m$selected_distro\033[0m"
    echo -e "  Version:      \033[1;32m$selected_version\033[0m"
    echo -e "  Profile:      \033[1;35m$selected_profile\033[0m"
    echo -e "  vCPUs:        \033[1;36m$cpus\033[0m"
    echo -e "  Memory:       \033[1;36m$memory MB\033[0m"
    echo -e "  Disk Size:    \033[1;36m$disk_size GB\033[0m"
    echo -e "\033[1;36m└────────────────────────────────────────────────────────┘\033[0m\n"

    gum confirm "🚀 Proceed with cluster virtual machine deployment?"
    if [ $? -eq 0 ]; then
        # Invoke standard provision command
        local prov_args=(-d "$selected_distro" -v "$selected_version" -p "$selected_profile" -c "$cpus" -m "$memory" -s "$disk_size")
        if [ "$selected_anvil" != "AUTO" ]; then
            prov_args+=(--anvil "$selected_anvil")
        fi
        cmd_provision "${prov_args[@]}"
    else
        log_info "Deployment cancelled."
    fi
}
