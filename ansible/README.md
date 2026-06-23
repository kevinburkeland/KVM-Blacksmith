# Ansible Integration for KVM-Blacksmith

This directory contains pure Bash dynamic inventory script and playbooks to integrate Ansible configuration management into the KVM-Blacksmith ecosystem.

## Dynamic Inventory

The inventory script dynamically queries `config/anvils.yaml` to provide a list of your hypervisors (Anvils) directly to Ansible.

### Usage

1. **Verify the Inventory Output**:
   Run the script with the `--list` flag:
   ```bash
   ./ansible/inventory/blacksmith_inventory.sh --list
   ```

2. **Test Ansible Connectivity**:
   Ping all active Anvils in your cluster:
   ```bash
   ansible -i ansible/inventory/blacksmith_inventory.sh anvils -m ping
   ```

---

## Post-Provisioning Guest Configuration

The default baseline playbook configures newly provisioned virtual machines automatically.

### Running Manually

To run the guest configuration playbook manually against a guest VM (by IP):
```bash
ansible-playbook -i "192.168.122.100," ansible/playbooks/configure_guest.yml \
  -u ubuntu \
  --ssh-common-args="-o StrictHostKeyChecking=accept-new"
```
*(Note: The trailing comma after the IP address is required by Ansible when passing a direct list of host IPs rather than an inventory file).*

### Running Automatically via KVM-Blacksmith

To run the baseline configuration automatically upon successful provisioning:
```bash
kvm-blacksmith provision --distro ubuntu --run-playbook
```

To run a custom playbook instead of the default baseline:
```bash
kvm-blacksmith provision --distro ubuntu --playbook /path/to/my_playbook.yml
```
