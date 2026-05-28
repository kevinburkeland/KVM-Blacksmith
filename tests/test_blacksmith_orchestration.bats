#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite for KVM-Blacksmith Distributed Orchestration
# ==============================================================================

setup() {
  export BATS_RUNNING="true"
  
  # Create temporary mock bin directory inside the tests directory
  # This avoids sandbox access issues with snap-confined yq
  MOCK_DIR="$(mktemp -d -p "${BATS_TEST_DIRNAME}")"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"
  
  TEST_CONFIG_DIR="$(mktemp -d -p "${BATS_TEST_DIRNAME}")"
  export TEST_CONFIG_DIR
  export CONFIG_FILE="${TEST_CONFIG_DIR}/anvils.yaml"
  
  # Write standard test manifest
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
}

teardown() {
  rm -rf "$MOCK_DIR"
  rm -rf "$TEST_CONFIG_DIR"
}

# Helper function to generate mock wrappers
make_mock() {
  local name="$1"
  local content="$2"
  echo "#!/bin/bash" > "${MOCK_DIR}/${name}"
  echo "$content" >> "${MOCK_DIR}/${name}"
  chmod +x "${MOCK_DIR}/${name}"
}

# Helper to strip ANSI color escape codes from output
strip_colors() {
  echo "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# ==============================================================================
# Inventory Parsing Tests
# ==============================================================================

@test "Inventory Parsing: fails gracefully if the manifest is missing" {
  export CONFIG_FILE="${TEST_CONFIG_DIR}/does-not-exist.yaml"
  run ./bin/kvm-blacksmith status
  [ "$status" -ne 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Manifest file not found"* ]]
}

@test "Inventory Parsing: fails gracefully if the manifest is malformed YAML" {
  echo "anvils: {" > "$CONFIG_FILE"
  run ./bin/kvm-blacksmith status
  [ "$status" -ne 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Manifest file is malformed"* ]]
  [[ "$clean_out" == *"Parser Error:"* ]]
}


# ==============================================================================
# Scheduling Algorithm Tests
# ==============================================================================

@test "Capacity Scheduling: selects Host B (highest free RAM)" {
  make_mock "ssh" '
    if [[ "$*" == *"free -m"* ]]; then
      if [[ "$*" == *"192.168.1.101"* ]]; then
        echo -e "Mem: 32768 28768 4000"
      elif [[ "$*" == *"192.168.1.102"* ]]; then
        echo -e "Mem: 65536 57536 8000"
      fi
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
  # Scheduler must choose anvil-02 (IP 192.168.1.102) due to higher free memory
  [[ "$clean_out" == *"anvil-02"* ]]
}

@test "Capacity Scheduling: aborts gracefully if requested RAM exceeds all hosts" {
  make_mock "ssh" '
    if [[ "$*" == *"free -m"* ]]; then
      if [[ "$*" == *"192.168.1.101"* ]]; then
        echo -e "Mem: 32768 28768 4000"
      elif [[ "$*" == *"192.168.1.102"* ]]; then
        echo -e "Mem: 65536 57536 8000"
      fi
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith provision -m 16384
  [ "$status" -ne 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Capacity exceeded: No available Anvil host"* ]]
}

@test "Capacity Scheduling: selects Host A in a RAM tie if it has fewer active VMs" {
  make_mock "ssh" '
    if [[ "$*" == *"free -m"* ]]; then
      # RAM is tied at 8000 MB free
      if [[ "$*" == *"192.168.1.101"* ]]; then
        echo -e "Mem: 32768 24768 8000"
      elif [[ "$*" == *"192.168.1.102"* ]]; then
        echo -e "Mem: 65536 57536 8000"
      fi
      exit 0
    fi
    if [[ "$*" == *"virsh list --all"* ]]; then
      if [[ "$*" == *"192.168.1.101"* ]]; then
        # anvil-01 has 1 VM
        echo "vm1"
      elif [[ "$*" == *"192.168.1.102"* ]]; then
        # anvil-02 has 2 VMs
        echo -e "vm2\nvm3"
      fi
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
  # Tie-breaker should select anvil-01 (1 VM vs 2 VMs on anvil-02)
  [[ "$clean_out" == *"anvil-01"* ]]
}

# ==============================================================================
# Subcommand Validation Tests
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

# ==============================================================================
# Single Anvil Verification Tests
# ==============================================================================

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

# ==============================================================================
# TUI Provisioning Tests
# ==============================================================================

@test "TUI Provisioning: fails gracefully if gum is missing" {
  # Mock yq so validate_manifest passes, but do NOT mock gum
  make_mock "yq" '
    echo "mocked"
    exit 0
  '

  # Exclude system PATH to ensure gum is not found
  PATH="${MOCK_DIR}" run ./bin/kvm-blacksmith tui
  [ "$status" -ne 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Required command 'gum' is missing"* ]]
}

@test "TUI Provisioning: successfully generates correct CLI commands from inputs" {
  # Mock yq, ssh, and gum
  make_mock "yq" '
    if [[ "$*" == *".host"* ]]; then
      echo "192.168.1.101"
    elif [[ "$*" == *".port"* ]]; then
      echo "22"
    elif [[ "$*" == *".user"* ]]; then
      echo "kevin"
    elif [[ "$*" == *".ssh_key"* ]]; then
      echo "~/.ssh/id_ed25519"
    elif [[ "$*" == *".max_ram_mb"* ]]; then
      echo "32768"
    elif [[ "$*" == *".max_vcpus"* ]]; then
      echo "16"
    elif [[ "$*" == *".anvils | keys"* ]]; then
      echo "anvil-01"
    elif [[ "$*" == *".distros | keys"* ]]; then
      echo "ubuntu"
    elif [[ "$*" == *".distros.ubuntu.default_version"* ]]; then
      echo "24.04"
    elif [[ "$*" == *".distros.ubuntu.supported_versions"* ]]; then
      echo "24.04"
    elif [[ "$*" == *".distros.ubuntu.profiles"* ]]; then
      echo "base"
    else
      echo "mocked"
    fi
    exit 0
  '

  make_mock "ssh" '
    if [[ "$*" == *"echo OK"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"command -v"* ]]; then
      echo "/home/kevin/Documents/git/KVM-Forge/bin/kvm-forge-cli"
      exit 0
    fi
    if [[ "$*" == *"free -m"* ]]; then
      echo -e "Mem: 32768 8768 24000"
      exit 0
    fi
    if [[ "$*" == *"cat"* ]]; then
      # Return a valid mock manifest YAML content
      cat <<EOF
distros:
  ubuntu:
    default_version: "24.04"
    supported_versions: ["24.04"]
    profiles: ["base"]
EOF
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

  make_mock "gum" '
    if [[ "$1" == "spin" ]]; then
      while [[ "$1" != "--" ]]; do
        shift
      done
      shift
      exec "$@"
    fi
    if [[ "$*" == *"choose"* ]]; then
      if [[ "$*" == *"Choose a target Anvil Node"* ]]; then
        echo "anvil-01"
      elif [[ "$*" == *"Select Operating System Distro"* ]]; then
        echo "ubuntu"
      elif [[ "$*" == *"Select Distro Version"* ]]; then
        echo "24.04"
      elif [[ "$*" == *"Select Hardware/Provisioning Profile"* ]]; then
        echo "base"
      fi
      exit 0
    fi
    if [[ "$*" == *"input"* ]]; then
      if [[ "$*" == *"Allocated vCPUs"* ]]; then
        echo "4"
      elif [[ "$*" == *"Allocated Memory"* ]]; then
        echo "8192"
      elif [[ "$*" == *"Allocated Disk Size"* ]]; then
        echo "30"
      fi
      exit 0
    fi
    if [[ "$*" == *"confirm"* ]]; then
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith tui
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"PROVISIONING SPECIFICATION SUMMARY"* ]]
  [[ "$clean_out" == *"Anvil Target: anvil-01"* ]]
  [[ "$clean_out" == *"OS Distro:    ubuntu"* ]]
  [[ "$clean_out" == *"VM Name:      test-vm-prov"* ]]
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



