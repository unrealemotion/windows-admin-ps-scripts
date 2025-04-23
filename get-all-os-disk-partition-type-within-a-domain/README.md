# Active Directory OS Disk Partition Information Script

## 1. Purpose

This PowerShell script queries Active Directory for computer accounts and then remotely connects to each reachable computer to gather information specifically about its **Operating System disk**. It identifies the disk partition style (MBR or GPT), the number of partitions, and the types of partitions present on that OS disk. The results are displayed grouped by Organizational Unit (OU) in the console and can optionally be exported to a CSV file for inventory, analysis, or migration planning purposes (e.g., preparing for UEFI/GPT conversions).

## 2. Features

*   **Active Directory Integration:** Queries Active Directory to retrieve a list of target computer accounts based on specified filters.
*   **OU Filtering:** Allows targeting computers within a specific OU (`$searchBase` variable).
*   **Filtering:** Filters AD computers based on criteria (default: enabled accounts).
*   **OU Path Extraction:** Determines the OU path for each computer from its Distinguished Name for reporting.
*   **Reachability Check:** Uses `Test-WSMan` to quickly check if a computer is reachable via Windows Remote Management (WinRM) before attempting data collection.
*   **Remote Data Collection:** Uses `Invoke-Command` to securely run commands on remote computers to gather disk information.
*   **OS Disk Identification:** Specifically targets the disk marked as the `IsSystem` disk.
*   **Partition Information:** Collects:
    *   Disk Number of the OS disk.
    *   Partition Style (`MBR` or `GPT`).
    *   Total number of partitions on the OS disk.
    *   Comma-separated list of partition types (e.g., `Recovery, EFI, Reserved, Basic`).
*   **Error Handling:** Includes checks for AD module availability, AD query errors, WinRM reachability, and errors during remote data collection. Reports unreachable systems or errors encountered.
*   **Progress Reporting:** Displays a progress bar while iterating through the computer list.
*   **Grouped Console Output:** Presents the collected information grouped by OU and sorted alphabetically (OUs and computers within OUs) in a formatted table for easy reading.
*   **Optional CSV Export:** Allows exporting the raw collected data (including OU paths) to a CSV file using the `-ExportCsvPath` parameter for further analysis.

## 3. Requirements

*   **Operating System:** Windows machine capable of running PowerShell (modern versions recommended).
*   **PowerShell Modules:** `ActiveDirectory` module must be installed. This is typically part of the Remote Server Administration Tools (RSAT) for Active Directory Domain Services.
*   **WinRM:** Windows Remote Management (WinRM) must be **enabled and configured** on the target computers to allow remote command execution. Firewalls on the target machines must allow inbound WinRM traffic (typically TCP port 5985 for HTTP or 5986 for HTTPS).
*   **Permissions:**
    *   The account running the script needs **read permissions** in Active Directory to query computer accounts.
    *   The account running the script needs **permissions to execute remote PowerShell commands** via WinRM on the target computers (usually requires local Administrator rights on the targets or specific WinRM configuration). Running the script as a Domain Administrator often covers these requirements, but delegated permissions are preferable where possible.

## 4. Configuration

You can modify the following variables within the script's `# --- Configuration ---` section:

*   **`$searchBase`**:
    *   Set this to the Distinguished Name of a specific Organizational Unit (OU) if you only want to scan computers within that OU and its sub-OUs.
    *   Leave it as `$null` (the default) to search the entire domain.
    *   **Example:** `$searchBase = 'OU=Workstations,DC=yourdomain,DC=com'`

*   **`$adFilter`**:
    *   Specifies the LDAP filter used to query Active Directory computers.
    *   The default is `'Enabled -eq $true'`, which finds only active computer accounts.
    *   You can modify this to target specific operating systems, names, etc.
    *   **Example (Windows 10/11 only):** `$adFilter = 'Enabled -eq $true -and (OperatingSystem -like "*Windows 10*" -or OperatingSystem -like "*Windows 11*")'`

## 5. Usage

1.  **Save:** Save the script content to a file named (for example) `Get-OSDiskInfo.ps1`.
2.  **Configure (Optional):** Modify the `$searchBase` or `$adFilter` variables within the script if needed.
3.  **Run as Administrator:**
    *   Open PowerShell **as Administrator** (required for AD queries and potentially remote execution).
    *   Navigate to the directory where you saved the file using the `cd` command.
    *   Example: `cd C:\Scripts`
4.  **Execute the Script:**
    *   **Basic Execution (Console Output Only):**
        ```powershell
        .\Get-OSDiskInfo.ps1
        ```
    *   **Execution with CSV Export:**
        ```powershell
        .\Get-OSDiskInfo.ps1 -ExportCsvPath "C:\Reports\OS_Disk_Info.csv"
        ```
        (Replace `"C:\Reports\OS_Disk_Info.csv"` with your desired output file path).
5.  **Review Output:** Observe the progress bar and any warnings in the console. The final results will be displayed grouped by OU. If exporting, check the generated CSV file.

## 6. Understanding the Output

### Console Output

*   The script displays results grouped by the Organizational Unit (OU) path of the computers.
*   Within each OU, computers are listed alphabetically.
*   The table columns are:
    *   `ComputerName`: The name of the computer.
    *   `DiskNumber`: The number assigned to the OS disk by Windows.
    *   `DiskType`: Indicates the partition style (`MBR` or `GPT`). May show `Unreachable`, `Error`, or `OS Disk Not Found` if data collection failed.
    *   `PartitionCount`: The total number of partitions found on the OS disk.
    *   `PartitionTypes`: A comma-separated list of the types of partitions found (e.g., `Recovery, EFI, MSR, Basic`). May contain error details if collection failed.

### CSV Output (Optional)

*   If the `-ExportCsvPath` parameter is used, a CSV file is generated containing the **raw data** collected for *all* processed computers (including those that were unreachable or had errors).
*   The CSV file includes the following columns, sorted by `OUPath` then `ComputerName`:
    *   `ComputerName`
    *   `OUPath`
    *   `DiskNumber`
    *   `DiskType`
    *   `PartitionCount`
    *   `PartitionTypes`
*   This raw data is suitable for import into spreadsheets or databases for further analysis and reporting.

## 7. Troubleshooting & Important Notes

*   **Active Directory Module Missing:** Ensure RSAT for Active Directory Domain Services is installed on the machine running the script.
*   **Permissions Errors:**
    *   Verify the executing account has AD read permissions.
    *   Verify the executing account has permissions to run remote commands on target machines (check local Administrators group or WinRM configuration/permissions).
*   **WinRM Errors / Unreachable:**
    *   Ensure WinRM service is running on target computers (`winrm quickconfig` can help).
    *   Check firewall rules on target machines (allow TCP 5985/5986).
    *   Verify network connectivity and name resolution between the script machine and targets.
*   **OS Disk Not Found:** This might occur on systems with unusual configurations or if the disk properties cannot be read correctly.
*   **Performance:** Running this script against a large number of computers can take significant time and generate network traffic. Consider targeting specific OUs (`$searchBase`) if needed.
*   **Accuracy:** The reported information reflects the state of the remote computer *at the time the script queried it*.
*   **Execution Policy:** If you cannot run the script, your PowerShell Execution Policy might be restricted. You may need to run `Set-ExecutionPolicy RemoteSigned` (or similar) from an Administrator PowerShell prompt or use the `.\ScriptName.ps1` execution method from within an already open Admin PowerShell console.