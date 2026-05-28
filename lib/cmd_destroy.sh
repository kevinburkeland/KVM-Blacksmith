# ==============================================================================
# KVM-Blacksmith: destroy Subcommand Logic
# ==============================================================================

cmd_destroy() {
    local vm_name="${1:-}"
    if [ -z "$vm_name" ]; then
        log_err "Missing guest virtual machine identifier. Usage: kvm-blacksmith destroy <vm-name>"
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
    log_info "Initiating remote VM teardown..."

    # Remote destroy instructions
    local remote_destroy_script
    remote_destroy_script="
        export PATH=\"\$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin\"
        export LIBVIRT_DEFAULT_URI=\"qemu:///system\"
        if virsh domstate \"$vm_name\" 2>/dev/null | grep -q \"running\"; then
            echo \"Stopping running guest...\"
            virsh destroy \"$vm_name\"
        fi
        echo \"Removing storage and undefined domain definitions...\"
        virsh undefine --remove-all-storage --nvram \"$vm_name\"
    "

    set +e
    ssh $SSH_OPTS $target_key_arg -p "$target_port" "$target_user@$target_host" "$remote_destroy_script"
    local destroy_rc=$?
    set -e

    if [ $destroy_rc -ne 0 ]; then
        log_err "Failed to destroy VM '$vm_name' on remote host $target_anvil (exit code $destroy_rc)."
        exit $destroy_rc
    fi

    log_info "\033[1;32mGuest VM '$vm_name' successfully removed from the cluster.\033[0m"
}
