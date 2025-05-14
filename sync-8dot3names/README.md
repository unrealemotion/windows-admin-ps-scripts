# Sync-ShortNames PowerShell Script

## Overview

This PowerShell script (`Sync-ShortNames.ps1`) is designed to synchronize 8.3 short filenames (also known as MS-DOS names or SFNs) from a source directory structure to an identical destination directory structure.

This is particularly useful in scenarios where files and folders were copied (e.g., using `robocopy /mir /copyall` without 8.3 name generation enabled on the destination at the time of the copy), resulting in the destination items lacking these short names, while the source items possess them. The script ensures that the 8.3 short names on the destination match those on the source for every file and folder.

## Features

*   **Administrator Privilege Check:** Automatically checks if the script is run with Administrator privileges and attempts to self-elevate if not. `fsutil` requires elevation.
*   **8.3 Name Enablement:** Checks if 8.3 name creation is enabled on the destination volume. If not, it attempts to enable it (with user confirmation via `ShouldProcess`).
*   **Recursive Scan:** Traverses the entire source directory structure (including subdirectories and files) if used with `-ApplyToChildren` parameter.
*   **Short Name Collection:** Retrieves the 8.3 short name for each item in the source using the reliable `Scripting.FileSystemObject` COM object.
*   **Object Model Storage:** Stores the collected information (relative path, short name, item type) in an efficient in-memory list of custom PowerShell objects.
*   **Targeted Application:** Applies the collected short names to the corresponding items in the destination directory using the `fsutil file setshortname` command.
*   **Progress Indication:** Provides progress bars for both the collection and application phases.
*   **Verbose Logging:** Offers detailed operational logs when run with the `-Verbose` switch.
*   **Error Handling:** Includes `try-catch` blocks for robust error management and reports issues clearly.
*   **WhatIf Support:** Supports the `-WhatIf` common parameter to show what changes would be made without actually executing them.

## Prerequisites

1.  **Windows Operating System:** The script relies on `fsutil.exe` and `Scripting.FileSystemObject`, which are Windows-specific.
2.  **PowerShell:** PowerShell 5.1 or higher is recommended.
3.  **Administrator Privileges:** The script **must** be run as an Administrator to use `fsutil.exe` for querying and setting short names, and for potentially modifying volume-level 8.3 name settings.
4.  **Identical Source and Destination Structure:** The script **assumes** that the destination directory is an exact structural and long-name replica of the source directory (e.g., created by `robocopy /mir`). It does *not* copy files or create directories; it only applies short names to existing items.
5.  **Source Items Have 8.3 Names:** The source directory's files and folders must already have the desired 8.3 short names.
6.  **NTFS Filesystem:** The destination volume should be formatted with NTFS, which supports 8.3 short names.

## Usage

1.  **Save the Script:** Save the code as `Sync-ShortNames.ps1` in a convenient location.
2.  **Open PowerShell as Administrator:**
    *   Search for "PowerShell" in the Start Menu.
    *   Right-click on "Windows PowerShell" (or "PowerShell 7+").
    *   Select "Run as administrator".
3.  **Navigate to Script Directory:**
    ```powershell
    cd "C:\Path\To\Your\Scripts"
    ```
4.  **Run the Script:**
    Execute the script by providing the mandatory `SourcePath` and `DestinationPath` parameters.

    ```powershell
    .\Sync-ShortNames.ps1 -SourcePath "C:\Path\To\SourceFolder" -DestinationPath "D:\Path\To\DestinationFolder"
    ```

    **Example:**
    ```powershell
    .\Sync-ShortNames.ps1 -SourcePath "E:\OriginalDataWithShortNames" -DestinationPath "F:\BackupDataMissingShortNames"
    ```

### Command-Line Parameters

*   `-SourcePath <String>`: (Mandatory) The full path to the source directory. This directory must exist and contain items with 8.3 short names.
*   `-DestinationPath <String>`: (Mandatory) The full path to the destination directory. This directory must exist and have a structure identical to the source. 8.3 short names will be applied here.
*   `-ApplyToChildren`: (Optional) A switch parameter is $false by default and becomes $true if you include it when running the script (e.g., .\Sync-ShortNames.ps1 -SourcePath C:\S -DestinationPath D:\T -ApplyToChildren).
*   `-Verbose`: (Optional) Displays detailed information about the script's operations.
*   `-WhatIf`: (Optional) Shows what actions the script would take without actually making any changes. This is highly recommended for a dry run.
    ```powershell
    .\Sync-ShortNames.ps1 -SourcePath "C:\Source" -DestinationPath "D:\Destination" -WhatIf
    ```
*   `-Confirm`: (Optional) Prompts for confirmation before performing each operation that modifies the system (like enabling 8.3 names or setting a short name).

## Important Considerations

*   **BACKUP YOUR DATA:** Before running any script that modifies file system attributes, especially on a large scale, ensure you have a reliable backup of your destination data. While this script is designed to be safe, unforeseen issues or incorrect usage can occur.
*   **Performance:** For very large directory structures (hundreds of thousands or millions of items), the script might take a significant amount of time to complete both the collection and application phases.
*   **8.3 Name Generation on Destination Volume:** The script attempts to enable 8.3 name creation on the destination volume if it's disabled. This typically involves `fsutil 8dot3name set <volume>: 0`. A system reboot *may* be required for changes to 8.3 name generation settings to fully take effect for *newly created* files by the OS, but `fsutil file setshortname` should work immediately for existing files once the volume setting allows it.
*   **Existing Short Names on Destination:** If items on the destination already have 8.3 short names, this script will attempt to overwrite them with the corresponding short names from the source.
*   **Files/Folders Without Short Names:** If a file or folder in the source legitimately does not have an 8.3 short name (e.g., names that are already 8.3 compliant or certain system-generated names), it will be skipped, and no short name will be applied on the destination for that specific item.

## Error Handling

*   The script uses `try-catch` blocks to handle potential errors during its execution.
*   Errors from `fsutil.exe` (e.g., if a short name is invalid or already in use in a conflicting way) will be captured and reported.
*   Warnings will be issued for non-critical issues, such as a destination item not being found.

## Troubleshooting

*   **"Access Denied" or `fsutil` errors:** Ensure you are running the script with Administrator privileges.
*   **"Destination item ... does not exist":** Verify that your source and destination paths are correct and that the destination is an identical mirror of the source in terms of long filenames and directory structure.
*   **"Failed to enable 8.3 name creation...":**
    *   Ensure you are running as Administrator.
    *   The volume might be in a state where `fsutil` cannot change the setting directly, or a reboot might be pending for a previous change.
    *   The filesystem might not support 8.3 names (very rare for standard Windows installations on NTFS).
*   **Script Fails to Parse:** If you copy-pasted the script, ensure no characters were corrupted or misinterpreted.

## License

This script is provided as-is. Use at your own risk. Please test thoroughly in a non-production environment before applying to critical data.
