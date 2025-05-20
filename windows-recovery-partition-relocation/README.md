# Windows Recovery Environment and Relocation Tool

## Overview

`Rel-WinRE.ps1` is a PowerShell script designed to manage the Windows Recovery Environment (WinRE) partition. It offers two primary modes of operation:

1.  **Full Mode (`-Mode Full`):**
    *   Backs up the existing WinRE partition content.
    *   Disables the current WinRE.
    *   Deletes the old recovery partition.
    *   **Prompts the user to manually expand their C: drive and leave unallocated space at the end of the OS disk.**
    *   Creates a new recovery partition in the unallocated space.
    *   Restores the backed-up WinRE data to the new partition.
    *   Sets the correct partition ID and attributes.
    *   Re-enables WinRE, pointing to the new partition.
    This mode is useful for scenarios like resizing the C: drive when the recovery partition is in the way, or when needing to move the recovery partition to the end of the disk for better C: drive management.

2.  **RestoreOnly Mode (`-Mode RestoreOnly`):**
    *   **Assumes the user has already prepared unallocated space at the end of the OS disk.**
    *   Prompts the user for the path to a previously created WinRE backup (like one made by this script in "Full" mode) and the size of the unallocated space.
    *   Creates a new recovery partition in the unallocated space.
    *   Restores the WinRE data from the specified backup to the new partition.
    *   Sets the correct partition ID and attributes.
    *   Enables WinRE, pointing to the new partition.
    This mode is for restoring a WinRE environment from a backup to a pre-prepared space.

## Features

*   Automated backup of WinRE contents.
*   Safe disabling and re-enabling of WinRE using `reagentc.exe`.
*   Partition deletion and creation using `diskpart.exe`.
*   Setting of correct partition type IDs (for GPT and MBR disks) and attributes for recovery partitions.
*   Robust file copying using `robocopy.exe`.
*   Detailed logging with color-coded messages for different event levels (INFO, WARN, ERROR, SUCCESS, ACTION).
*   Multiple verification steps for partition identification and WinRE status.
*   User interaction for critical manual steps (like C: drive expansion or confirming partition settings if automated checks are inconclusive).

## Prerequisites

*   **PowerShell Version 5.1 or higher.**
*   **Administrator Privileges:** The script *must* be run as an Administrator. It includes a check and will exit if not run with elevated rights.
*   **Windows OS:** Designed for Windows client operating systems that use WinRE (e.g., Windows 10, Windows 11).
*   **WinRE on OS Disk:** The script is primarily designed for scenarios where the WinRE partition is (or will be) on the same physical disk as the operating system (C: drive).

## Parameters

*   **`-Mode`** (string):
    *   Specifies the operational mode.
    *   Accepted values:
        *   `Full` (Default): Performs the full backup, delete, C: drive expansion prompt, recreate, restore, and re-enable process.
        *   `RestoreOnly`: Only creates a new partition in existing unallocated space, restores from a backup, and enables WinRE.
    *   This parameter is optional and defaults to "Full".

*   **`-WinREBackupPathFullMode`** (string):
    *   **This parameter is NOT user-specified.**
    *   It's an internal parameter that defines the default backup path when `-Mode Full` is used.
    *   The path is dynamically generated in the script's root directory: `"$PSScriptRoot\WinRE_Backup_$(Get-Date -Format 'yyyyMMdd-HHmmss')"`

*   **`-WinREBackupPathRestoreMode`** (string):
    *   **Mandatory if `-Mode` is `RestoreOnly`.**
    *   Specifies the full path to the folder containing the WinRE backup that you want to restore. This folder should contain the `Recovery\WindowsRE` structure with `winre.wim` inside.
    *   Example: `C:\Backups\MyWinRE_Backup`

## Usage Examples

**Important:** Always back up important data before running scripts that modify disk partitions.

1.  **Full Mode (Backup, Delete, Recreate, Restore):**
    *   Save the script as `RelRel-WinRE.ps1`.
    *   Open PowerShell as an Administrator.
    *   Navigate to the directory where you saved the script.
    *   Run: `.\RelRel-WinRE.ps1`
    *   Or explicitly: `.\Rel-WinRE.ps1 -Mode Full`
    *   A backup folder (e.g., `WinRE_Backup_YYYYMMDD-HHMMSS`) will be created in the same directory as the script.
    *   **Follow the on-screen prompts carefully, especially when asked to expand the C: drive and leave unallocated space.**

2.  **RestoreOnly Mode (Restore to existing unallocated space):**
    *   Ensure you have unallocated space at the end of your OS disk.
    *   Ensure you have a valid WinRE backup (e.g., created by this script in "Full" mode, or a manually prepared folder containing the `Recovery\WindowsRE` structure).
    *   Open PowerShell as an Administrator.
    *   Navigate to the directory where you saved the script.
    *   Run (replace the path with your actual backup path):
        `.\Rel-WinRE.ps1 -Mode RestoreOnly -WinREBackupPathRestoreMode "C:\Path\To\Your\WinRE_Backup_Folder"`
    *   The script will prompt for the size of the unallocated space you've prepared.

## Script Workflow (Simplified)

**Mode: Full**
1.  Check Admin privileges.
2.  Identify OS Disk.
3.  Get current WinRE info (must be enabled and on OS disk).
4.  Backup current WinRE partition contents to `$PSScriptRoot\WinRE_Backup_Timestamp`.
5.  Disable WinRE (`reagentc /disable`).
6.  Delete old recovery partition (`diskpart`).
7.  **PROMPT USER:** Manually expand C: drive using Disk Management, leaving specified unallocated space at the end of the disk.
8.  Create new primary partition in the unallocated space, format NTFS, label "Recovery" (`diskpart`).
9.  Restore WinRE files from backup to the new partition (`robocopy`).
10. Set new partition ID (GPT/MBR specific) and attributes (`diskpart`). Includes verification with `Get-Partition`, `diskpart detail partition` fallback, and user confirmation if needed.
11. Configure WinRE on the new partition (`reagentc /setreimage /path ...` and `reagentc /enable`).
12. Verify final WinRE status.

**Mode: RestoreOnly**
1.  Check Admin privileges.
2.  Identify OS Disk.
3.  **PROMPT USER:** For backup path (`-WinREBackupPathRestoreMode`) and size of pre-existing unallocated space.
4.  Create new primary partition in the unallocated space, format NTFS, label "Recovery" (`diskpart`).
5.  Restore WinRE files from specified backup path to the new partition (`robocopy`).
6.  Set new partition ID (GPT/MBR specific) and attributes (`diskpart`). Includes verification steps.
7.  Configure WinRE on the new partition (`reagentc /setreimage /path ...` and `reagentc /enable`).
8.  Verify final WinRE status.

## Configuration Variables (Internal)

These are defined at the top of the script:

*   `$global:WinREFolderName = "Recovery\WindowsRE"`: The standard path to WinRE files within its partition.
*   `$global:NewRecoveryPartitionLabel = "Recovery"`: The label assigned to the newly created recovery partition.
*   `$global:MinRecoveryPartitionSpaceMB = 300`: Minimum recommended size (in MB) for the new recovery partition. The script will use the original partition's size if larger, or this minimum.

## Logging

*   The script provides real-time, color-coded logs to the console.
*   Robocopy operations generate log files in the user's temporary directory (`$env:TEMP`), which are displayed upon success/failure and then typically removed.
*   Diskpart operations are also logged, including the commands being executed.

## Important Notes and Warnings

*   **DISK MODIFICATION IS RISKY:** This script performs disk partition modifications. While it includes several checks and uses standard Windows tools, there is always an inherent risk of data loss if things go wrong or if the script is used incorrectly. **ALWAYS BACK UP YOUR SYSTEM AND IMPORTANT DATA BEFORE RUNNING THIS SCRIPT.**
*   **Administrator Privileges Required:** The script will not run without them.
*   **User Prompts:** Pay close attention to any prompts from the script, especially the manual step for C: drive expansion in "Full" mode and any user confirmation prompts for partition settings.
*   **Target System:** This script is designed for typical Windows client installations. Its behavior on highly customized systems or server environments with complex disk layouts may vary.
*   **Diskpart Output Parsing:** The secondary verification for GPT partition IDs relies on parsing the output of `diskpart.exe`. This parsing assumes English language output from `diskpart`.
*   **Error Handling:** The script attempts to handle common errors, but unforeseen issues can always occur. If the script aborts, check the logs and potentially Disk Management (`diskmgmt.msc`) and `reagentc /info` to understand the system's state.

## Troubleshooting

*   **"Administrator privileges required"**: Re-run PowerShell as Administrator.
*   **"Could not find OS partition (C:)"**: Ensure your C: drive is standard and accessible.
*   **"Cannot proceed in 'Full' mode without an active WinRE"**: Ensure WinRE is currently enabled and on the OS disk if you're using "Full" mode. Check `reagentc /info`.
*   **Partition identification errors**: The script logs detailed information about partitions. If it fails to find a newly created partition, check Disk Management. There might be slight discrepancies in reported size or type immediately after creation.
*   **Robocopy errors**: Check the Robocopy log content displayed by the script. This usually indicates file access issues or problems with source/destination paths.
*   **`reagentc` errors**: The script will display output from `reagentc /info` if `reagentc` commands fail. This often points to issues with the `winre.wim` file, its path, or the target partition's configuration (ID, attributes).
*   **Backup folder hidden**: The script now attempts to use `attrib.exe` to remove System and Hidden attributes from the backup folder created in "Full" mode.

## Disclaimer

This script is provided "as-is" without any warranties. Use it at your own risk. The author is not responsible for any data loss or system damage that may occur from its use. Always understand what a script does before running it, especially one that modifies disk partitions.