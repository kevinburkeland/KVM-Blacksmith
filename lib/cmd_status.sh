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
    echo -e "\n\033[1;36m┌────────────────────────────────────────────────────────────────────────────────────────┬─────────────────┐\033[0m"
    echo -e "\033[1;36m│                                           ANVIL CLUSTER STATUS                                           │\033[0m"
    echo -e "\033[1;36m├──────────┬─────────┬──────────────────────────┬─────────────────┬──────────┬───────────┬─────────────────┤\033[0m"
    echo -e "\033[1;36m│ Anvil    │ Status  │ IP/Host                  │ RAM (Free/Max)  │ CPU Load │ Libvirt   │ Git Version     │\033[0m"
    echo -e "\033[1;36m├──────────┼─────────┼──────────────────────────┼─────────────────┼──────────┼───────────┼─────────────────┤\033[0m"

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

        # Remote query packaged in a single SSH connection for maximum performance
        local remote_script
        remote_script='
        export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"
        cpu_out=$(cat /proc/loadavg 2>/dev/null || uptime 2>/dev/null || echo "N/A")
        libvirt_out=$(systemctl is-active libvirtd virtqemud 2>/dev/null | grep -q "^active$" && echo "active" || echo "inactive")
        
        get_forge_git() {
            local root=""
            if command -v kvm-forge-cli &>/dev/null; then
                root=$(dirname "$(dirname "$(command -v kvm-forge-cli)")")
            elif [ -d ~/KVM-Forge ]; then
                root="$HOME/KVM-Forge"
            elif [ -d ~/Documents/git/KVM-Forge ]; then
                root="$HOME/Documents/git/KVM-Forge"
            elif [ -d /opt/KVM-Forge ]; then
                root="/opt/KVM-Forge"
            fi
            if [ -n "$root" ] && [ -d "$root/.git" ]; then
                (
                    cd "$root" 2>/dev/null || return
                    local sha branch dirty
                    sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
                    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
                    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                        dirty="*"
                    else
                        dirty=""
                    fi
                    if [ -n "$branch" ]; then
                        echo "$sha ($branch)$dirty"
                    else
                        echo "$sha$dirty"
                    fi
                )
            else
                echo "N/A"
            fi
        }
        git_out=$(get_forge_git)
        free_out=$(free -m 2>/dev/null || echo "N/A")
        
        echo "$cpu_out"
        echo "$libvirt_out"
        echo "$git_out"
        echo "$free_out"
        '

        # Check connectivity using ssh
        set +e
        local remote_res
        remote_res=$(ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_script" 2>/dev/null)
        local reachable=$?
        set -e

        if [ $reachable -eq 0 ] && [ -n "$remote_res" ]; then
            # Parse metrics from single connection response
            local cpu_out libvirt_out git_out free_out
            cpu_out=$(echo "$remote_res" | head -n1)
            libvirt_out=$(echo "$remote_res" | head -n2 | tail -n1)
            git_out=$(echo "$remote_res" | head -n3 | tail -n1)
            free_out=$(echo "$remote_res" | tail -n +4)

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

            # Format outputs for tabular layout with truncation safety
            local anvil_display="$anvil"
            [ ${#anvil} -gt 8 ] && anvil_display="${anvil:0:5}..."
            local host_display="$host"
            [ ${#host} -gt 24 ] && host_display="${host:0:21}..."
            local git_display="$git_out"
            [ ${#git_out} -gt 15 ] && git_display="${git_out:0:12}..."

            printf "\033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-24s \033[1;36m│\033[0m %-5s / %-5sMB \033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-15s \033[1;36m│\033[0m\n" \
                "$anvil_display" "$status_str" "$host_display" "$ram_free" "$max_ram" "${cpu_load:0:8}" "$libvirt_str" "$git_display"
        else
            local status_str="\033[1;31mOFFLINE\033[0m"
            local na="\033[1;30mN/A      \033[0m"
            local anvil_display="$anvil"
            [ ${#anvil} -gt 8 ] && anvil_display="${anvil:0:5}..."
            local host_display="$host"
            [ ${#host} -gt 24 ] && host_display="${host:0:21}..."

            printf "\033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-24s \033[1;36m│\033[0m %-15s \033[1;36m│\033[0m %-8s \033[1;36m│\033[0m %b \033[1;36m│\033[0m %-15s \033[1;36m│\033[0m\n" \
                "$anvil_display" "$status_str" "$host_display" "N/A" "N/A" "$na" "N/A"
        fi
    done

    echo -e "\033[1;36m└────────────────────────────────────────────────────────────────────────────────────────┴─────────────────┘\033[0m\n"
}
