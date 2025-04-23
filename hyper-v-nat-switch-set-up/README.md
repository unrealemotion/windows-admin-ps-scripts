# Hyper-V NAT SwitchSwitch Setup Script

## Overview

This PowerShell script automates the creation and configuration of a Network Address Translation (NAT) network on a Windows machine with the Hyper-V role enabled. It simplifies setting up an internal virtual network where virtual machines (VMs) can access the external network via the host machine's connection, while being isolated on their own subnet.

## Features

*   **Administrator Check:** Ensures the script is run with necessary administrative privileges.
*   **Existing NAT Check:** Detects pre-existing `NetNat` configurations. Prompts the user for confirmation before removing an existing NAT setup to avoid conflicts.
*   **Existing Switch Check:** Checks if a Hyper-V virtual switch with the default name (`NetNat`) already exists. If so, prompts the user to provide an alternative name.
*   **Virtual Switch Creation:** Creates an 'Internal' type Hyper-V virtual switch using the specified (or default) name.
*   **Network Adapter Configuration:**
    *   Identifies the virtual network adapter associated with the newly created switch (using the naming convention `vEthernet (<Switch Name>)`).
    *   Assigns a static IP address (default: `192.168.1.1`) and subnet mask (derived from prefix length, default: `/24` -> `255.255.255.0`) to this adapter. This IP serves as the gateway for VMs on the NAT network.
*   **NAT Rule Creation:** Creates the `NetNat` rule that enables network traffic routing between the internal virtual switch subnet and the external network.
*   **Step-by-Step Reporting:** Provides informative messages in the console for each major action being performed.
*   **Error Handling:** Includes `try-catch` blocks to handle potential errors during switch creation, IP configuration, and NAT setup, providing relevant error messages. Attempts cleanup on failure where appropriate.
*   **Summary Output:** Displays a summary upon completion, detailing the created resources (switch name, gateway IP, NAT subnet) and providing clear instructions on how to configure VMs to use the new network.
*   **Pause on Completion:** Includes a final prompt to prevent the PowerShell window from closing immediately when run directly, allowing the user to review the summary.

## Requirements

*   **Operating System:** Windows 10/11 or Windows Server with the Hyper-V role enabled.
*   **PowerShell Modules:** `Hyper-V` module must be installed and available.
*   **Permissions:** The script must be run with **Administrator** privileges.

## Configuration (Defaults)

The script uses the following default settings, which can be modified by editing the variables in the `# --- Configuration ---` section of the script file:

*   `$DefaultSwitchName`: `"NetNat"` (Default name for the Hyper-V switch)
*   `$IpAddress`: `"192.168.1.1"` (Gateway IP for the NAT network)
*   `$PrefixLength`: `24` (Subnet mask length, corresponds to `255.255.255.0`)
*   `$NatSubnet`: `"192.168.1.0/24"` (The IP range for the NAT network)
*   `$NatName`: `"HyperVNatNetwork"` (Internal name for the Windows NetNat object)

## Usage

1.  **Save:** Save the script content to a file named (for example) `Setup-HyperVNat.ps1`.
2.  **Run as Administrator:**
    *   **Method 1 (Recommended):** Open PowerShell **as Administrator**, navigate to the directory where you saved the file, and run the script:
        ```powershell
        .\Setup-HyperVNat.ps1
        ```
    *   **Method 2:** Right-click the `.ps1` file and select "Run with PowerShell". If prompted by UAC, allow administrative privileges. *(Note: Execution Policy might prevent this method unless set appropriately)*.
3.  **Follow Prompts:**
    *   If an existing `NetNat` is found, you will be asked if you want to remove it (`y/n`).
    *   If a Virtual Switch with the name `NetNat` (or your chosen default) exists, you will be prompted to enter an alternative name or press Enter to abort.
4.  **Review Output:** Observe the step-by-step progress messages.
5.  **Check Summary:** After execution, review the final summary for details of the created resources and VM configuration instructions.
6.  **Press Enter:** Press Enter to close the PowerShell window if it was opened specifically to run the script.

## VM Configuration Instructions

Once the script completes successfully, configure the network adapter settings within your virtual machines that are connected to the created virtual switch (`NetNat` or the alternative name you provided) as follows:

*   **Connect VM:** Ensure the VM's network adapter in Hyper-V settings is connected to the virtual switch created by the script (e.g., `NetNat`).
*   **Static IP Configuration (Recommended):**
    *   **IP Address:** Choose an IP address within the NAT subnet range, ensuring it's not the gateway IP. Example: `192.168.1.100` (if using defaults).
    *   **Subnet Mask:** Use the subnet mask corresponding to the `$PrefixLength`. Example: `255.255.255.0` (for `/24`).
    *   **Default Gateway:** Use the IP address assigned to the switch's adapter by the script. Example: `192.168.1.1` (if using defaults).
    *   **DNS Servers:** You can typically use your host machine's DNS servers, your router's IP address, or public DNS servers like Google (`8.8.8.8`, `8.8.4.4`) or Cloudflare (`1.1.1.1`).
*   **DHCP (Optional):** While this script doesn't set up a DHCP server for the NAT network, you *could* configure one within a VM on this network if desired. By default, VMs will need static configuration.

## Troubleshooting

*   **Adapter Not Found Error:** The script waits 5 seconds (`Start-Sleep -Seconds 5`) after creating the switch for the `vEthernet (<Switch Name>)` adapter to appear. If you still get an error that the adapter wasn't found, it might occasionally take longer. Try running the script again. You can also manually check available adapters using `Get-NetAdapter` in an Admin PowerShell window.
*   **Execution Policy:** If you cannot run the script via double-click or right-click, your PowerShell Execution Policy might be restricted. You may need to run `Set-ExecutionPolicy RemoteSigned` (or less restrictive) from an Administrator PowerShell prompt, or use the "Run as Administrator" method from within an already open Admin PowerShell console.
*   **Errors During Removal/Creation:** Pay close attention to error messages logged by the script. They often indicate conflicts (e.g., IP address already in use on another adapter) or permissions issues.

---
