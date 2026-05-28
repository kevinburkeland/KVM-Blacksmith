# ==============================================================================
# KVM-Blacksmith: provision Subcommand Logic
# ==============================================================================

cmd_provision() {
    if [ $# -eq 0 ]; then
        cmd_tui
        return
    fi

    # Default options matching KVM-Forge spec
    local distro="ubuntu"
    local version=""
    local profile="base"
    local cpus=4
    local memory=8192
    local disk_size=30
    local target_anvil=""
    local use_tui=0

    # Argument parsing loop
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tui)
                use_tui=1
                shift
                ;;
            -d|--distro)
                distro="$2"
                shift 2
                ;;
            -v|--version)
                version="$2"
                shift 2
                ;;
            -p|--profile)
                profile="$2"
                shift 2
                ;;
            -c|--cpus)
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "CPUs (-c) must be a positive integer."
                    exit 1
                fi
                cpus="$2"
                shift 2
                ;;
            -m|--memory)
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "Memory (-m) must be a positive integer."
                    exit 1
                fi
                memory="$2"
                shift 2
                ;;
            -s|--disk-size)
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "Disk size (-s) must be a positive integer."
                    exit 1
                fi
                disk_size="$2"
                shift 2
                ;;
            --anvil)
                target_anvil="$2"
                shift 2
                ;;
            *)
                log_err "Unknown provision parameter: $1"
                exit 1
                ;;
        esac
    done

    if [ $use_tui -eq 1 ]; then
        cmd_tui
        return
    fi

    validate_manifest

    local selected_anvil=""
    local host=""
    local port=""
    local user=""
    local key=""
    local key_arg=""

    if [ -n "$target_anvil" ]; then
        # Explicit target override
        selected_anvil="$target_anvil"
        host=$(get_anvil_field "$selected_anvil" "host")
        
        if [ -z "$host" ]; then
            log_err "Anvil host '$selected_anvil' not found in inventory manifest."
            exit 1
        fi

        port=$(get_anvil_field "$selected_anvil" "port")
        user=$(get_anvil_field "$selected_anvil" "user")
        key=$(get_anvil_field "$selected_anvil" "ssh_key")
        local max_ram=$(get_anvil_field "$selected_anvil" "max_ram_mb")
        local max_vcpus=$(get_anvil_field "$selected_anvil" "max_vcpus")

        [ -z "$port" ] && port=22
        [ -z "$user" ] && user="root"

        if [ -n "$key" ]; then
            local expanded_key
            expanded_key=$(expand_path "$key")
            if [ -f "$expanded_key" ]; then
                key_arg="-i $expanded_key"
            fi
        fi

        # Check hard limits defined in the manifest
        if [ -n "$max_ram" ] && [ "$max_ram" != "null" ] && [ "$memory" -gt "$max_ram" ]; then
            log_err "Capacity exceeded: Requested memory ($memory MB) exceeds maximum RAM limit ($max_ram MB) on Anvil $selected_anvil."
            exit 1
        fi
        if [ -n "$max_vcpus" ] && [ "$max_vcpus" != "null" ] && [ "$cpus" -gt "$max_vcpus" ]; then
            log_err "Capacity exceeded: Requested vCPUs ($cpus) exceeds maximum limit ($max_vcpus) on Anvil $selected_anvil."
            exit 1
        fi

        # Query host free RAM and verify libvirt connection via SSH
        set +e
        local free_out libvirt_ok
        free_out=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "free -m" 2>/dev/null)
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh uri" &>/dev/null
            libvirt_ok=$?
        else
            libvirt_ok=1
        fi
        set -e

        if [ $exit_code -ne 0 ] || [ -z "$free_out" ]; then
            log_err "Failed to query resources on target Anvil $selected_anvil."
            exit 1
        fi

        if [ $libvirt_ok -ne 0 ]; then
            log_err "Failed to connect to libvirt daemon on target Anvil $selected_anvil. Check permissions or group membership."
            exit 1
        fi

        local ram_free
        # Parse available/free columns
        local cols
        cols=$(echo "$free_out" | grep -E '^Mem:' | awk '{print NF}' || echo "0")
        if [ "$cols" -ge 7 ]; then
            ram_free=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $7}' || echo "0")
        else
            ram_free=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $4}' || echo "0")
        fi

        if [ "$memory" -gt "$ram_free" ]; then
            log_err "Capacity exceeded: Target Anvil $selected_anvil has insufficient free memory ($ram_free MB available, requested: $memory MB)."
            exit 1
        fi
    else
        # Capacity Scheduler: Query all active Anvils to find the best candidate
        local anvils
        anvils=$(get_anvils)
        local best_anvil=""
        local best_free_ram=0
        local best_active_vm_count=999999

        for anvil in $anvils; do
            local h p u k max_r max_vc
            h=$(get_anvil_field "$anvil" "host")
            p=$(get_anvil_field "$anvil" "port")
            u=$(get_anvil_field "$anvil" "user")
            k=$(get_anvil_field "$anvil" "ssh_key")
            max_r=$(get_anvil_field "$anvil" "max_ram_mb")
            max_vc=$(get_anvil_field "$anvil" "max_vcpus")

            [ -z "$p" ] && p=22
            [ -z "$u" ] && u="root"

            local k_arg=""
            if [ -n "$k" ]; then
                local exp_k
                exp_k=$(expand_path "$k")
                if [ -f "$exp_k" ]; then
                    k_arg="-i $exp_k"
                fi
            fi

            # Manifest limit checks
            if [ -n "$max_r" ] && [ "$max_r" != "null" ] && [ "$memory" -gt "$max_r" ]; then
                continue
            fi
            if [ -n "$max_vc" ] && [ "$max_vc" != "null" ] && [ "$cpus" -gt "$max_vc" ]; then
                continue
            fi

            # Check reachability, free memory, and libvirt connection
            set +e
            local f_out libvirt_ok
            f_out=$(ssh $SSH_OPTS $k_arg -p "$p" "$u@$h" "free -m" 2>/dev/null)
            local rc=$?
            if [ $rc -eq 0 ]; then
                ssh $SSH_OPTS $k_arg -p "$p" "$u@$h" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh uri" &>/dev/null
                libvirt_ok=$?
            else
                libvirt_ok=1
            fi
            set -e

            if [ $rc -ne 0 ] || [ -z "$f_out" ] || [ $libvirt_ok -ne 0 ]; then
                continue
            fi

            local r_free
            local columns
            columns=$(echo "$f_out" | grep -E '^Mem:' | awk '{print NF}' || echo "0")
            if [ "$columns" -ge 7 ]; then
                r_free=$(echo "$f_out" | grep -E '^Mem:' | awk '{print $7}' || echo "0")
            else
                r_free=$(echo "$f_out" | grep -E '^Mem:' | awk '{print $4}' || echo "0")
            fi

            # Ensure host has enough free RAM
            if [ "$r_free" -lt "$memory" ]; then
                continue
            fi

            # Determine suitability: Choose highest free RAM
            if [ "$r_free" -gt "$best_free_ram" ]; then
                best_anvil="$anvil"
                best_free_ram="$r_free"
                # Query VM count to cache for potential ties
                set +e
                local vm_count
                vm_count=$(ssh $SSH_OPTS $k_arg -p "$p" "$u@$h" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh list --all --name 2>/dev/null | grep -c . || echo 0" 2>/dev/null)
                best_active_vm_count=${vm_count:-0}
                set -e
            elif [ "$r_free" -eq "$best_free_ram" ]; then
                # Tie-breaking logic: least active/total VMs
                set +e
                local vm_count
                vm_count=$(ssh $SSH_OPTS $k_arg -p "$p" "$u@$h" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh list --all --name 2>/dev/null | grep -c . || echo 0" 2>/dev/null)
                local current_vm_count=${vm_count:-0}
                set -e

                if [ "$current_vm_count" -lt "$best_active_vm_count" ]; then
                    best_anvil="$anvil"
                    best_active_vm_count="$current_vm_count"
                fi
            fi
        done

        if [ -z "$best_anvil" ]; then
            log_err "Capacity exceeded: No available Anvil host has sufficient resources (requested: $memory MB RAM, $cpus vCPUs)."
            exit 1
        fi

        selected_anvil="$best_anvil"
        host=$(get_anvil_field "$selected_anvil" "host")
        port=$(get_anvil_field "$selected_anvil" "port")
        user=$(get_anvil_field "$selected_anvil" "user")
        key=$(get_anvil_field "$selected_anvil" "ssh_key")

        [ -z "$port" ] && port=22
        [ -z "$user" ] && user="root"

        if [ -n "$key" ]; then
            local expanded_key
            expanded_key=$(expand_path "$key")
            if [ -f "$expanded_key" ]; then
                key_arg="-i $expanded_key"
            fi
        fi
    fi

    # Remote Dispatcher
    local temp_log
    temp_log=$(mktemp)
    trap '[[ -n "${temp_log:-}" ]] && rm -f "$temp_log"' EXIT

    # Dynamically resolve remote CLI path
    local remote_cli_path
    remote_cli_path=$(resolve_remote_cli_path "$host" "$port" "$user" "$key_arg")

    # Construct the remote CLI call
    local remote_cmd="$remote_cli_path -d \"$distro\" -p \"$profile\" -c \"$cpus\" -m \"$memory\" -s \"$disk_size\""
    if [ -n "$version" ]; then
        remote_cmd="$remote_cmd -v \"$version\""
    fi

    echo -e "\n\033[1;32m┌────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;32m│              SCHEDULING CLUSTER PROVISION              │\033[0m"
    echo -e "\033[1;32m├────────────────────────────────────────────────────────┤\033[0m"
    log_info "Scheduled Anvil Node: \033[1;36m$selected_anvil\033[0m ($host)"
    log_info "Transmitting orchestration parameters to remote compute host..."
    echo -e "\033[1;32m└────────────────────────────────────────────────────────┘\033[0m\n"

    # Execute SSH command, stream output to stdout and log file
    set +e
    ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_cmd" 2>&1 | tee "$temp_log"
    local ssh_rc=${PIPESTATUS[0]}
    set -e

    if [ $ssh_rc -ne 0 ]; then
        log_err "Remote orchestration failed on host $selected_anvil (exit code $ssh_rc)."
        exit $ssh_rc
    fi

    # Parse and intercept provisioning parameters from log file
    local vm_name vm_ip vm_user
    vm_name=$(grep -i -E "The VM is named|Name:" "$temp_log" | tail -n1 | sed -E 's/.*(The VM is named|Name:)[[:space:]]*//I' | tr -d '\r' || true)
    vm_ip=$(grep -i -E "The IP is|IP Address:|IP:" "$temp_log" | tail -n1 | sed -E 's/.*(The IP is|IP Address:|IP:)[[:space:]]*//I' | tr -d '\r' || true)
    vm_user=$(grep -i -E "Default User:|User:" "$temp_log" | tail -n1 | sed -E 's/.*(Default User:|User:)[[:space:]]*//I' | tr -d '\r' || true)

    # If details were not formatted with labels, fallback to standard KVM-Forge output tail positions
    if [ -z "$vm_name" ] || [ -z "$vm_ip" ] || [ -z "$vm_user" ]; then
        # Try fetching from the trailing lines
        local total_lines
        total_lines=$(wc -l < "$temp_log")
        if [ "$total_lines" -ge 3 ]; then
            local tail_lines
            tail_lines=$(tail -n 10 "$temp_log")
            # If the output format is:
            # [INFO] The VM is named <name>
            # [INFO] The IP is <ip>
            # [INFO] The Default User is <user>
            # We can parse them cleanly:
            vm_name=$(echo "$tail_lines" | grep -E "The VM is named" | awk '{print $NF}' | tr -d '\r' || true)
            vm_ip=$(echo "$tail_lines" | grep -E "The IP is" | awk '{print $NF}' | tr -d '\r' || true)
            vm_user=$(echo "$tail_lines" | grep -E "Default User" | awk '{print $NF}' | tr -d '\r' || true)
        fi
    fi

    echo -e "\n\033[1;32m┌────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;32m│            PROVISIONING COMPLETE (CLUSTER STATE)       │\033[0m"
    echo -e "\033[1;32m├────────────────────────────────────────────────────────┤\033[0m"
    echo -e "  Host Anvil:   \033[1;36m$selected_anvil\033[0m ($host)"
    echo -e "  VM Name:      \033[1;33m${vm_name:-N/A}\033[0m"
    echo -e "  IP Address:   \033[1;32m${vm_ip:-N/A}\033[0m"
    echo -e "  Default User: \033[1;35m${vm_user:-N/A}\033[0m"
    echo -e "\033[1;32m└────────────────────────────────────────────────────────┘\033[0m\n"
}
