#!/usr/bin/env bats
# ==============================================================================
# BATS Test Suite: Inventory Parsing
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
