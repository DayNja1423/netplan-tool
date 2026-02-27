#!/bin/bash
#
# Netplan Configuration Script
# For Ubuntu 22.04 LTS
#
# Usage (local):
#   sudo bash configure-netplan.sh
#
# Usage (remote - download & run):
#   curl -sSL <RAW_URL> -o /tmp/configure-netplan.sh && sudo bash /tmp/configure-netplan.sh
#
# Usage (remote - one-liner):
#   bash <(curl -sSL <RAW_URL>)
#

set -e

# -----------------------------------------------
# PIPE DETECTION: If piped via curl, save to a
# temp file and re-execute so stdin is the TTY
# (required for interactive questionary prompts)
# -----------------------------------------------
if [ ! -t 0 ]; then
    TMPSCRIPT=$(mktemp /tmp/configure-netplan-XXXXXX.sh)
    cat > "${TMPSCRIPT}"
    chmod +x "${TMPSCRIPT}"
    echo "[*] Detected piped input - re-launching from ${TMPSCRIPT} to restore TTY..."
    exec bash "${TMPSCRIPT}" "$@" < /dev/tty
fi

# -----------------------------------------------
# WORKING DIRECTORY SETUP
# -----------------------------------------------
# When run via curl/pipe, BASH_SOURCE may be empty
if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=$(mktemp -d /tmp/netplan-config-XXXXXX)
fi

PYTHON_DIR="${SCRIPT_DIR}/netplan_modules"
NETPLAN_JSON_FILE_PATH="/tmp/netplan_config.json"
LOG_FILE="/var/log/netplan-config-setup.log"

# Cleanup temp files on exit (only if we created a temp dir)
cleanup() {
    if [[ "${SCRIPT_DIR}" == /tmp/netplan-config-* ]]; then
        rm -rf "${SCRIPT_DIR}"
    fi
    if [[ -f "${TMPSCRIPT:-}" ]]; then
        rm -f "${TMPSCRIPT}"
    fi
}
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "${LOG_FILE}" 2>/dev/null
}

log_ok()   { log "${GREEN}[OK]${NC}    $1"; }
log_warn() { log "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { log "${RED}[ERROR]${NC} $1"; }
log_info() { log "${CYAN}[INFO]${NC}  $1"; }

echo ""
echo "============================================"
echo " Netplan Configuration Script"
echo " For Ubuntu 22.04 LTS"
echo "============================================"
echo ""

# -----------------------------------------------
# PRE-FLIGHT CHECKS
# -----------------------------------------------
log_info "Running pre-flight checks..."

# 1. Check for root
if [ "$EUID" -ne 0 ]; then
    log_err "This script must be run as root. Use: sudo bash $0"
    exit 1
fi
log_ok "Running as root"

# 2. Check OS & version
if [ ! -f /etc/os-release ]; then
    log_err "Cannot detect OS - /etc/os-release not found"
    exit 1
fi

. /etc/os-release
log_info "Detected OS: ${PRETTY_NAME}"

if [ "${ID}" != "ubuntu" ]; then
    log_warn "This script is designed for Ubuntu. Detected: ${ID}. Proceed with caution."
fi

UBUNTU_MAJOR=$(echo "${VERSION_ID}" | cut -d. -f1)
if [ "${UBUNTU_MAJOR}" -lt 20 ] 2>/dev/null; then
    log_warn "Ubuntu ${VERSION_ID} detected. This script is tested on 22.04 LTS."
fi

# 3. Check netplan is installed
if ! command -v netplan &> /dev/null; then
    log_err "netplan is not installed on this system."
    log_info "Install it with: apt-get install -y netplan.io"
    exit 1
fi
log_ok "netplan found: $(which netplan)"

# 4. Check existing netplan config files
NETPLAN_DIR="/etc/netplan"
if [ ! -d "${NETPLAN_DIR}" ]; then
    log_err "Netplan directory ${NETPLAN_DIR} does not exist"
    exit 1
fi

EXISTING_NETPLAN=$(ls ${NETPLAN_DIR}/*.yaml 2>/dev/null || true)
if [ -z "${EXISTING_NETPLAN}" ]; then
    log_warn "No existing netplan YAML files found in ${NETPLAN_DIR}"
    log_info "A new config file will be created at ${NETPLAN_DIR}/00-installer-config.yaml"
    touch "${NETPLAN_DIR}/00-installer-config.yaml"
else
    log_ok "Existing netplan config(s) found:"
    for f in ${EXISTING_NETPLAN}; do
        log_info "  - ${f}"
    done
fi

# 5. Detect available network interfaces
log_info "Available network interfaces:"
ip -br link show | while read line; do
    log_info "  ${line}"
done

# -----------------------------------------------
# DEPENDENCY INSTALLATION
# -----------------------------------------------
log_info "Installing dependencies..."

# Update apt cache
log_info "Updating apt package cache..."
if apt-get update -qq > /dev/null 2>&1; then
    log_ok "apt cache updated"
else
    log_warn "apt-get update had issues (may still work with cached packages)"
fi

# System packages needed
SYSTEM_PACKAGES=(
    "python3"
    "python3-pip"
    "python3-venv"
    "net-tools"
    "iproute2"
)

for pkg in "${SYSTEM_PACKAGES[@]}"; do
    if dpkg -l "${pkg}" 2>/dev/null | grep -q "^ii"; then
        log_ok "${pkg} already installed"
    else
        log_info "Installing ${pkg}..."
        if apt-get install -y --allow-downgrades "${pkg}" > /dev/null 2>&1; then
            log_ok "${pkg} installed successfully"
        else
            log_err "Failed to install ${pkg}"
            if [ "${pkg}" = "python3" ] || [ "${pkg}" = "python3-pip" ]; then
                log_err "python3/pip are required. Cannot continue."
                exit 1
            fi
        fi
    fi
done

# Verify python3 is functional
PYTHON_VERSION=$(python3 --version 2>&1)
if [ $? -ne 0 ]; then
    log_err "python3 is not functional after installation"
    exit 1
fi
log_ok "Python: ${PYTHON_VERSION}"

# Verify pip is functional
PIP_VERSION=$(pip3 --version 2>&1)
if [ $? -ne 0 ]; then
    log_err "pip3 is not functional after installation"
    exit 1
fi
log_ok "Pip: ${PIP_VERSION}"

# Install Python packages
PYTHON_PACKAGES=(
    "questionary==2.0.1"
)

log_info "Installing Python packages..."
for pypkg in "${PYTHON_PACKAGES[@]}"; do
    pkg_name=$(echo "${pypkg}" | cut -d= -f1)
    log_info "Installing/upgrading ${pypkg}..."
    if pip3 install "${pypkg}" -q 2>/dev/null; then
        log_ok "${pypkg} installed successfully"
    else
        # Fallback: try without pinned version
        log_warn "Pinned version failed, trying latest ${pkg_name}..."
        if pip3 install "${pkg_name}" --upgrade -q 2>/dev/null; then
            log_ok "${pkg_name} (latest) installed successfully"
        else
            log_err "Failed to install ${pkg_name}. Cannot continue."
            exit 1
        fi
    fi
done

# Final verification - import test
log_info "Verifying Python environment..."
if python3 -c "import questionary; import ipaddress; import json; import re" 2>/dev/null; then
    log_ok "All Python dependencies verified"
else
    log_err "Python dependency verification failed"
    exit 1
fi

echo ""
log_ok "All pre-flight checks passed. Dependencies installed."
echo ""

# Create config directory
mkdir -p "$(dirname ${NETPLAN_JSON_FILE_PATH})"

# Create the Python modules directory
mkdir -p "${PYTHON_DIR}"

# --- Write Python module: variables.py ---
cat > "${PYTHON_DIR}/variables.py" << 'PYEOF'
NETPLAN_OLD_FILE_FULL_PATH = "/etc/netplan/00-installer-config.yaml"
NETPLAN_NEW_FILE_FULL_PATH = "/etc/netplan/50-cloud-init.yaml"

GENERAL_CONFIGURATION = """
network:
  ethernets:
    {0}
  version: 2
"""

NIC_TEMPLATE = """
    {interface_name}:
        addresses: [{ip_address}]
        nameservers:
                addresses: [{dns_ip}]
        routes:
              - to: default
                via: {route_via}
                metric: {metric}
"""

VLAN_ONLY_HEADLINE = """
    {interface_name}:
      optional: true
  vlans:
"""

VLAN_TEMPLATE = """
    vlan{vlan_id_primary}:
      id: {vlan_id}
      link: {interface_name}
      addresses: [{ip_address}]
      nameservers:
        addresses: [{dns_ip}]
        search: []
      routes:
        - to: default
          via: {route_via}
          metric: {metric}
"""
PYEOF

# --- Write Python module: network_interface_configurator.py ---
cat > "${PYTHON_DIR}/network_interface_configurator.py" << 'PYEOF'
import ipaddress
import re
import subprocess
from abc import ABC, abstractmethod
from collections import defaultdict
from typing import List, Dict, Any, Callable

import questionary

MGMT_METRIC_NOTE = "Tip: Set the management interface with the lowest metric to give it top priority. For " \
                   "example, a metric of 0 takes priority over 1."
ATTACK_METRIC_NOTE = "Tip: The metric must be higher than the management interface (the lower the metric, " \
                     "the higher the priority) and unique from the other metrics "

MIN_VLAN_ID = 1
MAX_VLAN_ID = 4094


def validate_ip(ip: str) -> [bool, str]:
    return validate_text(ip, lambda text: ipaddress.ip_address(text) is not None, "Invalid IP")


def validate_ip_network(ip_network: str) -> [bool, str]:
    return validate_text(ip_network,
                         lambda text: "/" in text and ipaddress.ip_network(text, False) is not None,
                         "Invalid IP/subnet mask")


def validate_vlan_id(vlan_id: str) -> [bool, str]:
    return validate_text(vlan_id,
                         lambda text: vlan_id.isnumeric() and MIN_VLAN_ID <= int(vlan_id) <= MAX_VLAN_ID,
                         "Invalid VLAN ID")


def validate_interface_name(interface_name: str) -> [bool, str]:
    return validate_text(interface_name,
                         lambda text: re.match(r'^[a-zA-Z0-9_\-]+$', text) is not None,
                         "Invalid interface name")


def validate_metric(metric: str) -> [bool, str]:
    return validate_text(metric, lambda text: text.isnumeric() and 0 <= int(text), "Invalid Metric")


def validate_text(text: str, validation_function: Callable[[str], bool], error_message: str) -> [bool, str]:
    try:
        return True if validation_function(text) else error_message
    except ValueError:
        return error_message


def get_dns_ips() -> str:
    more_dns_ips: bool = True
    dns_ips: List[str] = []

    while more_dns_ips:
        dns_ip: str = questionary.text("DNS IPs (nameservers)", qmark='', validate=validate_ip).ask()
        dns_ips.append(dns_ip)
        more_dns_ips = questionary.confirm(f"Add another DNS?", qmark='').ask()

    return ", ".join(dns_ips)


def ip_matches_subnet(ip_address: str, ip_network: str) -> bool:
    try:
        return ipaddress.ip_address(ip_address) in ipaddress.ip_network(ip_network, False)
    except ValueError:
        return False


def create_nic(metric_note='') -> Dict[str, str]:
    metric_text: str = f"{metric_note}\n Metric" if metric_note else "Metric"
    get_host_interfaces()
    interface_name: str = questionary.text("Interface name", qmark='', validate=validate_interface_name).ask()
    ip_address: str = questionary.text("IP/subnet mask", qmark='', validate=validate_ip_network).ask()
    dns_ips: str = get_dns_ips()

    while True:
        default_gateway_ip: str = questionary.text("Default gateway IP", qmark='', validate=validate_ip).ask()
        is_valid_default_gateway_ip: bool = ip_matches_subnet(default_gateway_ip, ip_address)

        if is_valid_default_gateway_ip:
            break

        questionary.print(" The default gateway IP doesn't match the IP/subnet mask.")

    metric: str = questionary.text(metric_text, qmark='', validate=validate_metric).ask()

    return {
        "interface_name": interface_name,
        "ip_address": ip_address,
        "dns_ip": dns_ips,
        "route_via": default_gateway_ip,
        "metric": metric
    }


class NetworkInterfaceConfigurator(ABC):
    num_of_attack_network_interfaces: int = 0

    def __init__(self):
        self.mgmt_interface = None
        self.attack_interfaces: List[Dict[str, str]] = []

    def _get_network_interfaces(self) -> List[Dict[str, str]]:
        res: List[Dict[str, str]] = self.attack_interfaces.copy()

        if self.mgmt_interface:
            res.insert(0, self.mgmt_interface)

        return res

    @abstractmethod
    def _create_network_interface(self, metric_note='') -> Dict[str, str]:
        pass

    @property
    def network_interface_name(self) -> str:
        raise NotImplementedError

    def create_network_interface(self, metric_note='') -> Dict[str, str]:
        network_interface = self._create_network_interface(metric_note)
        self.attack_interfaces.append(network_interface)
        return network_interface

    def create_mgmt_network_interface(self, metric_note='') -> Dict[str, str]:
        questionary.print(f"Management {self.network_interface_name}")
        self.mgmt_interface: Dict[str, str] = self._create_network_interface(metric_note)
        return self.mgmt_interface

    def create_attack_network_interface(self) -> Dict[str, str]:
        self.num_of_attack_network_interfaces += 1
        questionary.print(f"Attack {self.network_interface_name} {self.num_of_attack_network_interfaces}")
        attack_interface: Dict[str, str] = self._create_network_interface(ATTACK_METRIC_NOTE)
        self.attack_interfaces.append(attack_interface)
        return attack_interface

    def create_attack_network_interfaces(self) -> List[Dict[str, str]]:
        more_network_interfaces: bool = True

        while more_network_interfaces:
            self.create_attack_network_interface()
            more_network_interfaces = questionary.confirm(f"Add another {self.network_interface_name}?", qmark='').ask()

        return self.attack_interfaces

    @abstractmethod
    def get_network_interfaces(self) -> Any:
        pass


class NicConfigurator(NetworkInterfaceConfigurator):
    network_interface_name: str = "NIC"

    def _create_network_interface(self, metric_note='') -> Dict[str, str]:
        return create_nic(metric_note)

    def get_network_interfaces(self) -> List[Dict[str, str]]:
        return self._get_network_interfaces()


class VlanConfigurator(NetworkInterfaceConfigurator):
    network_interface_name: str = "VLAN"

    def _create_network_interface(self, metric_note='') -> Dict[str, str]:
        vlan_id: str = questionary.text("VLAN ID", qmark='', validate=validate_vlan_id).ask()
        vlan: Dict[str, str] = {"vlan_id": vlan_id}
        nic: Dict[str, str] = create_nic(metric_note)
        vlan.update(nic)
        return vlan

    def get_network_interfaces(self) -> Dict[str, List[Dict[str, str]]]:
        res: Dict[str, List[Dict[str, str]]] = defaultdict(list)
        vlans: List[Dict[str, str]] = self._get_network_interfaces()

        for vlan in vlans:
            res[vlan["interface_name"]].append(vlan)

        return dict(res)
PYEOF

# --- Write Python module: netplan_configuration.py ---
cat > "${PYTHON_DIR}/netplan_configuration.py" << 'PYEOF'
from abc import ABC, abstractmethod
from typing import Dict, List, Any

import questionary

from network_interface_configurator import NicConfigurator, MGMT_METRIC_NOTE, VlanConfigurator, \
    NetworkInterfaceConfigurator


class NetplanConfiguration(ABC):
    @abstractmethod
    def build_configuration(self):
        pass

    @abstractmethod
    def to_dict(self) -> Dict[str, Any]:
        pass


class SingleNicConfiguration(NetplanConfiguration):
    def __init__(self):
        self.nic_configurator = NicConfigurator()

    def build_configuration(self):
        self.nic_configurator.create_mgmt_network_interface()

    def to_dict(self):
        return {"single": self.nic_configurator.mgmt_interface}


class MultipleNicsConfiguration(NetplanConfiguration):
    def __init__(self):
        self.nic_configurator = NicConfigurator()

    def build_configuration(self):
        self.nic_configurator.create_mgmt_network_interface(MGMT_METRIC_NOTE)
        self.nic_configurator.create_attack_network_interfaces()

    def to_dict(self):
        return {"multiple": self.nic_configurator.get_network_interfaces()}


class VlansConfiguration(NetplanConfiguration):
    def __init__(self):
        self.vlan_configurator = VlanConfigurator()

    def build_configuration(self):
        self.vlan_configurator.create_mgmt_network_interface(MGMT_METRIC_NOTE)
        self.vlan_configurator.create_attack_network_interfaces()

    def to_dict(self):
        return {"vlan": self.vlan_configurator.get_network_interfaces()}


class MultipleNicsAndVlansConfiguration(NetplanConfiguration):
    def __init__(self):
        self.nic_configurator = NicConfigurator()
        self.vlan_configurator = VlanConfigurator()

    def build_configuration(self):
        options_to_configurator: Dict[str, NetworkInterfaceConfigurator] = {
            "VLAN": self.vlan_configurator,
            "NIC": self.nic_configurator
        }
        choices: List[str] = list(options_to_configurator.keys())
        option: str = questionary.rawselect("Select management type:", choices=choices, qmark='').ask()
        options_to_configurator.get(option).create_mgmt_network_interface(MGMT_METRIC_NOTE)
        option: str = questionary.rawselect("Select attack type:", choices=choices, qmark='').ask()
        options_to_configurator.get(option).create_attack_network_interface()

        while True:
            add_another_interface: bool = questionary.confirm(f"Add another interface?", qmark='').ask()

            if not add_another_interface:
                break

            option: str = questionary.rawselect(
                "VLAN or NIC? Press 1 for VLAN or 2 for NIC",
                choices=choices,
                qmark=''
            ).ask()
            options_to_configurator.get(option).create_attack_network_interface()

    def to_dict(self):
        return {
            "vlan": self.vlan_configurator.get_network_interfaces(),
            "multiple": self.nic_configurator.get_network_interfaces()
        }
PYEOF

# --- Write Python module: modify_netplan_configuration.py ---
cat > "${PYTHON_DIR}/modify_netplan_configuration.py" << 'PYEOF'
import json
import os
import shlex
import subprocess
import sys

import variables as var


class CliResult:
    def __init__(self, exit_code, stdout, stderr):
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr


def run_cli_command(command: str):
    task = subprocess.Popen(shlex.split(command), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    task_output = task.communicate()
    return CliResult(task.returncode,
                     task_output[0].decode("utf-8"),
                     task_output[1].decode("utf-8"))


def validate_cli_command_output(cli_result_obj: CliResult):
    if hasattr(cli_result_obj, 'exit_code'):
        if cli_result_obj.exit_code == 0:
            return cli_result_obj.stdout
        else:
            raise Exception(f'Command exited with code {cli_result_obj.exit_code}. Stderr: {cli_result_obj.stderr}')
    else:
        raise Exception("Error parsing CliResult Object")


def create_full_netplan_file_path():
    if os.path.exists(var.NETPLAN_NEW_FILE_FULL_PATH):
        return var.NETPLAN_NEW_FILE_FULL_PATH
    elif os.path.exists(var.NETPLAN_OLD_FILE_FULL_PATH):
        return var.NETPLAN_OLD_FILE_FULL_PATH
    else:
        print("Can't find any netplan file in /etc/netplan")
        exit("Error in finding netplan file")


def backup_old_netplan_file(netplan_file_name):
    os.rename(netplan_file_name, "{file_name}_old".format(file_name=netplan_file_name))


def restore_old_netplan_file(netplan_file_name):
    os.remove(netplan_file_name)
    os.rename("{file_name}_old".format(file_name=netplan_file_name), netplan_file_name)


def create_single_nic_template(json_content):
    single_nic_key = json_content["single"]
    new_configuration = var.NIC_TEMPLATE.format(interface_name=single_nic_key["interface_name"],
                                                ip_address=single_nic_key["ip_address"],
                                                dns_ip=single_nic_key["dns_ip"], route_via=single_nic_key["route_via"],
                                                metric=single_nic_key["metric"])
    return new_configuration


def create_multiple_nic_template(json_content):
    multiple_nic_dict = json_content["multiple"]
    new_configuration = ""
    for nic in multiple_nic_dict:
        new_configuration += var.NIC_TEMPLATE.format(interface_name=nic["interface_name"], ip_address=nic["ip_address"],
                                                     dns_ip=nic["dns_ip"], route_via=nic["route_via"],
                                                     metric=nic["metric"])
    return new_configuration


def create_vlan_nic_template(json_content):
    vlan_nic_dict = json_content["vlan"]
    for interface_name, all_trunk_ports_dict in vlan_nic_dict.items():
        new_configuration = var.VLAN_ONLY_HEADLINE.format(interface_name=interface_name)
        for nic in all_trunk_ports_dict:
            new_configuration += var.VLAN_TEMPLATE.format(vlan_id_primary=nic["vlan_id"], vlan_id=nic["vlan_id"],
                                                          interface_name=interface_name,
                                                          ip_address=nic["ip_address"], dns_ip=nic["dns_ip"],
                                                          route_via=nic["route_via"], metric=nic["metric"])
    return new_configuration


def create_netplan_from_json(json_content):
    new_template = ""

    if "single" in json_content and "multiple" in json_content:
        exit("Can't configure both of them")

    if "single" in json_content:
        new_template = create_single_nic_template(json_content)
    elif "multiple" in json_content:
        new_template = create_multiple_nic_template(json_content)
        if "vlan" in json_content:
            new_template += create_vlan_nic_template(json_content)
    elif "vlan" in json_content:
        new_template = create_vlan_nic_template(json_content)

    netplan_new_content = var.GENERAL_CONFIGURATION.format(new_template)
    return netplan_new_content


def create_new_netplan_file_template(json_file_path):
    with open(json_file_path, "r") as user_input_json:
        json_content = json.load(user_input_json)
    return create_netplan_from_json(json_content)


def create_new_netplan_file(new_content, netplan_file_name):
    with open(netplan_file_name, 'w') as new_file:
        new_file.write(new_content)


def apply_netplan_changes(netplan_file_name):
    apply_netplan_conf = "netplan apply"
    output = run_cli_command(apply_netplan_conf)
    validate_cli_command_output(output)


if __name__ == "__main__":
    json_file_path = sys.argv[1]
    netplan_file_name = create_full_netplan_file_path()
    backup_old_netplan_file(netplan_file_name)
    try:
        new_conf_content = create_new_netplan_file_template(json_file_path)
        create_new_netplan_file(new_conf_content, netplan_file_name)
        apply_netplan_changes(netplan_file_name)
    except:
        print("Error in netplan configuration, restoring backup")
        restore_old_netplan_file(netplan_file_name)
        output = run_cli_command("netplan apply")
        validate_cli_command_output(output)
PYEOF

# --- Write Python module: create_netplan_configuration.py (main entry point) ---
cat > "${PYTHON_DIR}/create_netplan_configuration.py" << 'PYEOF'
import json
import sys
from typing import Dict, Any

import questionary

try:
    import termios
except ImportError:
    termios = None

from modify_netplan_configuration import create_netplan_from_json
from netplan_configuration import SingleNicConfiguration, MultipleNicsConfiguration, VlansConfiguration, \
    MultipleNicsAndVlansConfiguration, NetplanConfiguration


def create_netplan_configuration(json_file_path: str):
    confirm_configuration: bool = False

    # Flush pending terminal input to prevent first keypress being swallowed
    if termios:
        try:
            termios.tcflush(sys.stdin, termios.TCIFLUSH)
        except Exception:
            pass

    while not confirm_configuration:
        options_to_configuration: Dict[str, NetplanConfiguration] = {
            "Single NIC (same NIC for management and attack)": SingleNicConfiguration(),
            "Multiple NICs (several NICs for different network segments)": MultipleNicsConfiguration(),
            "VLANs (several VLANs for different network segments)": VlansConfiguration(),
            "Multiple NICs & VLANs (both VLANs and NICs for different segments)": MultipleNicsAndVlansConfiguration(),
        }

        option: str = questionary.rawselect(
            "Select your interface configuration type",
            choices=list(options_to_configuration.keys()),
            qmark=''
        ).ask()

        netplan_config: NetplanConfiguration = options_to_configuration.get(option)
        netplan_config.build_configuration()
        netplan_config_dict: Dict[str, Any] = netplan_config.to_dict()
        yaml_config: str = create_netplan_from_json(netplan_config_dict)
        questionary.print('Review your Netplan configuration')
        questionary.print(yaml_config)
        confirm_configuration = questionary.confirm(
            f"Press Y to confirm and continue or N to start over (input will be lost)",
            qmark='').ask()

    with open(json_file_path, 'w') as json_file:
        json.dump(netplan_config_dict, json_file, indent=4)


if __name__ == '__main__':
    json_file_path: str = sys.argv[1] if len(sys.argv) > 1 else 'netplan_config.json'
    create_netplan_configuration(json_file_path)
PYEOF

echo "--------------------------------------------"
echo " Starting Netplan Configuration Wizard"
echo "--------------------------------------------"
echo ""

# Phase 1: Interactive configuration (collect user input and save JSON)
log_info "[Phase 1/2] Collecting network configuration..."
echo ""
cd "${PYTHON_DIR}"
python3 create_netplan_configuration.py "${NETPLAN_JSON_FILE_PATH}"
if [ $? -ne 0 ]; then
    log_err "Configuration wizard failed."
    exit 1
fi
cd "${SCRIPT_DIR}"
log_ok "Network configuration saved to ${NETPLAN_JSON_FILE_PATH}"

echo ""
log_info "[Phase 2/2] Applying netplan configuration..."

# Phase 2: Apply the configuration to the actual netplan file
cd "${PYTHON_DIR}"
python3 modify_netplan_configuration.py "${NETPLAN_JSON_FILE_PATH}"
if [ $? -ne 0 ]; then
    log_err "Failed to apply netplan configuration."
    exit 1
fi
cd "${SCRIPT_DIR}"

echo ""
echo "============================================"
log_ok "Netplan configuration applied successfully!"
echo "============================================"
log_info "JSON config:  ${NETPLAN_JSON_FILE_PATH}"
log_info "Log file:     ${LOG_FILE}"
log_info "Verify with:  cat /etc/netplan/*.yaml"
log_info "              ip addr show"
echo ""

# Clean up the Python modules directory (not needed after apply)
if [ -d "${PYTHON_DIR}" ]; then
    rm -rf "${PYTHON_DIR}"
    log_info "Cleaned up temporary Python modules"
fi
