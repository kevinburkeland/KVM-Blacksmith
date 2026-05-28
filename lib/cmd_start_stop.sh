# ==============================================================================
# KVM-Blacksmith: start & stop Subcommands Logic
# ==============================================================================

cmd_start() {
    local vm_name="${1:-}"
    if [ -z "$vm_name" ]; then
        log_err "Missing guest virtual machine identifier. Usage: kvm-blacksmith start <vm-name>"
        exit 1
    fi

    validate_manifest
    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_err "No Anvils defined in inventory manifest."
        exit 1
    fi

    local target_host=""
    local target_anvil=""
    local target_port=22
    local target_user="root"
    local target_key=""
    local target_key_arg=""

    log_info "Scanning cluster hypervisors for guest virtual machine: \033[1;33m$vm_name\033[0m..."

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

        # Check reachability
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "echo OK" &>/dev/null
        local reachable=$?
        set -e

        if [ $reachable -ne 0 ]; then
            continue
        fi

        # Check if VM exists on this host (validating libvirt connectivity first)
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh uri &>/dev/null && virsh list --all --name 2>/dev/null | grep -w -q \"$vm_name\"" &>/dev/null
        local has_vm=$?
        set -e

        if [ $has_vm -eq 0 ]; then
            target_anvil="$anvil"
            target_host="$host"
            target_port="$port"
            target_user="$user"
            target_key="$key"
            target_key_arg="$key_arg"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        log_err "VM '$vm_name' not found on any active Anvil in the cluster."
        exit 1
    fi

    log_info "Located guest on Anvil: \033[1;36m$target_anvil\033[0m ($target_host)"

    # Query VM state first and boot if stopped
    local remote_cmd
    remote_cmd="
        export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"
        export LIBVIRT_DEFAULT_URI=\"qemu:///system\"
        state=\$(virsh domstate \"$vm_name\" 2>/dev/null || echo \"unknown\")
        if [ \"\$state\" = \"running\" ]; then
            echo \"ALREADY_RUNNING\"
        else
            virsh start \"$vm_name\"
        fi
    "

    local remote_res
    set +e
    remote_res=$(ssh $SSH_OPTS $target_key_arg -p "$target_port" "$target_user@$target_host" "$remote_cmd" 2>/dev/null)
    local rc=$?
    set -e

    if [ $rc -ne 0 ]; then
        log_err "Failed to boot VM '$vm_name' on remote host $target_anvil."
        exit $rc
    fi

    if [[ "$remote_res" == *"ALREADY_RUNNING"* ]]; then
        log_info "VM '$vm_name' is already running on $target_anvil."
    else
        log_info "\033[1;32mGuest VM '$vm_name' successfully booted on $target_anvil.\033[0m"
    fi
}

cmd_stop() {
    local vm_name="${1:-}"
    if [ -z "$vm_name" ]; then
        log_err "Missing guest virtual machine identifier. Usage: kvm-blacksmith stop <vm-name>"
        exit 1
    fi

    validate_manifest
    local anvils
    anvils=$(get_anvils)

    if [ -z "$anvils" ]; then
        log_err "No Anvils defined in inventory manifest."
        exit 1
    fi

    local target_host=""
    local target_anvil=""
    local target_port=22
    local target_user="root"
    local target_key=""
    local target_key_arg=""

    log_info "Scanning cluster hypervisors for guest virtual machine: \033[1;33m$vm_name\033[0m..."

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

        # Check reachability
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "echo OK" &>/dev/null
        local reachable=$?
        set -e

        if [ $reachable -ne 0 ]; then
            continue
        fi

        # Check if VM exists on this host (validating libvirt connectivity first)
        set +e
        ssh $SSH_OPTS $key_arg -p "$port" "$user@$host" "export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"; export LIBVIRT_DEFAULT_URI=\"qemu:///system\"; virsh uri &>/dev/null && virsh list --all --name 2>/dev/null | grep -w -q \"$vm_name\"" &>/dev/null
        local has_vm=$?
        set -e

        if [ $has_vm -eq 0 ]; then
            target_anvil="$anvil"
            target_host="$host"
            target_port="$port"
            target_user="$user"
            target_key="$key"
            target_key_arg="$key_arg"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        log_err "VM '$vm_name' not found on any active Anvil in the cluster."
        exit 1
    fi

    log_info "Located guest on Anvil: \033[1;36m$target_anvil\033[0m ($target_host)"

    # Query VM state first and shutdown if running
    local remote_cmd
    remote_cmd="
        export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"
        export LIBVIRT_DEFAULT_URI=\"qemu:///system\"
        state=\$(virsh domstate \"$vm_name\" 2>/dev/null || echo \"unknown\")
        if [ \"\$state\" = \"shut off\" ] || [ \"\$state\" = \"shutoff\" ]; then
            echo \"ALREADY_STOPPED\"
        else
            virsh shutdown \"$vm_name\"
        fi
    "

    local remote_res
    set +e
    remote_res=$(ssh $SSH_OPTS $target_key_arg -p "$target_port" "$target_user@$target_host" "$remote_cmd" 2>/dev/null)
    local rc=$?
    set -e

    if [ $rc -ne 0 ]; then
        log_err "Failed to shutdown VM '$vm_name' on remote host $target_anvil."
        exit $rc
    fi

    if [[ "$remote_res" == *"ALREADY_STOPPED"* ]]; then
        log_info "VM '$vm_name' is already stopped on $target_anvil."
    else
        log_info "\033[1;32mGuest VM '$vm_name' successfully shutdown on $target_anvil.\033[0m"
    fi
}
