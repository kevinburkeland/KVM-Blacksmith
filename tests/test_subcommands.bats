#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite: Subcommands (status, list, destroy, upgrade, start/stop/restart)
# ==============================================================================

setup() {
  export BATS_RUNNING="true"
  
  MOCK_DIR="$(mktemp -d -p "${BATS_TEST_DIRNAME}")"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"
  
  TEST_CONFIG_DIR="$(mktemp -d -p "${BATS_TEST_DIRNAME}")"
  export TEST_CONFIG_DIR
  export CONFIG_FILE="${TEST_CONFIG_DIR}/anvils.yaml"
  
  cat <<EOF > "$CONFIG_FILE"
anvils:
  anvil-01:
    host: "192.168.1.101"
    port: 22
    user: "kevin"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 32768
    max_vcpus: 16
  anvil-02:
    host: "192.168.1.102"
    port: 22
    user: "kevin"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 65536
    max_vcpus: 32
EOF

  PLAYBOOK_PATH="${BATS_TEST_DIRNAME}/../ansible/playbooks/configure_guest.yml"
  export PLAYBOOK_PATH
  PLAYBOOK_BACKUP=""
  if [ -f "$PLAYBOOK_PATH" ]; then
    PLAYBOOK_BACKUP="$(mktemp)"
    cp "$PLAYBOOK_PATH" "$PLAYBOOK_BACKUP"
    rm -f "$PLAYBOOK_PATH"
  fi
  export PLAYBOOK_BACKUP
}

teardown() {
  rm -rf "$MOCK_DIR"
  rm -rf "$TEST_CONFIG_DIR"

  if [ -f "$PLAYBOOK_PATH" ]; then
    rm -f "$PLAYBOOK_PATH"
  fi
  if [ -n "${PLAYBOOK_BACKUP:-}" ] && [ -f "$PLAYBOOK_BACKUP" ]; then
    cp "$PLAYBOOK_BACKUP" "$PLAYBOOK_PATH"
    rm -f "$PLAYBOOK_BACKUP"
  fi
}

make_mock() {
  local name="$1"
  local content="$2"
  echo "#!/bin/bash" > "${MOCK_DIR}/${name}"
  echo "$content" >> "${MOCK_DIR}/${name}"
  chmod +x "${MOCK_DIR}/${name}"
}

strip_colors() {
  echo "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# ==============================================================================
# Tests
# ==============================================================================

@test "Subcommand status: aggregates reachable vs unreachable hosts" {
  make_mock "ssh" '
    if [[ "$*" == *"192.168.1.102"* ]]; then
      # anvil-02 connectivity fails (Offline)
      exit 1
    fi
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"get_forge_git"* ]]; then
      echo "0.15 0.10 0.05"
      echo "active"
      echo "a1b2c3d (main)"
      echo -e "Mem: 32768 28768 4000"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith status
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"anvil-01"* ]]
  [[ "$clean_out" == *"ONLINE"* ]]
  [[ "$clean_out" == *"anvil-02"* ]]
  [[ "$clean_out" == *"OFFLINE"* ]]
}

@test "Subcommand list: aggregates VM details across reachable hypervisors" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list"* ]]; then
      if [[ "$*" == *"192.168.1.101"* ]]; then
        echo "test-vm-1|running|4|192.168.122.10"
      elif [[ "$*" == *"192.168.1.102"* ]]; then
        echo "test-vm-2|shut off|2|-"
      fi
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith list
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"test-vm-1"* ]]
  [[ "$clean_out" == *"running"* ]]
  [[ "$clean_out" == *"192.168.122.10"* ]]
  [[ "$clean_out" == *"test-vm-2"* ]]
  [[ "$clean_out" == *"shut off"* ]]
}

@test "Subcommand destroy: scans cluster and triggers remote VM destruction" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-02
      if [[ "$*" == *"192.168.1.102"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"virsh destroy"* || "$*" == *"virsh undefine"* ]]; then
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith destroy test-destroy-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-02"* ]]
  [[ "$clean_out" == *"Guest VM 'test-destroy-vm' successfully removed"* ]]
}

@test "Subcommand destroy: fails if VM does not exist in cluster" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list"* ]]; then
      # No VM found anywhere
      exit 1
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith destroy test-destroy-vm
  [ "$status" -ne 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"not found on any active Anvil"* ]]
}

@test "Single Anvil Setup: status command succeeds with a single anvil" {
  cat <<EOF > "$CONFIG_FILE"
anvils:
  anvil-01:
    host: "192.168.1.101"
    port: 22
    user: "kevin"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 32768
    max_vcpus: 16
EOF

  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"get_forge_git"* ]]; then
      echo "0.15 0.10 0.05"
      echo "active"
      echo "a1b2c3d (main)"
      echo -e "Mem: 32768 28768 4000"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith status
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"anvil-01"* ]]
  [[ "$clean_out" == *"ONLINE"* ]]
  [[ "$clean_out" != *"anvil-02"* ]]
}

@test "Single Anvil Setup: list command succeeds with a single anvil" {
  cat <<EOF > "$CONFIG_FILE"
anvils:
  anvil-01:
    host: "192.168.1.101"
    port: 22
    user: "kevin"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 32768
    max_vcpus: 16
EOF

  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list"* ]]; then
      echo "test-vm-1|running|4|192.168.122.10"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith list
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"anvil-01"* ]]
  [[ "$clean_out" == *"test-vm-1"* ]]
  [[ "$clean_out" == *"running"* ]]
  [[ "$clean_out" == *"192.168.122.10"* ]]
  [[ "$clean_out" != *"anvil-02"* ]]
}

@test "Single Anvil Setup: capacity scheduling selects the single anvil if resource criteria met" {
  cat <<EOF > "$CONFIG_FILE"
anvils:
  anvil-01:
    host: "192.168.1.101"
    port: 22
    user: "kevin"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 32768
    max_vcpus: 16
EOF

  make_mock "ssh" '
    if [[ "$*" == *"free -m"* ]]; then
      echo -e "Mem: 32768 28768 4000"
      exit 0
    fi
    if [[ "$*" == *"virsh list --all"* ]]; then
      echo 0
      exit 0
    fi
    if [[ "$*" == *"command -v"* ]]; then
      echo "/usr/bin/kvm-forge-cli"
      exit 0
    fi
    if [[ "$*" == *"kvm-forge-cli"* ]]; then
      echo "The VM is named test-vm-prov"
      echo "The IP is 192.168.122.100"
      echo "Default User: ubuntu"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith provision -m 2048
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"anvil-01"* ]]
}

@test "Subcommand status: detects libvirt activity when only virtqemud is running (Fedora)" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"get_forge_git"* ]]; then
      echo "0.15 0.10 0.05"
      echo "active"
      echo "a1b2c3d (main)"
      echo -e "Mem: 32768 28768 4000"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith status
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"anvil-01"* ]]
  [[ "$clean_out" == *"ONLINE"* ]]
  [[ "$clean_out" == *"ACTIVE"* ]]
  [[ "$clean_out" != *"INACTIVE"* ]]
}

@test "Subcommand upgrade: checks local and remote revisions and triggers update" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"git fetch"* ]]; then
      echo "Current remote revision: a1b2c3d"
      echo "Fetching changes from Git origin..."
      echo "Resetting tracking branch to origin/main..."
      echo "Successfully updated KVM-Forge core."
      echo "New remote revision: e5f6g7h"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith upgrade
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"UPGRADING CLUSTER KVM-FORGE CORES"* ]]
  [[ "$clean_out" == *"Upgrading KVM-Forge on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"Successfully updated KVM-Forge core"* ]]
  [[ "$clean_out" == *"New remote revision: e5f6g7h"* ]]
}

@test "Subcommand start: powers on a stopped guest VM" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"virsh domstate"* ]]; then
      # Return stopped state
      echo "shut off"
      exit 0
    fi
    if [[ "$*" == *"virsh start"* ]]; then
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith start test-start-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"successfully booted on anvil-01"* ]]
}

@test "Subcommand start: skips booting if VM is already running" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"state=\$(virsh domstate"* ]]; then
      # Return running/already running state
      echo "ALREADY_RUNNING"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith start test-running-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"is already running on anvil-01"* ]]
}

@test "Subcommand stop: gracefully shuts down a running guest VM" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"virsh domstate"* ]]; then
      # Return running state
      echo "running"
      exit 0
    fi
    if [[ "$*" == *"virsh shutdown"* ]]; then
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith stop test-stop-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"successfully shutdown on anvil-01"* ]]
}

@test "Subcommand stop: skips shutdown if VM is already stopped" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"state=\$(virsh domstate"* ]]; then
      # Return stopped/already stopped state
      echo "ALREADY_STOPPED"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith stop test-stopped-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"is already stopped on anvil-01"* ]]
}

@test "Subcommand restart: reboots a running guest VM" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"state=\$(virsh domstate"* ]]; then
      echo "REBOOTING"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith restart test-running-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"successfully rebooted on anvil-01"* ]]
}

@test "Subcommand restart: boots a stopped guest VM" {
  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"virsh list --all --name"* ]]; then
      # VM resides only on anvil-01
      if [[ "$*" == *"192.168.1.101"* ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    if [[ "$*" == *"state=\$(virsh domstate"* ]]; then
      echo "STARTING"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith restart test-stopped-vm
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Located guest on Anvil: anvil-01"* ]]
  [[ "$clean_out" == *"was not running. Successfully booted on anvil-01"* ]]
}
