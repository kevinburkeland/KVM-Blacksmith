# KVM-Blacksmith 🔨

**KVM-Blacksmith** is the centralized, lightweight cluster orchestrator for the **KVM-Forge** virtual machine provisioning ecosystem. 

Designed for systems administrators and DevOps educators, KVM-Blacksmith enables you to coordinate, schedule, deploy, and monitor virtual machines across multiple remote **Anvil** compute nodes (hypervisors running `kvm-forge-cli`) using a pure, robust, and secure Bash-compliant control agent.

> [!WARNING]
> **Work in Progress**: This orchestrator is currently a work in progress and remains untested in a production cluster environment. The code is being uploaded to GitHub to facilitate distributed testing.

---

## 📖 Key Architectural Principles

- **Agentless Orchestration**: Communicates entirely via secure, non-interactive, lightweight SSH wrappers (`ssh -o ConnectTimeout=3 -o BatchMode=yes`). No complex daemon or database is required on remote hosts.
- **Dynamic Capacity Scheduling**: Queries active resource utilization (`free -m`) on compute hosts dynamically. Automatically schedules virtual machines on the node with the **highest available free RAM**.
- **Tie-Breaking Load Balancing**: If multiple hypervisors share identical free RAM, the scheduler queries virtual machine workloads (`virsh list --all`) and places the guest on the host with the **least active/total VMs**.
- **Rigorous Shell Security**: Built with modern Bash robustness flags (`set -euo pipefail`), active environment validation to prevent command injections (`validate_forge_env_file`), and safe variable expansions inside exit traps.
- **Transparent Execution**: Maintaining high educational value, KVM-Blacksmith logs all raw commands transmitted to hypervisors, keeping the cluster operations completely visible.

---

## 🛠️ Configuration Manifest (`config/anvils.yaml`)

Define your physical hypervisor fleet inside the inventory manifest located at `config/anvils.yaml`. It details node host addresses, ports, credentials, private SSH keys, and resource capacity limits:

```yaml
anvils:
  anvil-01:
    host: "[IP_ADDRESS]"
    port: 22
    user: "forge"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 32768
    max_vcpus: 16
  anvil-02:
    host: "[IP_ADDRESS]"
    port: 22
    user: "forge"
    ssh_key: "~/.ssh/id_ed25519"
    max_ram_mb: 65536
    max_vcpus: 32
```

---

## 🕹️ CLI Usage and Subcommands

KVM-Blacksmith provides four core subcommands designed to operate on your cluster:

### 1. Visualizing Cluster Status
Queries all Anvils in your inventory, checks connection health, loads RAM details, parses CPU load metrics, and verifies the local `libvirtd` systemd service status:
```bash
./bin/kvm-blacksmith status
```
**Tabular ASCII Visualization:**
```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                  ANVIL CLUSTER STATUS                                  │
├──────────┬─────────┬──────────────────────────┬─────────────────┬──────────┬───────────┤
│ Anvil    │ Status  │ IP/Host                  │ RAM (Free/Max)  │ CPU Load │ Libvirt   │
├──────────┼─────────┼──────────────────────────┼─────────────────┼──────────┼───────────┤
│ anvil-01 │ ONLINE  │ 192.168.1.101            │ 24576 / 32768MB │ 0.15,... │ ACTIVE    │
│ anvil-02 │ ONLINE  │ 192.168.1.102            │ 49152 / 65536MB │ 0.45,... │ ACTIVE    │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2. Collating Guest Virtual Machines
Queries all active hypervisors simultaneously using a high-performance packaged remote query script, aggregating a single, unified view of all virtual machines, states, vCPU allocations, and dynamic IP leases:
```bash
./bin/kvm-blacksmith list
```
**Tabular ASCII Visualization:**
```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 GUEST VIRTUAL MACHINES                                 │
├──────────┬──────────────────────┬──────────────────────┬─────────┬─────────────────────┤
│ Anvil    │ VM Name              │ State                │ vCPUs   │ IP Address          │
├──────────┼──────────────────────┼──────────────────────┼─────────┼─────────────────────┤
│ anvil-01 │ ubuntu-web           │ running              │ 4       │ 192.168.122.10      │
│ anvil-01 │ debian-db            │ shut off             │ 2       │ -                   │
│ anvil-02 │ gentoo-sandbox       │ running              │ 8       │ 192.168.122.30      │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3. Capacity-Scheduled Provisioning
Deploys virtual machines to the most appropriate Anvil hypervisor using the capacity scheduling algorithm. Streams the remote `kvm-forge-cli` progress in real-time, intercepts final connection metrics, and outputs a formatted deployment card:
```bash
./bin/kvm-blacksmith provision -d ubuntu -v 24.04 -p base -c 4 -m 8192 -s 30
```
*Optional `--anvil <name>` flag allows administrators to bypass capacity scheduling and target a specific node directly.*

**Provisioning Log Stream Card:**
```
┌────────────────────────────────────────────────────────┐
│              SCHEDULING CLUSTER PROVISION              │
├────────────────────────────────────────────────────────┤
[INFO] Scheduled Anvil Node: anvil-02 (192.168.1.102)
[INFO] Transmitting orchestration parameters to remote compute host...
└────────────────────────────────────────────────────────┘

... [Live remote virt-install and cloud-init output logs] ...

┌────────────────────────────────────────────────────────┐
│            PROVISIONING COMPLETE (CLUSTER STATE)       │
├────────────────────────────────────────────────────────┤
  Host Anvil:   anvil-02 (192.168.1.102)
  VM Name:      ubuntu-vm
  IP Address:   192.168.122.100
  Default User: ubuntu
└────────────────────────────────────────────────────────┘
```

### 4. Cluster-Wide VM Destruction
Scans all cluster Anvils to locate the host currently managing the target virtual machine. Securely stops the guest instance, undefines the hypervisor registration, and wimes all associated storage volumes and non-volatile configurations:
```bash
./bin/kvm-blacksmith destroy ubuntu-vm
```

---

## 🧪 Automated Testing

The suite uses the **BATS (Bash Automated Testing System)** framework to verify the orchestration logic under a 100% offline, predictable setup by mocking the heavy network/SSH layer using command interception.

### Executing Tests
Run the test suite using `bats` in the workspace directory:
```bash
bats tests/test_blacksmith_orchestration.bats
```

### Mocking Mechanics & Confinement Resilience
- **SSH Mock**: Intercepts outgoing queries dynamically depending on target parameters (simulating connection drops, matching memory loads of `4000` vs `8000` MB, and VM process counts) to feed BATS deterministic answers.
- **Snap Sandbox Workaround**: Snap-confined `yq` executables are sandboxed away from `/tmp` paths. To ensure compatibility, our BATS tests create volatile manifests inside the local workspace repository folder (`tests/`), avoiding confinement access errors.
- **ANSI Color stripping**: Since KVM-Blacksmith is built with rich ANSI terminal colors, our BATS assertions pass outputs through a regex filter to strip escape characters prior to pattern matching, ensuring reliable test assertions.

---

## 📖 Educational System Engineering Highlights

### 1. Robust Scoped Exit Cleanup
Traps execute at the end of shell life in the global scope (after local function closures). Under strict `set -u` nounset rules, referencing local temporary variables causes an unbound variable failure. We prevent this utilizing Bash parameter default substitution:
```bash
trap '[[ -n "${temp_log:-}" ]] && rm -f "$temp_log"' EXIT
```

### 2. High-Performance Packs
Instead of querying VM lists sequentially over multiple separate SSH network round-trips, we wrap multiple virsh inspect commands inside a single inline execution block:
```bash
virsh list --all --name | while read vm; do ...; done
```
This reduces remote connection overhead from 10 seconds to less than 1 second per host query.
