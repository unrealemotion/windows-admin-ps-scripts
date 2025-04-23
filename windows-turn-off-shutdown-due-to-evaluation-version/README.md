# Disable WLMS Service using PsExec

## 1. Purpose

This PowerShell script is designed to disable the "WLMS" (Windows Licensing Monitoring Service - *assumed*) service on a local machine. Because modifying critical services often requires elevated privileges beyond standard administrator rights, this script utilizes **PsExec** from the Sysinternals suite to execute commands as the `NT AUTHORITY\SYSTEM` account.

The script operates in two modes based on internet connectivity:

*   **With Internet Access:** Automatically downloads PsTools (containing PsExec) from the official Microsoft Sysinternals site, extracts PsExec, and uses it to disable the service.
*   **Without Internet Access:** Prompts the user to manually download PsExec and provide the full path to the executable file on the local machine.

After attempting to disable and stop the service, the script prompts the user whether to reboot the machine immediately.

## 2. Prerequisites

*   **Operating System:** Windows (Modern versions with PowerShell installed).
*   **Permissions:** The script **MUST** be run **as Administrator**. It includes a `#Requires -RunAsAdministrator` directive to enforce this.
*   **PsExec:** The script relies heavily on `PsExec.exe`.
    *   If the machine **has internet access**, the script will attempt to download it automatically. Ensure firewalls or security policies do not block downloads from `https://download.sysinternals.com`.
    *   If the machine **does not have internet access**, you must manually download `PsExec.exe` (available from [https://live.sysinternals.com/PsExec.exe](https://live.sysinternals.com/PsExec.exe) or as part of the PsTools suite) and transfer it to the target machine *before* running the script.
*   **Antivirus:** PsExec is sometimes flagged by antivirus software. You may need to create an exception for the downloaded file (`$env:TEMP\PSTools.zip`), the extraction location (`$env:TEMP\PSTools`), or the `PsExec.exe` file itself if issues occur during download, extraction, or execution.

## 3. Input Preparation

This script does not require a separate input file. All necessary information is gathered through interactive prompts during execution.

## 4. Running the Script

1.  **Save:** Save the script content to a file (e.g., `Disable-WLMS.ps1`).
2.  **Open PowerShell as Administrator:**
    *   Search for "PowerShell" in the Start Menu.
    *   Right-click "Windows PowerShell" and select "Run as administrator".
3.  **Navigate to the Script Directory (Optional but Recommended):**
    *   Use the `cd` command to change to the directory where you saved the script file.
    *   Example: `cd C:\Scripts`
4.  **Execute the Script:**
    *   Type `.\` followed by the script's filename and press Enter.
    *   Example: `.\Disable-WLMS.ps1`
5.  **Answer the Prompts:**
    *   **`Does this server have internet access? (y/n)`:**
        *   Enter `y` if the machine can reach the internet to download PsTools. The script will attempt the download and extraction.
        *   Enter `n` if the machine cannot reach the internet. You will be prompted for the path to PsExec next.
    *   **`Enter the full path to PsExec.exe on this machine...`:** (Only if you answered 'n' above)
        *   Provide the complete, correct path to the `PsExec.exe` file you manually placed on the machine.
        *   Example: `C:\Tools\PsExec.exe`
    *   **`Do you want to reboot the server now? (y/n)`:**
        *   Enter `y` to initiate an immediate reboot of the machine.
        *   Enter `n` to skip the reboot. A reboot might still be necessary for the service change to take full effect in all scenarios.
6.  **Observe Console Output:** The script will print messages indicating its progress:
    *   Downloading PsTools (if applicable).
    *   Extracting PsExec (if applicable).
    *   Attempting to disable the WLMS service using PsExec.
    *   Attempting to stop the WLMS service (if it was running).
    *   Indicating if a reboot is initiated or skipped.
    *   Reporting any errors encountered during the process.
    *   A final "Script completed." message.

## 5. Troubleshooting & Important Notes

*   **Run as Administrator:** Ensure you are running the PowerShell console with elevated (Administrator) privileges.
*   **PsExec Download/Extraction Failure:**
    *   Check internet connectivity and firewall rules if download fails.
    *   Check antivirus logs if extraction fails or `PsExec.exe` is missing after supposed extraction. The `PsTools.zip` or `PsExec.exe` might have been quarantined.
    *   Ensure sufficient disk space in the temporary directory (`$env:TEMP`).
*   **PsExec Path Errors (Manual Mode):** Double-check the path provided. Ensure it points directly to `PsExec.exe` and the file exists at that location. Check for typos.
*   **Service Modification Errors:** If `sc.exe` commands fail even via PsExec, it could indicate:
    *   The service name "WLMS" is incorrect on the target system.
    *   Unusual system configurations or security hardening that prevents even the SYSTEM account from modifying the service via `sc.exe`. Review the specific error message provided.
*   **Why PsExec is Used:** Standard commands like `Set-Service -StartupType Disabled` might fail for certain protected services, even when run as Administrator. PsExec allows running `sc.exe` in the `SYSTEM` security context, which typically has the necessary permissions.
*   **Disclaimer:** Disabling system services can have unintended consequences. Ensure you understand the purpose of the WLMS service and the implications of disabling it in your environment before running this script. **Use at your own risk.**
*   **Reboot:** While the script attempts to stop the service if running, a system reboot is often the most reliable way to ensure a disabled service does not start.