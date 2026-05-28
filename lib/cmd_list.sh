# ==============================================================================
# KVM-Blacksmith: list / vms Subcommand Logic
# ==============================================================================

cmd_list() {
    validate_manifest
    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_warn "No Anvils defined in inventory manifest."
        exit 0
    fi

    # Render Header
    echo -e "\n\033[1;35m┌────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m│                                 GUEST VIRTUAL MACHINES                                 │\033[0m"
    echo -e "\033[1;35m├──────────┬──────────────────────┬──────────────────────┬─────────┬─────────────────────┤\033[0m"
    echo -e "\033[1;35m│ Anvil    │ VM Name              │ State                │ vCPUs   │ IP Address          │\033[0m"
    echo -e "\033[1;35m├──────────┼──────────────────────┼──────────────────────┼─────────┼─────────────────────┤\033[0m"

    local vm_found=0

    for anvil in $anvils; do
        local host port user key
        host=$(get_anvil_field "$anvil" "host")
        port=$(get_anvil_field "$anvil" "port")
        user=$(get_anvil_field "$anvil" "user")
        key=$(get_anvil_field "$anvil" "ssh_key")

        [ -z "$port" ] && port=22
        [ -z "$user" ] && user="root"

        local key_arg=""
        if [ -n "$key" ]; then
            local expanded_key
            expanded_key=$(expand_path "$key")
            if [ -f "$expanded_key" ]; then
                key_arg="-i $expanded_key"
            fi
        fi

        # Verify reachability first
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "echo OK" &>/dev/null
        local reachable=$?
        set -e

        if [ $reachable -ne 0 ]; then
            log_warn "Anvil host $anvil ($host) is OFFLINE or unreachable. Skipping VM list query."
            continue
        fi

        # Remote query packaged in a single SSH connection for maximum performance
        local remote_script
        remote_script='
        export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"
        export LIBVIRT_DEFAULT_URI="qemu:///system"
        if ! virsh uri &>/dev/null; then
            echo "ERROR: Failed to connect to libvirt daemon. Check permissions or group membership." >&2
            exit 1
        fi
        get_vm_ip() {
            local vm="$1"
            local ip=""
            # Try 1: lease lookup
            ip=$(virsh domifaddr "$vm" --source lease 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk "{print \$4}" | cut -d/ -f1 | head -n1 || echo "")
            # Try 2: ARP lookup (essential for bridged physical interfaces)
            if [ -z "$ip" ]; then
                ip=$(virsh domifaddr "$vm" --source arp 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk "{print \$4}" | cut -d/ -f1 | head -n1 || echo "")
            fi
            # Try 3: Guest Agent lookup (if qemu-guest-agent is running)
            if [ -z "$ip" ]; then
                ip=$(virsh domifaddr "$vm" --source agent 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk "{print \$4}" | cut -d/ -f1 | head -n1 || echo "")
            fi
            # Try 4: generic lookup
            if [ -z "$ip" ]; then
                ip=$(virsh domifaddr "$vm" 2>/dev/null | grep ipv4 | grep -v "127.0.0.1" | awk "{print \$4}" | cut -d/ -f1 | head -n1 || echo "")
            fi
            echo "${ip:-"-"}"
        }
        for vm in $(virsh list --all --name 2>/dev/null); do
            [ -z "$vm" ] && continue
            state=$(virsh domstate "$vm" 2>/dev/null || echo "unknown")
            vcpus=$(virsh dominfo "$vm" 2>/dev/null | grep -E "^CPU\(s\):" | awk "{print \$2}" || echo "N/A")
            ip=$(get_vm_ip "$vm")
            echo "$vm|$state|$vcpus|$ip"
        done
        '

        local vm_outputs
        local ssh_err
        ssh_err=$(mktemp)
        set +e
        vm_outputs=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_script" 2>"$ssh_err")
        local rc=$?
        set -e

        if [ $rc -ne 0 ]; then
            log_warn "Failed to query virtual machines on Anvil $anvil ($host)."
            if [ -s "$ssh_err" ]; then
                log_warn "Details: $(cat "$ssh_err" | tr -d '\r\n')"
            fi
        fi
        rm -f "$ssh_err"

        if [ -n "$vm_outputs" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                # Parse VM properties
                local name state vcpus ip
                name=$(echo "$line" | cut -d'|' -f1)
                state=$(echo "$line" | cut -d'|' -f2)
                vcpus=$(echo "$line" | cut -d'|' -f3)
                ip=$(echo "$line" | cut -d'|' -f4)

                vm_found=$((vm_found + 1))

                # Colorize state column
                local state_color="\033[0m"
                if [ "$state" = "running" ]; then
                    state_color="\033[1;32m" # Green
                elif [ "$state" = "shut off" ]; then
                    state_color="\033[1;31m" # Red
                fi

                # Format outputs for tabular layout with truncation safety
                local anvil_display="$anvil"
                [ ${#anvil} -gt 8 ] && anvil_display="${anvil:0:5}..."
                local name_display="$name"
                [ ${#name} -gt 20 ] && name_display="${name:0:17}..."
                local ip_display="$ip"
                [ ${#ip} -gt 19 ] && ip_display="${ip:0:16}..."

                printf "\033[1;35m│\033[0m %-8s \033[1;35m│\033[0m %-20s \033[1;35m│\033[0m %b%-20s\033[0m \033[1;35m│\033[0m %-7s \033[1;35m│\033[0m %-19s \033[1;35m│\033[0m\n" \
                    "$anvil_display" "$name_display" "$state_color" "$state" "$vcpus" "$ip_display"
            done <<< "$vm_outputs"
        fi
    done

    if [ "$vm_found" -eq 0 ]; then
        echo -e "\033[1;35m│\033[0m \033[1;30m%-84s\033[0m \033[1;35m│\033[0m" "No virtual machines found running across cluster."
    fi

    echo -e "\033[1;35m└────────────────────────────────────────────────────────────────────────────────────────┘\033[0m\n"
}
