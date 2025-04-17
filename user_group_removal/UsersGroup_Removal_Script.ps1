#region Input Gathering and Validation
# --- New Input Mechanism ---
$inputFile = Read-Host "Enter the path to the csv file containing folder names"
$parentDir = Read-Host "Enter the path to the parent directory containing these folders"
$outputDir = Read-Host "Enter the path to the directory where the log file should be saved"

# Validate inputs
if (!(Test-Path -Path $inputFile -PathType Leaf)) {
    Write-Error "Input file not found: $inputFile"
    exit 1
}
if (!(Test-Path -Path $parentDir -PathType Container)) {
    Write-Error "Parent directory not found: $parentDir"
    exit 1
}
if (!(Test-Path -Path $outputDir -PathType Container)) {
    Write-Warning "Output directory not found: $outputDir. Attempting to create it."
    try {
        New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop | Out-Null
        Write-Host "Output directory created successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to create output directory '$outputDir': $($_.Exception.Message)"
        exit 1
    }
}

# Prepare log file path
$logFileName = "acl_changed_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$logFilePath = Join-Path -Path $outputDir -ChildPath $logFileName

# Initialize summary data array
$summaryData = @()

# Simple logging function to replace Write-Host
Function Log-Message ($Message, $Type = "INFO") {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp [$Type] $Message"

    # --- New Output Mechanism ---
    Add-Content -Path $logFilePath -Value $logEntry
}

Log-Message "Script started."
Log-Message "Input File: $inputFile"
Log-Message "Parent Directory: $parentDir"
Log-Message "Output Log File: $logFilePath"

# Read folder names from the input file
try {
    $folderNamesRaw = Get-Content -Path $inputFile -Raw -ErrorAction Stop
    # Split, trim whitespace, and remove empty entries
    $folderNames = $folderNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($folderNames.Count -eq 0) {
       Log-Message "Input file '$inputFile' is empty or contains no valid folder names after parsing." -Type WARN
       # Add summary entry for this situation if needed, though arguably no folders processed yet
       # $summaryData += [PSCustomObject]@{ FolderPath = 'N/A'; Status = 'Skipped'; Details = 'Input file empty or invalid.' }
       exit 0 # Exit gracefully
    }
     Log-Message "Found $($folderNames.Count) folder(s) to process: $($folderNames -join ', ')"
} catch {
    Log-Message "Fatal error reading or parsing input file '$inputFile': $($_.Exception.Message)" -Type ERROR
    # Add summary entry for this failure
    $summaryData += [PSCustomObject]@{ FolderPath = 'N/A'; Status = 'Fatal Error'; Details = "Failed to read input file: $($_.Exception.Message)" }
    # Append summary immediately on fatal error before exiting
    if ($summaryData.Count -gt 0) {
        Log-Message "--- Summary ---"
        $summaryTable = $summaryData | Format-Table -AutoSize | Out-String
        Add-Content -Path $logFilePath -Value $summaryTable
    }
    exit 1
}
#endregion Input Gathering and Validation

#region Core Processing Loop (Original Logic Wrapped)

# Process each folder specified in the input file
foreach ($folderName in $folderNames)
{
    # Construct the full path using the provided parent directory and the folder name from the file
    $path = Join-Path -Path $parentDir -ChildPath $folderName
    Log-Message "--- Processing folder: $path ---"

    # Initialize status variables for summary for this folder
    $currentStatus = "Unknown Error" # Default to error unless explicitly set otherwise
    $currentDetails = "An unexpected error occurred during processing."
    $inheritanceWasDisabled = $false
    $usersRemoved = $false
    $errorOccurred = $false
    $errorMessage = ""

    # ===============================================================
    # == BEGIN UNMODIFIED CORE LOGIC (with status tracking added) ==
    # ===============================================================

    if (!(Test-Path -Path $path -PathType Container)) {
        $errorOccurred = $true
        $errorMessage = "The directory '$path' specified in the input file does not exist or is not a directory."
        Log-Message "Error: $errorMessage" -Type ERROR
        $currentStatus = "Skipped"
        $currentDetails = $errorMessage
        $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
        continue # Skip to next folder
    }

    # Get the ACL of the directory
    $acl = $null # Ensure acl is null initially in case Get-Acl fails
    try {
        $acl = Get-Acl -Path $path -ErrorAction Stop
    } catch {
        $errorOccurred = $true
        $errorMessage = "Error getting ACL for '$path': $($_.Exception.Message)"
        Log-Message $errorMessage -Type ERROR
        $currentStatus = "Error"
        $currentDetails = "Failed to read ACL. Details: $($_.Exception.Message)"
        $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
        continue # Skip to next folder
    }


    # Check if inheritance is enabled
    if ($acl.AreAccessRulesProtected) {
        Log-Message "Inheritance is disabled already for '$path'." -Type WARN
        $inheritanceWasDisabled = $true # Mark that we started with inheritance off
        # Proceed directly to Users group removal logic
    } else {
        Log-Message "Inheritance is enabled for '$path'. Rebuilding ACL and disabling inheritance." -Type INFO
        # --- 1. Get all ACEs ---
        $originalAcl = $acl # Use the already retrieved ACL
        $owner = $originalAcl.Owner
        $group = $originalAcl.Group
        $accessRules = $originalAcl.Access

        # --- 2. Create a new ACL ---
        $newAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $newAcl.SetOwner([System.Security.Principal.NTAccount]$owner)
        $newAcl.SetGroup([System.Security.Principal.NTAccount]$group)

        # --- 3. Sort ACEs ---
        $denyRules = New-Object System.Collections.Generic.List[System.Security.AccessControl.FileSystemAccessRule]
        $allowRules = New-Object System.Collections.Generic.List[System.Security.AccessControl.FileSystemAccessRule]
        foreach ($rule in $accessRules) {
            if ($rule.AccessControlType -eq "Deny") { $denyRules.Add($rule) } else { $allowRules.Add($rule) }
        }

        # --- 4. Apply ACEs in order ---
        foreach ($rule in $denyRules) { $newAcl.AddAccessRule($rule) }
        foreach ($rule in $allowRules) { $newAcl.AddAccessRule($rule) }

        # --- 5. Apply new ACL and disable inheritance ---
        try {
            Set-Acl -Path $path -AclObject $newAcl -ErrorAction Stop
            Log-Message "Successfully applied rebuilt ACL (before disabling inheritance) for '$path'." -Type INFO

            # Get ACL again, disable inheritance, apply again
            $acl = Get-Acl -Path $path -ErrorAction Stop # Get ACL *after* rebuild
            $acl.SetAccessRuleProtection($true, $false) # $true = protect (disable inh.), $false = don't copy inherited rules (they are already explicit now)
            Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
            Log-Message "ACL rebuilt, reordered, and inheritance disabled for '$path'." -Type INFO
            # Successfully disabled inheritance
        } catch {
            $errorOccurred = $true
            $errorMessage = "Error applying rebuilt ACL or disabling inheritance for '$path': $($_.Exception.Message)"
            Log-Message $errorMessage -Type ERROR
            $currentStatus = "Error"
            $currentDetails = "Failed during ACL rebuild/inheritance disable. Details: $($_.Exception.Message)"
            $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
            continue # Skip Users removal if this failed
        }
    } # End of 'else' block (inheritance was enabled)


    # --- 6. Remove ACEs for "Users" group ---
    # This section runs if inheritance was already disabled OR if it was successfully disabled above.
    Log-Message "Attempting to remove 'Users' group ACEs for '$path'." -Type INFO

    $targetUsersSID = $null
    $targetUsersName = ""
    $computerName = [System.Environment]::MachineName
    $domainUsersSID = $null
    $localUsersSID = $null
    $domainOrComputerName = ""

    try {
        # Try Domain/Computer account first
        $domainOrComputerName = if ($env:USERDOMAIN -ne $computerName) { $env:USERDOMAIN } else { $computerName }
        $domainUsers = New-Object System.Security.Principal.NTAccount($domainOrComputerName, "Users")
        $domainUsersSID = $domainUsers.Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
        Log-Message "Could not resolve domain/computer account '$domainOrComputerName\Users'. Will proceed using local 'BUILTIN\Users'." -Type WARN
        $domainUsersSID = $null
    }

    try {
        # Get Local BUILTIN\Users
        $localUsers = New-Object System.Security.Principal.NTAccount("BUILTIN", "Users")
        $localUsersSID = $localUsers.Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
         $errorOccurred = $true
         $errorMessage = "Critical error: Could not translate the well-known SID for 'BUILTIN\Users'. Cannot remove Users group. Error: $($_.Exception.Message)"
         Log-Message $errorMessage -Type ERROR
         $currentStatus = "Error"
         $currentDetails = "Failed to find BUILTIN\\Users SID. Details: $($_.Exception.Message)"
         # Use $summaryData += ... here before continue
         $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
         continue
    }

    # Determine which SID to use
    if ($domainUsersSID -ne $null) {
        $targetUsersSID = $domainUsersSID
        $targetUsersName = "$domainOrComputerName\Users"
        Log-Message "Identified Domain/Computer 'Users' SID: $targetUsersSID ($targetUsersName)" -Type INFO
    } elseif ($localUsersSID -ne $null){
        $targetUsersSID = $localUsersSID
        $targetUsersName = "BUILTIN\Users"
        Log-Message "Using Local 'BUILTIN\Users' SID: $targetUsersSID ($targetUsersName)" -Type INFO
    } else {
         $errorOccurred = $true
         $errorMessage = "Error: Could not determine a valid SID for any 'Users' group after checking Domain/Local."
         Log-Message $errorMessage -Type ERROR
         $currentStatus = "Error"
         $currentDetails = "Failed to determine Users SID."
         $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
         continue
    }

    # Get the ACL *again* (after potential inheritance changes)
    try {
        $acl = Get-Acl -Path $path -ErrorAction Stop
    } catch {
        $errorOccurred = $true
        $errorMessage = "Error getting final ACL before 'Users' removal for '$path': $($_.Exception.Message)"
        Log-Message $errorMessage -Type ERROR
        $currentStatus = "Error"
        $currentDetails = "Failed read ACL before Users removal. Details: $($_.Exception.Message)"
        $summaryData += [PSCustomObject]@{ FolderPath = $path; Status = $currentStatus; Details = $currentDetails }
        continue
    }

    # Remove *all* access rules for the identified SID.
    Log-Message "Purging access rules for SID '$targetUsersSID' ($targetUsersName) from '$path'." -Type INFO
    try {
        $ruleCountBefore = ($acl.Access | Where-Object {$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $targetUsersSID }).Count
        if ($ruleCountBefore -eq 0) {
             Log-Message "No ACEs found for '$targetUsersName' ($targetUsersSID) on '$path'. Nothing to remove." -Type INFO
             $usersRemoved = $true # Technically successful as the goal state (no users) is achieved
        } else {
            $acl.PurgeAccessRules($targetUsersSID)
            Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
            Log-Message "Successfully removed $ruleCountBefore ACE(s) for '$targetUsersName' from '$path'." -Type INFO
            $usersRemoved = $true
        }
    } catch {
         $errorOccurred = $true
         $errorMessage = "Error purging or applying ACL after removing '$targetUsersName' for '$path': $($_.Exception.Message)"
         Log-Message $errorMessage -Type ERROR
         $currentStatus = "Error"
         $currentDetails = "Failed applying ACL after Users removal. Details: $($_.Exception.Message)"
         # Add to summary below
    }

    # ===============================================================
    # == END UNMODIFIED CORE LOGIC                                ==
    # ===============================================================

    # Determine final status for summary based on outcomes
    if (-not $errorOccurred) {
        if ($inheritanceWasDisabled) {
            $currentStatus = "Success"
            $currentDetails = "Inheritance was already disabled. Users group ACEs removed/verified absent."
        } else {
            $currentStatus = "Success"
            $currentDetails = "Inheritance disabled and ACL rebuilt. Users group ACEs removed/verified absent."
        }
    } elseif ($currentStatus -eq "Unknown Error") { # If an error occurred but wasn't caught by specific continues above
         $currentStatus = "Error"
         $currentDetails = "Failed during Users group removal stage. Last known error: $errorMessage"
    }
    # Else: $currentStatus and $currentDetails were already set by a 'continue' block or specific error catch

    # Add the final status for this folder to the summary data
    $summaryData += [PSCustomObject]@{
        FolderPath = $path
        Status     = $currentStatus
        Details    = $currentDetails
    }

} # End foreach folderName

#endregion Core Processing Loop

#region Final Summary Output
Log-Message "--- Summary ---"
if ($summaryData.Count -gt 0) {
    # Format the data as a table string
    # Adjust column widths as needed (-Property FolderPath, @{n='Status';w=10}, @{n='Details';w=60})
    $summaryTable = $summaryData | Format-Table -AutoSize -Wrap | Out-String 

    # Append the table to the log file
    Add-Content -Path $logFilePath -Value $summaryTable
    Log-Message "Summary table generated."
} else {
    Log-Message "No folders were processed, or no summary data was generated."
}

Log-Message "Script finished."
Write-Host "Processing complete. Log saved to: $logFilePath"
#endregion Final Summary Output