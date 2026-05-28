# ==============================================================================
# KVM-Blacksmith: status Subcommand Logic
# ==============================================================================

cmd_status() {
    validate_manifest
    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_warn "No Anvils defined in inventory manifest ($CONFIG_FILE)."
        exit 0
    fi

    # Render Header
    echo -e "\n\033[1;36m┌────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;36m│                                  ANVIL CLUSTER STATUS                                  │\033[0m"
    echo -e "\033[1;36m├──────────┬─────────┬──────────────────────────┬─────────────────┬──────────┬───────────┤\033[0m"
    echo -e "\033[1;36m│ Anvil    │ Status  │ IP/Host                  │ RAM (Free/Max)  │ CPU Load │ Libvirt   │\033[0m"
    echo -e "\033[1;36m├──────────┼─────────┼──────────────────────────┼─────────────────┼──────────┼───────────┤\033[0m"

    for anvil in $anvils; do
        local host port user key max_ram
        host=$(get_anvil_field "$anvil" "host")
        port=$(get_anvil_field "$anvil" "port")
        user=$(get_anvil_field "$anvil" "user")
        key=$(get_anvil_field "$anvil" "ssh_key")
        max_ram=$(get_anvil_field "$anvil" "max_ram_mb")

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

        # Check connectivity using ssh
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "echo OK" &>/dev/null
        local reachable=$?
        set -e

        if [ $reachable -eq 0 ]; then
            # Query active statistics
            local free_out cpu_out libvirt_out
            set +e
            free_out=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "free -m" 2>/dev/null)
            cpu_out=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "cat /proc/loadavg 2>/dev/null || uptime" 2>/dev/null)
            libvirt_out=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "systemctl is-active libvirtd virtqemud 2>/dev/null | grep -q '^active$' && echo 'active' || echo 'inactive'" 2>/dev/null)
            set -e

            # Parse RAM
            local ram_total ram_used ram_free
            ram_total=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $2}' || echo "0")
            ram_used=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $3}' || echo "0")
            
            # Use available column if 7 columns are present, else free column
            local cols
            cols=$(echo "$free_out" | grep -E '^Mem:' | awk '{print NF}' || echo "0")
            if [ "$cols" -ge 7 ]; then
                ram_free=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $7}' || echo "0")
            else
                ram_free=$(echo "$free_out" | grep -E '^Mem:' | awk '{print $4}' || echo "0")
            fi

            [ -z "$max_ram" ] && max_ram=$ram_total

            # Parse CPU load
            local cpu_load
            cpu_load=$(echo "$cpu_out" | awk '{print $1 ", " $2 ", " $3}' | tr -d '\r\n' || echo "N/A")
            # If loadavg parsing failed, clean up output
            if [[ "$cpu_load" == *"load"* ]]; then
                cpu_load=$(echo "$cpu_out" | sed -E 's/.*load average(s)?: //I' | tr -d '\r\n')
            fi

            # Parse Libvirt status
            local libvirt_state="INACTIVE"
            if [ -n "$libvirt_out" ]; then
                local raw_state
                raw_state=$(echo "$libvirt_out" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
                if [ "$raw_state" = "ACTIVE" ]; then
                    libvirt_state="ACTIVE"
                fi
            fi

            local status_str="\033[1;32mONLINE \033[0m"
            local libvirt_str="\033[1;32mACTIVE   \033[0m"
            [ "$libvirt_state" = "INACTIVE" ] && libvirt_str="\033[1;31mINACTIVE \033[0m"

            # Format outputs for tabular layout
            printf "\033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-24s \033[1;36m│\033[0m %-5s / %-5sMB \033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m\n" \
                "$anvil" "$status_str" "$host" "$ram_free" "$max_ram" "${cpu_load:0:8}" "$libvirt_str"
        else
            local status_str="\033[1;31mOFFLINE\033[0m"
            local na="\033[1;30mN/A      \033[0m"
            printf "\033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-24s \033[1;36m│\033[0m %-15s \033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m\n" \
                "$anvil" "$status_str" "$host" "N/A" "N/A" "$na"
        fi
    done

    echo -e "\033[1;36m└────────────────────────────────────────────────────────────────────────────────────────┘\033[0m\n"
}
