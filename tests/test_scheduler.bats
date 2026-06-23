#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite: Capacity Scheduler
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
