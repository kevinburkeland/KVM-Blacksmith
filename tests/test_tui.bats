#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite: TUI Provisioning Wizard
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
      if [[ "$*" == *"Run post-provision Ansible"* ]]; then
        exit 1
      fi
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
  [[ "$clean_out" == *"Ansible:      None"* ]]
}

@test "TUI Provisioning: successfully configures Ansible from TUI" {
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

  make_mock "ansible-playbook" '
    echo "MOCK PLAYBOOK EXECUTION: $*"
    exit 0
  '
  make_mock "ssh" '
    if [[ "$*" == *"free -m"* ]]; then
      echo -e "Mem: 32768 28768 20000"
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
      elif [[ "$*" == *"Select Ansible Playbook"* ]]; then
        echo "Default Baseline Playbook"
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
  [[ "$clean_out" == *"Ansible:      Default Baseline Playbook"* ]]
  [[ "$clean_out" == *"Executing Ansible configuration playbook"* ]]
  [[ "$clean_out" == *"Ansible post-provision configuration completed successfully"* ]]
}
