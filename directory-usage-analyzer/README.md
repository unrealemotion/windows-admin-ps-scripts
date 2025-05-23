# Analyze-DirectorySpace.ps1 PowerShell Script

## Overview

This PowerShell script (`Analyze-DirectorySpace.ps1`) is designed to perform a comprehensive analysis of disk space usage for a specified directory. It recursively scans the directory, collects detailed information about each file, and generates various summary reports. This helps users understand what is consuming disk space, identify large files or folders, and track file age or ownership patterns.

The script is particularly useful for diagnosing situations where a directory is unexpectedly filling up or for general disk space auditing.

## Features

*   **Recursive Directory Scan:** Scans the target directory and all its subdirectories.
*   **Detailed File Information Collection:** Gathers data including full path, name, extension, size, creation time, last write time, last access time, and file owner.
*   **Human-Readable File Sizes:** Displays file sizes in an easy-to-understand format (Bytes, KB, MB, GB, etc.).
*   **Progress Indication:** Shows a progress bar during the potentially lengthy file scanning phase.
*   **Summary Reports:** Generates multiple insightful summaries:
    *   **By File Extension Type:** Shows file count, total size, and percentage of total space per extension.
    *   **By File Creation Date:** Groups files by their creation date, showing count, total size, and percentage, sorted with the most recent dates first.
    *   **By File Last Write Date:** Groups files by their last modification date, showing count, total size, and percentage, sorted with the most recent dates first.
    *   **By File Owner:** Summarizes space usage by the reported file owner.
    *   **Top N Largest Files:** Lists the N largest files found (N is configurable).
    *   **Top-Level Folder Sizes:** Shows the total size and file count for each immediate subfolder and files directly within the scanned root.
*   **Overall Directory Summary:** Provides total files scanned, total size, total folders, and a count of items skipped due to access errors.
*   **Skipped Item Reporting:** Lists any files or folders that could not be accessed during the initial scan.
*   **Owner Retrieval Handling:** Attempts to get file owner information using `Get-Acl` and reports failures gracefully (e.g., "Access Denied").
*   **Console Output:** Displays all summaries directly in the PowerShell console.
*   **Optional File Report:** Can save the complete analysis report to a specified text file in UTF-8 encoding.
*   **Execution Time:** Reports the total time taken for the script to run.
*   **Input Validation:** Checks if the provided directory path is valid and accessible.

## Prerequisites

1.  **Windows Operating System:** The script utilizes Windows-specific cmdlets and features like `Get-ChildItem` and `Get-Acl`.
2.  **PowerShell:** PowerShell 5.1 or higher is recommended for best compatibility with all script features.
3.  **Read Permissions:** The account running the script needs read access to the `DirectoryPath` and its contents to gather file information. Retrieving file owner information via `Get-Acl` may require additional permissions on some files/folders, but the script will note failures.

## Usage

1.  **Save the Script:** Save the code as `Analyze-DirectorySpace.ps1` in a convenient location.
2.  **Open PowerShell:**
    *   Search for "PowerShell" in the Start Menu.
    *   Click on "Windows PowerShell" (or "PowerShell 7+").
    *   (Running as Administrator is not strictly required unless scanning highly restricted system directories, but it can help avoid `Get-Acl` permission issues.)
3.  **Navigate to Script Directory (Optional):** If the script is not in a directory listed in your PATH environment variable, navigate to its location:
    ```powershell
    cd "C:\Path\To\Your\Scripts"
    ```
4.  **Run the Script:**
    Execute the script by providing the mandatory `DirectoryPath` parameter.

    **Basic Usage:**
    ```powershell
    .\Analyze-DirectorySpace.ps1 -DirectoryPath "C:\Users\YourUser\Documents"
    ```

    **Example with Top N Files specified:**
    ```powershell
    .\Analyze-DirectorySpace.ps1 -DirectoryPath "D:\Projects" -ShowTopNFiles 20
    ```

    **Example with Report Saved to File:**
    (The report filename includes a timestamp to ensure uniqueness for repeated scans.)
    ```powershell
    .\Analyze-DirectorySpace.ps1 -DirectoryPath "C:\Users\YourUser\AppData\Local" -ReportPath "C:\Reports\"
    ```

### Command-Line Parameters

*   `-DirectoryPath <String>`
    *   **Mandatory.**
    *   The full path to the directory you want to analyze.
*   `-ShowTopNFiles <Int>`
    *   Optional. Defaults to `10`.
    *   The number of largest files to display in the "Top N Largest Files" report.
*   `-ReportPath <String>`
    *   Optional.
    *   If specified, the full path (e.g., `C:\Reports\`) where the complete analysis report will be saved as a text file. The report is saved in UTF-8 encoding. If the parent directory for the report does not exist, the script will attempt to create it.
*   `-Verbose`
    *   A common PowerShell parameter. While this script doesn't have extensive custom verbose messages beyond its standard output, using `-Verbose` can sometimes provide more detail from underlying cmdlets if errors occur.
*   `-WhatIf`
    *   A common PowerShell parameter. Since this script primarily reads data and doesn't make system changes (other than potentially creating a report directory), `-WhatIf` will have limited effect on its core analysis functions. It would show if `New-Item` (for report directory creation) would run.
*   `-Confirm`
    *   A common PowerShell parameter. Similar to `-WhatIf`, its impact is minimal as the script is non-destructive.

## Output Description

The script produces output in two main ways:

1.  **Console Output:**
    *   A progress bar during the initial file scan.
    *   Clearly titled sections for each summary (File Extension, Creation Date, Last Write Date, Owner, Top N Files, Top-Level Folders, Overall Summary).
    *   Data within summaries is typically presented in formatted tables for easy reading.
    *   A list of any items skipped due to access errors.
    *   The total script execution time.

2.  **File Report (if `-ReportPath` is used):**
    *   A text file containing a header with scan details (scanned directory, report date, duration, totals).
    *   All the summaries and information displayed in the console are written to this file, preserving the table formatting.
    *   This provides a persistent record of the analysis.

## Important Considerations

*   **Performance:** Scanning very large directories with hundreds of thousands or millions of files can take a significant amount of time and consume memory to store file data.
*   **Permissions:** The script's ability to gather complete information (especially file ownership) depends on the read permissions of the account running it. "Access Denied" or similar errors for owner retrieval will be noted.
*   **Long Paths:** While PowerShell generally handles long paths well, underlying components like `Get-Acl` might encounter `PathTooLongException` for extremely deep file paths. Such errors are caught and noted for owner retrieval.
*   **Memory Usage:** For directories with an extremely large number of files, the `$allFilesData` variable holding all file details can grow large in memory.
*   **System Files/Folders:** Scanning system-protected directories (e.g., `C:\Windows\System32` in its entirety) may result in many "Access Denied" errors for `Get-Acl` and potentially for `Get-ChildItem` on certain items, even when run as Administrator.

## Error Handling

*   **Initial Path Validation:** The script checks if the `-DirectoryPath` exists and is a directory.
*   **File/Folder Access Errors:** `Get-ChildItem` errors during the initial scan (e.g., due to permissions) are caught, and problematic paths are added to a "Skipped Items" list.
*   **Owner Retrieval Errors:** `Get-Acl` failures (e.g., access denied, path too long) are caught on a per-file basis. The owner field will indicate the type of error, and a count of these failures is reported.
*   **Report Saving Errors:** If the script fails to save the report to the specified `-ReportPath` (e.g., due to invalid path or permissions), an error message is displayed.

## Troubleshooting

*   **"Error: Directory '...' does not exist or is not accessible."**:
    *   Verify that the path provided to `-DirectoryPath` is correct and that you typed it accurately.
    *   Ensure the account running the script has at least read permissions for the specified directory.
*   **Slow Performance**:
    *   This is expected for directories containing a vast number of files or very large total size. Allow the script sufficient time to complete.
    *   Consider scanning smaller subdirectories if a full scan of a huge volume is too slow for your needs.
*   **"Access Denied" in Owner Summary or Skipped Items List**:
    *   The account running the script lacks the necessary permissions for those specific files or folders.
    *   If possible, run the script with an account that has broader read permissions (e.g., as an Administrator), especially if `Get-Acl` is failing.
    *   Understand that some system-protected files may remain inaccessible even to administrators.
*   **Report File Not Saved**:
    *   Check if the path provided to `-ReportPath` is valid.
    *   Ensure the script has write permissions to the directory where the report is being saved. The script attempts to create the parent directory if it doesn't exist, but this also requires permissions.
*   **Dates Shown as `[UNEXPECTED_TYPE: System.String VALUE: '...']`**:
    *   This was an issue in earlier versions when grouping files by date. The current version includes fixes to handle date parsing more robustly. If you see this, ensure you are using the latest version of the script.

## License

This script is provided as-is. Use at your own risk. It is recommended to test the script on non-critical directories first to understand its behavior and output. The author(s) are not responsible for any unintended consequences of using this script.