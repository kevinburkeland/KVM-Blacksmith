#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite: Provisioning Integrations
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
  make_mock "ssh-keygen" 'exit 1'
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

@test "Provisioning: runs default Ansible playbook when --run-playbook is passed" {
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
      echo "[INFO] The Default User is forgeuser"
      exit 0
    fi
    exit 0
  '

  run ./bin/kvm-blacksmith provision -m 2048 --run-playbook
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Executing Ansible configuration playbook"* ]]
  [[ "$clean_out" == *"Ansible post-provision configuration completed successfully"* ]]
  [[ "$clean_out" == *"MOCK PLAYBOOK EXECUTION: -i 192.168.122.100, "*"-u forgeuser"* ]]
}

@test "Provisioning: runs custom Ansible playbook when --playbook is passed" {
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

  local custom_pb="${BATS_TEST_DIRNAME}/custom_pb.yml"
  touch "$custom_pb"

  run ./bin/kvm-blacksmith provision -m 2048 --playbook "$custom_pb"
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  [[ "$clean_out" == *"Executing Ansible configuration playbook"* ]]
  [[ "$clean_out" == *"$custom_pb"* ]]
  [[ "$clean_out" == *"Ansible post-provision configuration completed successfully"* ]]
  
  rm -f "$custom_pb"
}

@test "Provisioning: auto-copies configure_guest.yml.example when configure_guest.yml does not exist" {
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

  # Verify file is not there (setup deletes it)
  [ ! -f "$PLAYBOOK_PATH" ]

  run ./bin/kvm-blacksmith provision -m 2048 --run-playbook
  [ "$status" -eq 0 ]
  clean_out=$(strip_colors "$output")
  
  [[ "$clean_out" == *"Creating default playbook from template"* ]]
  [ -f "$PLAYBOOK_PATH" ]
}

@test "Provisioning: collects and passes existing VM names to FORGE_EXCLUDED_NAMES" {
  local ssh_log="${BATS_TEST_DIRNAME}/ssh_calls.log"
  rm -f "$ssh_log"

  make_mock "ssh" "
    echo \"ssh called with: \$*\" >> \"$ssh_log\"
    if [[ \"\$*\" == *\"virsh list --all --name\"* ]]; then
      if [[ \"\$*\" == *\"192.168.1.101\"* ]]; then
        echo -e \"occupied-vm-1.forge.example\noccupied-vm-2.forge.example\"
      elif [[ \"\$*\" == *\"192.168.1.102\"* ]]; then
        echo \"occupied-vm-3.forge.example\"
      fi
      exit 0
    fi
    if [[ \"\$*\" == *\"free -m\"* ]]; then
      echo -e \"Mem: 32768 28768 20000\"
      exit 0
    fi
    if [[ \"\$*\" == *\"command -v\"* ]]; then
      echo \"/usr/bin/kvm-forge-cli\"
      exit 0
    fi
    if [[ \"\$*\" == *\"kvm-forge-cli\"* ]]; then
      echo \"The VM is named test-vm-prov\"
      echo \"The IP is 192.168.122.100\"
      echo \"Default User: ubuntu\"
      exit 0
    fi
    exit 0
  "

  run ./bin/kvm-blacksmith provision -m 2048
  [ "$status" -eq 0 ]
  
  # Assert that the remote CLI command with FORGE_EXCLUDED_NAMES was invoked via ssh
  run grep "FORGE_EXCLUDED_NAMES" "$ssh_log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORGE_EXCLUDED_NAMES=\"occupied-vm-1,occupied-vm-2,occupied-vm-3\""* ]]

  rm -f "$ssh_log"
}

@test "Provisioning: removes VM IP from known_hosts if it already exists" {
  local ssh_keygen_log="${BATS_TEST_DIRNAME}/ssh_keygen_calls.log"
  rm -f "$ssh_keygen_log"

  make_mock "ssh-keygen" "
    echo \"ssh-keygen called with: \$*\" >> \"$ssh_keygen_log\"
    if [[ \"\$*\" == *\"-F\"* ]]; then
      exit 0
    fi
    exit 0
  "

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

  run ./bin/kvm-blacksmith provision -m 2048
  [ "$status" -eq 0 ]

  [ -f "$ssh_keygen_log" ]
  run grep "ssh-keygen called with: -F 192.168.122.100" "$ssh_keygen_log"
  [ "$status" -eq 0 ]
  run grep "ssh-keygen called with: -R 192.168.122.100" "$ssh_keygen_log"
  [ "$status" -eq 0 ]

  rm -f "$ssh_keygen_log"
}

@test "Provisioning: does not remove VM IP from known_hosts if it does not exist" {
  local ssh_keygen_log="${BATS_TEST_DIRNAME}/ssh_keygen_calls.log"
  rm -f "$ssh_keygen_log"

  make_mock "ssh-keygen" "
    echo \"ssh-keygen called with: \$*\" >> \"$ssh_keygen_log\"
    if [[ \"\$*\" == *\"-F\"* ]]; then
      exit 1
    fi
    exit 0
  "

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

  run ./bin/kvm-blacksmith provision -m 2048
  [ "$status" -eq 0 ]

  [ -f "$ssh_keygen_log" ]
  run grep "ssh-keygen called with: -F 192.168.122.100" "$ssh_keygen_log"
  [ "$status" -eq 0 ]
  run grep "ssh-keygen called with: -R 192.168.122.100" "$ssh_keygen_log"
  [ "$status" -ne 0 ]

  rm -f "$ssh_keygen_log"
}

