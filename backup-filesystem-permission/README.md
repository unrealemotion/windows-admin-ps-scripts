# Backup-FileSystemPermissions PowerShell Script

## Overview

This PowerShell script (`Backup-FileSystemPermissions.ps1`) is designed to collect and back up Access Control Lists (ACLs) for specified file system paths. It meticulously captures comprehensive security information including Owner, Group, Discretionary Access Control List (DACL), and System Access Control List (SACL).

This is particularly useful for creating snapshots of security configurations for auditing, migration, or disaster recovery purposes, allowing for potential restoration of permissions to a known state. The script is built for resilience, logging errors for individual item failures without halting the entire backup process, and produces multiple output formats for comprehensive backup and easy review.

## Features

*   **Collects Comprehensive ACLs:** Gathers full security descriptors (Owner, Group, DACL, SACL) for each specified item.
*   **Accepts Flexible Input:** Processes one or more file or folder paths provided as arguments.
*   **Supports Recursive Mode:** Optionally collects ACLs for all child items (files and folders) within specified directory paths.
*   **Creates Timestamped Backups:** Saves outputs in a timestamped subfolder (e.g., `Backup_YYYYMMDD_HHMMSS`) to prevent overwriting previous backups and maintain a history.
*   **Generates Multiple Output Formats:**
    *   **CLIXML (`FullPermissionsBackup.clixml`):** Stores full `FileSystemSecurity` objects, ideal for restoration.
    *   **CSV (`DACL_Report.csv`):** Provides a human-readable report of DACL entries.
    *   **Text Log (`ProcessingLog.txt`):** Records detailed script execution, including errors and summaries.
*   **Handles Errors Gracefully:** Manages issues like "Access Denied" or "Path Not Found" for individual items by logging them and continuing with other items.
*   **Provides User Feedback:**
    *   Supports `-Verbose` output for step-by-step console progress.
    *   Displays a progress bar for lengthy operations.
*   **Allows Custom Output Location:** Enables specification of a custom base directory for backup outputs.

## Prerequisites

1.  **Windows Operating System:** The script relies on PowerShell features and ACL concepts specific to Windows.
2.  **PowerShell:**
    *   Recommended: PowerShell 5.0 or newer (due to `[System.Collections.ArrayList]::new()` syntax and other modern constructs).
3.  **Administrator Privileges:**
    *   **Run as Administrator:** Generally recommended for accessing all system files/folders and essential for SACL retrieval.
    *   **"Manage auditing and security log" (SeSecurityPrivilege):** Required to read SACLs (audit rules). Without this privilege, SACLs will not be backed up, and errors may occur when attempting to access them.
    *   **"Backup files and directories" (SeBackupPrivilege):** May be required to access certain files or folders that the user running the script wouldn't normally have direct read access to, allowing the script to bypass standard DACL checks for backup purposes.

## Usage

11.  **Open PowerShell as Administrator:**
    *   Search for "PowerShell" in the Start Menu.
    *   Right-click on "Windows PowerShell" (or "PowerShell 7+").
    *   Select "Run as administrator" (crucial for accessing all ACLs, especially SACLs).
2.  **Navigate to Script Directory:**
    ```powershell
    cd "C:\Path\To\Your\Scripts"
    ```
3.  **Run the Script:**
    Execute the script by providing the mandatory `Path` parameter and any optional parameters.

    **Example:**
    ```powershell
    .\Backup-FileSystemPermissions.ps1 -Path "C:\Data\ProjectFolder" -Recursive -Verbose
    ```

### Command-Line Parameters

*   `-Path <String[]>`: (Mandatory)
    Specifies one or more file or folder paths for which to back up ACLs.
    Example: `-Path "C:\Folder1", "D:\Files\report.docx"`

*   `-Recursive <SwitchParameter>`: (Optional)
    If present, the script will collect ACLs for all child items (files and folders) within the specified paths. Defaults to `$false` if not specified.
    Example: `-Recursive`

*   `-OutputDirectory <String>`: (Optional)
    Specifies the base directory where the timestamped backup subfolder will be created.
    Defaults to a subfolder named `PermissionBackups` in the script's current execution directory (e.g., `.\PermissionBackups`).
    Example: `-OutputDirectory "E:\Backups\ACL_Snapshots"`

*   `-Verbose <SwitchParameter>`: (Optional)
    Common parameter that enables detailed console output of the script's operations.

*   `-WhatIf <SwitchParameter>`: (Optional)
    Common parameter that shows what the script *would* do (e.g., paths it would process, directories it would create) without actually performing the backup operations. Note: Data collection (Get-Acl) will still occur.

*   `-Confirm <SwitchParameter>`: (Optional)
    Common parameter that prompts for confirmation before executing commands that make changes (though this script primarily reads data, it does create output files/directories).

## Output Files

All output files are placed within a timestamped subfolder (e.g., `Backup_YYYYMMDD_HHMMSS`) inside the specified (or default) `OutputDirectory`.
Example location: `C:\Scripts\PermissionBackups\Backup_20231027_100000\`

1.  **`FullPermissionsBackup.clixml`**
    *   **Format:** XML (PowerShell CLIXML)
    *   **Content:** An array of PowerShell custom objects. Each object contains:
        *   `Path`: The full path to the file/folder.
        *   `AclObject`: The complete `System.Security.AccessControl.FileSystemSecurity` object (includes Owner, Group, DACL, SACL).
        *   `Sddl`: The Security Descriptor Definition Language (SDDL) string for the item.
        *   `RetrievedAt`: Timestamp of when the ACL was retrieved.
    *   **Purpose:** This is the primary backup file. It can be imported back into PowerShell (`Import-Clixml`) and used with `Set-Acl` to restore permissions.

2.  **`DACL_Report.csv`**
    *   **Format:** Comma Separated Values (CSV)
    *   **Content:** A table with detailed information for each Access Control Entry (ACE) in the Discretionary Access Control List (DACL) of successfully processed items. Columns include:
        *   `FolderPath`
        *   `IdentityReference` (User/Group)
        *   `FileSystemRights`
        *   `AccessControlType` (Allow/Deny)
        *   `IsInherited`
        *   `InheritanceFlags`
        *   `PropagationFlags`
    *   **Purpose:** Provides a human-readable overview of explicit permissions (DACLs) for auditing, documentation, or quick review.

3.  **`ProcessingLog.txt`**
    *   **Format:** Plain Text
    *   **Content:**
        *   Script start time, end time, and parameters used.
        *   A list (hierarchical if `-Recursive`) of all items targeted for processing:
            *   Full path of the item.
            *   Status: "SUCCESS" or "FAILURE".
            *   If "FAILURE", includes the specific error message encountered for that item.
        *   Summary: Total items scanned, number of successes, number of failures.
    *   **Purpose:** Detailed logging for troubleshooting and auditing the backup process itself.

## Example Usage Scenarios

1.  **Backup ACLs for a single folder and all its contents, with verbose output:**
    ```powershell
    .\Backup-FileSystemPermissions.ps1 -Path "E:\Shared\ImportantDocs" -Recursive -Verbose
    ```

2.  **Backup ACLs for multiple specific files and folders, output to a custom directory:**
    ```powershell
    .\Backup-FileSystemPermissions.ps1 -Path "C:\Data\File1.txt", "C:\Data\SensitiveFolder", "D:\Archive\OldReport.docx" -OutputDirectory "F:\SecurityBackups\ACLs"
    ```

3.  **Backup ACLs for a top-level folder only (not its children):**
    ```powershell
    .\Backup-FileSystemPermissions.ps1 -Path "C:\Program Files\MyApp"
    ```

4.  **Perform a dry run to see what would be processed without creating backup files (useful for path validation):**
    ```powershell
    .\Backup-FileSystemPermissions.ps1 -Path "C:\Very\Large\Share" -Recursive -WhatIf -Verbose
    ```
    *(Note: `-WhatIf` here primarily affects file/directory creation for output. ACLs will still be read.)*

## Important Considerations

*   **BACKUP YOUR DATA:** While this script performs backups of ACLs, always ensure you have full data backups as part of your overall disaster recovery strategy. This script does not back up file/folder *content*.
*   **Performance:** For very large directory structures (hundreds of thousands or millions of items), especially with the `-Recursive` switch, the script may take a significant amount of time to complete. The `Get-Acl` cmdlet can be I/O intensive.
*   **SACL Access:** Retrieving SACLs requires the "Manage auditing and security log" (SeSecurityPrivilege). If the script is run without this privilege, SACLs will not be backed up, and errors might be logged for attempts to read them.
*   **Path Length Limitations:** Extremely long file paths (over 260 characters) might cause issues with `Get-Acl` or other file system operations if the system/PowerShell version is not configured to handle them (e.g., via registry settings for long path support in Windows 10/Server 2016+).
*   **Restoration Complexity:** Restoring permissions, especially Owner and SACLs, can be complex and may require specific privileges beyond standard administrative rights (e.g., Take Ownership privilege).

## Error Handling

*   The script uses `try-catch` blocks to handle errors on a per-item basis. If an error occurs while processing a specific file or folder (e.g., "Access Denied," "Path Not Found"), it logs the error to `ProcessingLog.txt` and `Verbose` stream (if enabled) and continues to the next item.
*   Critical errors that prevent the script from initializing (e.g., invalid `OutputDirectory` path where it cannot create subfolders) may halt the script.
*   The `ProcessingLog.txt` provides a summary of successes and failures, which is crucial for identifying any items whose ACLs could not be backed up.

## Troubleshooting

*   **"Access Denied" Errors when reading ACLs:**
    *   Ensure PowerShell is run **as Administrator**.
    *   Verify the account running the script has at least Read permissions on the target files/folders.
    *   For SACLs, ensure the account has the "Manage auditing and security log" (SeSecurityPrivilege). This can be configured via Local Security Policy (`secpol.msc`) -> Local Policies -> User Rights Assignment.
    *   The "Backup files and directories" (SeBackupPrivilege) can also help bypass standard DACL checks for backup purposes.
*   **"Path Not Found" Errors:**
    *   Double-check the paths provided to the `-Path` parameter for typos or if the item truly does not exist.
*   **Output Directory Creation Failure:**
    *   Ensure the path specified in `-OutputDirectory` is valid and the script has write permissions to create subdirectories there.
*   **Script syntax errors on older PowerShell versions (e.g., related to `::new()`):**
    *   The script is designed for PowerShell 5.0+. If using an older version (e.g., PSv3, PSv4), you may need to replace `[System.Collections.ArrayList]::new()` with `New-Object System.Collections.ArrayList` and similar constructs for generic lists.

## Disclaimer

This script is provided "as-is" without any warranty. Always test backup and, more importantly, any restore procedures in a non-production, isolated environment before relying on them for critical data or systems. The author is not responsible for any data loss, permission misconfiguration, or system issues that may arise from its use or misuse.
