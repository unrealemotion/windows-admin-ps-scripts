# Hyper-V Multi-Environment Lab Creation Script

## 1. Overview

This PowerShell script automates the setup of multiple, distinct Hyper-V lab environments based on provided Windows Server VHDX template files (e.g., 2016.vhdx, 2019.vhdx, 2022.vhdx).

For each specified template VHDX, the script constructs a complete lab environment designed to simulate a multi-site network configuration. This includes:

*   Creating dedicated directory structures on a target drive.
*   Creating isolated 'Internal' type Hyper-V virtual switches for each simulated site.
*   Deploying virtual machines (Domain Controller, Nodes, iSCSI Target, Gateway) within each environment.
*   Copying the base VHDX template and renaming it appropriately for each deployed VM.
*   Configuring specific resources (Memory, Generation) for each VM role.
*   Enabling Nested Virtualization for Node VMs.
*   Configuring the Gateway VM with multiple network adapters connected to the different site switches.

## 2. Features

*   **Multi-Environment Deployment:** Creates separate lab setups for each specified VHDX template base name (e.g., "2016", "2019").
*   **Automated Directory Structure:** Generates a consistent folder hierarchy for each lab environment and its components (Sites, Gateway).
*   **Virtual Switch Creation:** Creates necessary 'Internal' Hyper-V switches for network segmentation between sites within each lab.
*   **VM Deployment:** Automates the creation of multiple VMs per environment:
    *   Site VMs: Domain Controller (DC), Node\_1, Node\_2, iSCSI Target Server per site (Sites 1-3).
    *   Gateway VM: Configured with NICs connecting to each site's switch.
*   **VHDX Management:** Copies the source template VHDX for each VM, renaming it specific to the VM's role and environment.
*   **Configuration:** Assigns predefined memory and generation settings to VMs.
*   **Nested Virtualization:** Automatically enables nested virtualization (`ExposeVirtualizationExtensions`) for Node VMs.
*   **Idempotency:** Checks for the existence of directories, switches, and VMs before attempting creation, skipping existing items with a warning.
*   **Prerequisite Checks:** Verifies Administrator privileges and the availability of the Hyper-V PowerShell module before execution.
*   **Console Reporting:** Outputs progress messages, warnings, and errors directly to the PowerShell console.

## 3. Prerequisites

*   **Operating System:** Windows 10/11 or Windows Server with the **Hyper-V Role enabled**.
*   **PowerShell:** Version 5.1 or later.
*   **Hyper-V Module:** The Hyper-V PowerShell module must be installed (typically comes with the Hyper-V Role).
*   **Permissions:** The script **must** be run with **Administrator** privileges.
*   **Source VHDX Templates:** The template VHDX files (e.g., `2016.vhdx`, `2019.vhdx`) defined in the script's configuration must exist at the specified source location. **Generalized (Sysprep'd) templates are highly recommended.**
*   **Target Drive:** The base drive specified for lab creation must exist and have **sufficient free disk space** to accommodate copies of the VHDX files for *all* VMs across *all* environments.

## 4. Configuration

Before running the script, review and **modify the variables** within the `#region Configuration Variables` section of the script file (`.ps1`) as needed:

*   `[string]$SourceVHDXLocation`: Path to the directory containing your source VHDX template files.
    *   Default: `"C:\template\"`
*   `[string]$LabBaseDrive`: The drive letter where the lab environment directories will be created.
    *   Default: `"L:\"`
*   `[string[]]$SourceBaseNames`: An array of strings representing the base names of your VHDX templates (without the `.vhdx` extension). The script will create one full lab environment for each name listed here.
    *   Default: `@("2016", "2019", "2022")`
*   `[long]$DCMemory`: Startup memory assigned to Domain Controller VMs.
    *   Default: `2GB`
*   `[long]$NodeMemory`: Startup memory assigned to Node VMs.
    *   Default: `4GB`
*   `[long]$iSCSIMemory`: Startup memory assigned to iSCSI Target Server VMs.
    *   Default: `2GB`
*   `[long]$GatewayMemory`: Startup memory assigned to Gateway VMs.
    *   Default: `2GB`
*   `[int]$VMGeneration`: Generation number for all created VMs.
    *   Default: `2` (Ensure your templates match this generation).

## 5. Running the Script

1.  **Save:** Save the script content to a file (e.g., `Create-HyperVLabEnvironments.ps1`).
2.  **Configure:** **Edit the script file** and adjust the variables in the `#region Configuration Variables` section to match your source VHDX locations, desired target drive, template names, and resource requirements.
3.  **Run as Administrator:**
    *   **Method 1 (Recommended):** Open PowerShell **as Administrator**, navigate (`cd`) to the directory where you saved the script, and execute it:
        ```powershell
        .\Create-HyperVLabEnvironments.ps1
        ```
    *   **Method 2:** Right-click the `.ps1` file and select "Run with PowerShell". Grant administrative privileges if prompted by UAC. *(Note: PowerShell Execution Policy may affect this method)*.
4.  **Monitor Output:** Observe the progress messages in the PowerShell console. The script will indicate which environment it's processing and the actions being taken (creating directories, switches, VMs, copying VHDX files). Warnings will be shown for items that already exist.

## 6. Understanding the Output

*   **Console Messages:** The primary output is the real-time status messages displayed in the PowerShell console window during execution. This includes:
    *   Progress indicators for each lab environment and step.
    *   Confirmation messages for successful creations.
    *   Warnings (`Yellow`) if directories, switches, or VMs already exist (creation is skipped).
    *   Errors (`Red`) if failures occur during creation or configuration steps.
*   **Created Resources:** Upon successful completion, the script will have created the following on your system:
    *   **Directories:** Folders on the `$LabBaseDrive` for each environment (e.g., `L:\2019_Lab\`) containing subfolders for `Site_1`, `Site_2`, `Site_3`, and `GateWay`, holding the respective VM VHDX files and configuration.
    *   **Hyper-V Switches:** Internal virtual switches named according to the pattern `${BaseName}_Site_1`, `${BaseName}_Site_2`, etc. (e.g., `2019_Site_1`).
    *   **Hyper-V VMs:** Virtual machines named according to the pattern `${BaseName}_Site_X_Role` or `${BaseName}_GateWay` (e.g., `2019_Site_1_DC`, `2019_GateWay`) configured within Hyper-V Manager.

## 7. Troubleshooting & Important Notes

*   **Administrator Privileges:** Ensure the script is run from an elevated (Administrator) PowerShell session. The initial check should prevent execution otherwise.
*   **Hyper-V Module:** Verify the Hyper-V role and management tools (including the PowerShell module) are installed. The initial check should detect missing modules.
*   **Source VHDX Path:** Double-check the `$SourceVHDXLocation` variable and the VHDX filenames match those listed in `$SourceBaseNames`. The script will warn and skip an environment if its template VHDX is not found.
*   **Disk Space:** Lack of sufficient disk space on `$LabBaseDrive` is a common cause of failure during the VHDX copy process. Ensure ample space is available *before* running.
*   **Template Generalization (Sysprep):** Using generalized (Sysprep'd) VHDX templates is crucial to avoid issues with duplicate Security Identifiers (SIDs) and computer names when deploying multiple VMs from the same image.
*   **Existing Items:** The script is designed to skip existing items. If you need to recreate an environment, you may need to manually remove the corresponding directories, VMs, and switches first.
*   **Resource Usage:** Creating and running multiple VMs simultaneously, especially across several lab environments, can consume significant CPU, RAM, and Disk I/O resources on the host machine. Plan accordingly.
*   **Errors During Creation:** Check the console output for specific error messages from `New-VM`, `Copy-Item`, `New-VMSwitch`, etc. These often provide clues about the cause (e.g., path not found, insufficient resources, configuration conflicts).