<#
.SYNOPSIS
Scans a specified directory recursively, reports folder ACLs in a two-column table
(Folder Name, ACL Summary) to a text file, highlighting folders with 'Users' group access,
and lists only the names of folders with the 'Users' group in their ACL
to a comma-separated CSV file.

.DESCRIPTION
This script prompts the user for a starting directory and an output directory.
It then iterates through all subfolders within the starting directory.
1. It creates a text report (FolderACL_Report.txt) in the output directory.
   This report is a table with two columns:
   - FolderName: The name of the folder. Folders with a 'Users' group in their
     ACL will have an asterisk (*) appended.
   - ACL_Summary: A concise, multi-line summary of the ACL entries
     (Identity, Rights, Type, Inheritance) for that folder.
   A legend explaining the asterisk is included at the top of the report.
2. It creates a CSV file (Folders_With_UsersGroup.csv) in the output directory,
   containing a single line with the names (not full paths) of folders that
   have any 'Users' group in their ACL, separated by commas.

.NOTES
Author: Asher Le
Date:   April 17, 2025
Requires: PowerShell 3.0 or later.
Run this script with sufficient permissions to read the target directories and their ACLs.
Consider running as Administrator if scanning system folders or folders with restricted access.
The text report table width adjusts automatically (-AutoSize), and text in the
ACL_Summary column will wrap (-Wrap).
#>

# --- Configuration ---
$ReportFileName = "FolderACL_Report.txt"
$CsvFileName = "Folders_With_UsersGroup.csv"
$HighlightMarker = " *" # Marker to add to folder names in the text report

# --- User Input ---

# Get the starting directory path
$StartDirectory = Read-Host "Please enter the full path to the directory you want to scan"
# Validate the start directory
if (-not (Test-Path -Path $StartDirectory -PathType Container)) {
    Write-Error "The specified start directory '$StartDirectory' does not exist or is not a directory. Exiting."
    Exit
}

# Get the output directory path
$OutputDirectory = Read-Host "Please enter the full path to the directory where the output files should be saved"
# Validate or create the output directory
if (-not (Test-Path -Path $OutputDirectory -PathType Container)) {
    Write-Warning "Output directory '$OutputDirectory' does not exist. Attempting to create it."
    try {
        New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Output directory '$OutputDirectory' created successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create output directory '$OutputDirectory'. Error: $($_.Exception.Message). Exiting."
        Exit
    }
}

# Define full output file paths
$ReportFilePath = Join-Path -Path $OutputDirectory -ChildPath $ReportFileName
$CsvFilePath = Join-Path -Path $OutputDirectory -ChildPath $CsvFileName

# --- Initialization ---

# Clear or create empty output files / Add Header and Legend for Text Report
Set-Content -Path $ReportFilePath -Value "Folder ACL Report - Generated on $(Get-Date)" -ErrorAction SilentlyContinue
Add-Content -Path $ReportFilePath -Value "Note: Folders marked with '$($HighlightMarker.Trim())' in the FolderName column have a 'Users' group in their ACL."
Add-Content -Path $ReportFilePath -Value "--------------------------------------------------" # Separator after header/legend
# Clear CSV
Set-Content -Path $CsvFilePath -Value "" -ErrorAction SilentlyContinue

# Array to hold data for the text report table
$ReportData = [System.Collections.Generic.List[PSCustomObject]]::new()
# List to store just the names of folders for the CSV
$FolderNamesWithUsersGroup = [System.Collections.Generic.List[string]]::new()
$TotalFolders = 0
$ProcessedFolders = 0

# --- Main Processing ---

Write-Host "Scanning folders under '$StartDirectory'..."

try {
    # Get all directories recursively
    $Folders = Get-ChildItem -Path $StartDirectory -Recurse -Directory -Force -ErrorAction SilentlyContinue

    $TotalFolders = $Folders.Count
    Write-Host "Found $TotalFolders folders to process."

    # Add the top-level Start Directory itself
    $Folders = @(Get-Item -Path $StartDirectory -Force) + $Folders

    # Iterate through each folder
    foreach ($Folder in $Folders) {
        $ProcessedFolders++
        $FolderPath = $Folder.FullName
        $FolderNameOnly = $Folder.Name # Get just the folder name for processing
        Write-Progress -Activity "Processing Folder ACLs" -Status "Processing folder $ProcessedFolders of $($TotalFolders + 1): $FolderPath" -PercentComplete (($ProcessedFolders / ($TotalFolders + 1)) * 100)

        $Acl = $null
        $AclError = $null
        $FolderHasUsersGroup = $false # Reset flag for each folder
        $AclSummaryString = ""
        $ReportFolderName = $FolderNameOnly # Start with the base name for the report

        try {
            # Get the ACL information for the folder
            $Acl = Get-Acl -Path $FolderPath -ErrorAction Stop

            # --- Format ACL Summary for Text Report & Check for Users Group ---
            $AclStrings = @() # Temporary array for current folder's ACL rule strings
            if ($Acl.Access.Count -gt 0) {
                foreach ($AccessRule in $Acl.Access) {
                    $Identity = $AccessRule.IdentityReference.Value
                    $Rights = $AccessRule.FileSystemRights
                    $Type = $AccessRule.AccessControlType
                    $Inheritance = if ($AccessRule.IsInherited) { "Inherited" } else { "Explicit" }

                    # Add a concise string representation for each rule
                    $AclStrings += "  $Identity : $Rights ($Type, $Inheritance)"

                    # --- Check for Users Group (only need to find it once per folder) ---
                    if (-not $FolderHasUsersGroup -and $Identity -like '*\Users') {
                        $FolderHasUsersGroup = $true
                        # No need to check identity again for this folder once found
                    }
                }
                 $AclSummaryString = $AclStrings -join [System.Environment]::NewLine
            }
            else {
                $AclSummaryString = "(No explicit access rules found)"
            }

            # --- Prepare data for the report collection ---
            # Add highlight marker to folder name if applicable
            if ($FolderHasUsersGroup) {
                 $ReportFolderName = $FolderNameOnly + $HighlightMarker
            }

            # Add data object for this folder to the report collection
            $ReportData.Add([PSCustomObject]@{
                FolderName  = $ReportFolderName # Use potentially modified name
                ACL_Summary = $AclSummaryString.Trim()
            })

            # --- Add ORIGINAL Folder Name to CSV List if Applicable ---
            if ($FolderHasUsersGroup) {
                # Add only the original folder name to the CSV list
                $FolderNamesWithUsersGroup.Add($FolderNameOnly)
            }

        }
        catch {
            # Handle errors getting ACL (e.g., Access Denied)
            $AclError = $_.Exception.Message
            Write-Warning "Could not retrieve ACL for folder '$FolderPath'. Error: $AclError"

             # Add error entry to the report collection (without highlight marker)
            $ReportData.Add([PSCustomObject]@{
                FolderName  = $FolderNameOnly # Use original name for errors
                ACL_Summary = "ERROR: Could not retrieve ACL - $AclError"
            })
        }
    } # End foreach folder

    Write-Progress -Activity "Processing Folder ACLs" -Completed

    # --- Generate Text Report File (Table Format) ---
    Write-Host "Generating text report table..."
    if ($ReportData.Count -gt 0) {
        # Format the collected data as a table and append to the report file
        $TableOutput = $ReportData | Format-Table FolderName, ACL_Summary -AutoSize -Wrap | Out-String -Width 4096 -Stream
        Add-Content -Path $ReportFilePath -Value $TableOutput
        Write-Host "Text report generated successfully: $ReportFilePath" -ForegroundColor Green
    } else {
        Add-Content -Path $ReportFilePath -Value "No folders found or processed."
         Write-Host "Text report generated, but no folder data was collected: $ReportFilePath" -ForegroundColor Yellow
    }


    # --- Generate CSV File (Comma-Separated Original Names) ---
    if ($FolderNamesWithUsersGroup.Count -gt 0) {
        Write-Host "Exporting list of folder names with 'Users' group access to CSV..."
        # Join the list of original names with a comma
        $CsvContent = $FolderNamesWithUsersGroup -join ','
        # Write the single line to the CSV file
        Set-Content -Path $CsvFilePath -Value $CsvContent -Encoding UTF8
        Write-Host "CSV file generated successfully: $CsvFilePath" -ForegroundColor Green
    }
    else {
        Write-Host "No folders found with the 'Users' group in their ACL. CSV file will be empty." -ForegroundColor Yellow
        # Ensure the file is empty if none were found
        Set-Content -Path $CsvFilePath -Value "" -Encoding UTF8
    }

}
catch {
    Write-Error "An unexpected error occurred during script execution: $($_.Exception.Message)"
}

Write-Host "Script finished."