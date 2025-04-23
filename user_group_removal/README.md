# User Guide: Folder ACL Inheritance & Users Group Removal Script

## 1. Purpose

This PowerShell script modifies the security settings (Access Control Lists - ACLs) of specific folders provided via an input file. For each target folder, the script performs the following actions:

*   **Disables Inheritance:** If ACL inheritance is enabled on the folder, the script disables it, converting inherited permissions into explicit permissions directly on the folder.
*   **Removes 'Users' Group:** It removes all permissions granted to the built-in 'Users' group. This targets the appropriate group, whether it's the local (`BUILTIN\Users`) or the domain/computer-specific one (`DOMAIN\Users` or `COMPUTERNAME\Users`).

The script processes *only* the folders listed in the input file and generates a detailed log file documenting its actions and a final summary.

## 2. Prerequisites

*   **Operating System:** Windows (Modern versions with PowerShell installed, which is standard).
*   **Permissions:** **Crucially**, you MUST run this script using an account that possesses **Full Control** permissions on all target folders. At a minimum, the account needs rights to **Modify Permissions** and potentially **Take Ownership**. Running PowerShell **as an Administrator** is highly recommended and often necessary.

## 3. Input Preparation

You need to create a simple plain text file (`.txt`) listing the target folders.

*   **Format:** Plain text (`.txt`).
*   **Content:**
    *   List the **exact names** of the folders you want to process, **separated by commas** (`,`).
    *   **Important:** Do **NOT** include the parent directory path in this file. Only list the folder names as they appear *within* their parent directory.
    *   Whitespace around the commas is acceptable (e.g., `FolderA, FolderB` is fine).
    *   Ensure there are no empty entries caused by extra commas (e.g., avoid `FolderA,,FolderB`).

*   **Example:**
    Imagine you have a parent directory `C:\Projects` containing folders: `Project Alpha`, `Shared Files`, and `Old Archives`. If you only want to modify `Project Alpha` and `Shared Files`, create a text file (e.g., `folders_to_process.txt`) with the following content:

    ```text
    Project Alpha,Shared Files
    ```

*   **Saving:** Save this input file in a location you can easily access when running the script (e.g., `C:\Scripts\input\folders_to_process.txt`).

## 4. Running the Script

1.  **Open PowerShell as Administrator:**
    *   Search for "PowerShell" in the Start Menu.
    *   Right-click "Windows PowerShell" and select "Run as administrator".

2.  **Navigate to the Script Directory (Optional but Recommended):**
    *   Use the `cd` command to change to the directory where you saved the script file (e.g., `UsersGroup_Removal_Script.ps1`).
    *   Example: `cd C:\Scripts`

3.  **Execute the Script:**
    *   Type `.\` followed by the script's filename and press Enter.
    *   Example: `.\UsersGroup_Removal_Script.ps1`

4.  **Answer the Prompts:** The script will require three pieces of information:
    *   **Input File Path:** Enter the *full path* to the `.txt` file you created in Step 3 (Input Preparation).
        *   Example: `C:\Scripts\input\folders_to_process.txt`
    *   **Parent Directory Path:** Enter the *full path* to the directory that *contains* the folders listed in your input file.
        *   Example: `C:\Projects`
    *   **Log File Directory Path:** Enter the *full path* to an *existing directory* where you want the output log file to be saved. The script will attempt to create the directory if it doesn't exist, but it's best practice to ensure it exists beforehand.
        *   Example: `C:\Scripts\logs`

The script will then begin processing the specified folders and log its progress.

## 5. Understanding the Output (Log File)

*   **Location:** The log file is created in the output directory you specified during the prompts.
*   **Filename:** The filename incorporates the date and time of the script execution, ensuring each log is unique (e.g., `UsersGroup_Removal_log_20231027_153000.txt`).
*   **Content:**
    *   **Timestamped Logs:** Detailed, timestamped entries show the script's actions for each folder (checking existence, getting ACLs, disabling inheritance, removing the Users group). Messages are prefixed with `[INFO]`, `[WARN]`, or `[ERROR]`.
    *   **Summary Table:** At the end of the log, a table summarizes the results for every folder the script attempted to process.

*   **Summary Table Columns:**
    *   `FolderPath`: The full path to the folder processed.
    *   `Status`: The overall outcome for the folder:
        *   `Success`: Inheritance was disabled (if applicable), and the Users group was successfully removed (or confirmed absent).
        *   `Skipped`: The folder was skipped (e.g., it didn't exist or wasn't a directory).
        *   `Error`: An error occurred that prevented successful processing.
    *   `Details`: Provides more specific context for the status, especially for warnings or errors (e.g., "Inheritance was already disabled", "Failed to read ACL", "Users group ACEs removed/verified absent").

*   **Example Log File Snippet (Focus on Summary):**
    ```log
    ... (detailed logs above) ...
    2023-10-27 15:31:15 [INFO]   Summary ---

    FolderPath                     Status    Details
    ----------                     ------    -------
    C:\Projects\Project Alpha      Success   Inheritance disabled and ACL rebuilt. Users group ACEs removed/verified absent.
    C:\Projects\Shared Files       Success   Inheritance was already disabled. Users group ACEs removed/verified absent.
    C:\Projects\NonExistent        Skipped   The directory 'C:\Projects\NonExistent' specified in the input file does not exist or is not a directory.
    C:\Projects\LockedFolder       Error     Failed read ACL before Users removal. Details: Attempted to perform an unauthorized operation.

    2023-10-27 15:31:15 [INFO] Summary table generated.
    2023-10-27 15:31:15 [INFO] Script finished.
    ```

## 6. Troubleshooting & Important Notes

*   **Permissions Errors (`Unauthorized operation`):** Ensure you are running PowerShell as an Administrator *and* that the user account running the script has the necessary Full Control (or Modify Permissions/Take Ownership) rights on the target folders.
*   **Folder Not Found Errors:**
    *   Double-check the **Parent Directory** path provided during the prompts.
    *   Verify that the folder names listed in your **input `.txt` file** exactly match the actual folder names within the parent directory (case sensitivity might matter depending on the underlying system).
    *   Ensure the input file is plain text and correctly comma-separated without errors.
*   **Input File Issues:** Confirm the path provided for the input file is correct. Make sure the file is not empty or corrupted.
*   **Backup Recommended:** **Modifying ACLs is a significant operation. It is STRONGLY recommended to back up critical data or thoroughly test the script in a non-production environment before running it on important folders.**
*   **Users Group Identification:** The script attempts to identify the correct 'Users' group by checking for a domain/computer-specific version first, then falling back to the local `BUILTIN\Users`. In complex or unusual configurations (specific workgroups, unique AD setups), the script might struggle to resolve the correct Security Identifier (SID). Check the log file for any warnings related to SID resolution if you suspect issues.