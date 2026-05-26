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
    if [[ "$*" == *"kvm-forge-cli provision"* ]]; then
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
    if [[ "$*" == *"kvm-forge-cli provision"* ]]; then
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
    if [[ "$*" == *"echo OK"* ]]; then
      if [[ "$*" == *"192.168.1.102"* ]]; then
        # anvil-02 connectivity fails (Offline)
        exit 1
      fi
      exit 0
    fi
    if [[ "$*" == *"free -m"* ]]; then
      echo -e "Mem: 32768 28768 4000"
      exit 0
    fi
    if [[ "$*" == *"cat /proc/loadavg"* ]]; then
      echo "0.15 0.10 0.05"
      exit 0
    fi
    if [[ "$*" == *"systemctl is-active libvirtd"* ]]; then
      echo "active"
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
