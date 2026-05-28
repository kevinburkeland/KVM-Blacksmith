# ==============================================================================
# KVM-Blacksmith: upgrade Subcommand Logic
# ==============================================================================

cmd_upgrade() {
    validate_manifest
    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_warn "No Anvils defined in inventory manifest."
        exit 0
    fi

    # Retrieve local KVM-Forge git revision if available
    local local_sha=""
    local local_forge_dir=""
    for dir in "$HOME/Documents/git/KVM-Forge" "$HOME/KVM-Forge" "/opt/KVM-Forge"; do
        if [ -d "$dir/.git" ]; then
            local_forge_dir="$dir"
            break
        fi
    done

    if [ -n "$local_forge_dir" ]; then
        local_sha=$(cd "$local_forge_dir" && git rev-parse --short HEAD 2>/dev/null || true)
        log_info "Local KVM-Forge reference revision: \033[1;32m$local_sha\033[0m"
    else
        log_warn "Local KVM-Forge repository reference not found. Will pull latest changes from remote origin on all nodes."
    fi

    echo -e "\n\033[1;36m┌────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;36m│             UPGRADING CLUSTER KVM-FORGE CORES          │\033[0m"
    echo -e "\033[1;36m├────────────────────────────────────────────────────────┤\033[0m"

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
            log_warn "Anvil host $anvil ($host) is OFFLINE. Skipping KVM-Forge upgrade."
            continue
        fi

        log_info "Upgrading KVM-Forge on Anvil: \033[1;36m$anvil\033[0m ($host)..."

        local remote_script
        remote_script='
        export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"
        get_forge_root() {
            local cli_path
            if command -v kvm-forge-cli &>/dev/null; then
                cli_path=$(command -v kvm-forge-cli)
                dirname "$(dirname "$cli_path")"
            elif [ -d ~/KVM-Forge ]; then
                echo "$HOME/KVM-Forge"
            elif [ -d ~/Documents/git/KVM-Forge ]; then
                echo "$HOME/Documents/git/KVM-Forge"
            elif [ -d /opt/KVM-Forge ]; then
                echo "/opt/KVM-Forge"
            else
                echo ""
            fi
        }
        root=$(get_forge_root)
        if [ -z "$root" ] || [ ! -d "$root/.git" ]; then
            echo "ERROR: KVM-Forge git repository not found on remote server." >&2
            exit 1
        fi
        cd "$root"
        old_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "Current remote revision: $old_sha"
        echo "Fetching changes from Git origin..."
        git fetch --all --prune &>/dev/null
        
        # Get active tracking branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        echo "Resetting tracking branch to origin/$branch..."
        git reset --hard "origin/$branch"
        
        new_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "Successfully updated KVM-Forge core."
        echo "New remote revision: $new_sha"
        '

        # Execute remote upgrade
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "$remote_script"
        local rc=$?
        set -e

        if [ $rc -eq 0 ]; then
            log_info "\033[1;32mUpgrade succeeded on $anvil ($host).\033[0m\n"
        else
            log_err "Upgrade failed on $anvil ($host).\n"
        fi
    done
    echo -e "\033[1;36m└────────────────────────────────────────────────────────┘\033[0m\n"
}
