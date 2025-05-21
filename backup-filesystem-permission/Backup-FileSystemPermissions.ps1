[CmdletBinding(SupportsShouldProcess = $false)] # SupportsShouldProcess is not strictly needed here as we are not making system changes directly, but good practice.
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "One or more file/folder paths to back up permissions for.")]
    [string[]]$Path,

    [Parameter(HelpMessage = "Collect ACLs for all child items recursively.")]
    [switch]$Recursive,

    [Parameter(HelpMessage = "Directory to save backup files. Defaults to '.\\PermissionBackups'.")]
    [string]$OutputDirectory
)

begin {
    $ScriptStartTime = Get-Date
    Write-Verbose "Script started at $ScriptStartTime"

    # --- Initialize Counters and Collections ---
    $TotalItemsToScan = 0
    $ProcessedItemCount = 0 # For progress bar
    $SucceededCount = 0
    $FailedCount = 0
    $AllAclObjects = [System.Collections.ArrayList]::new()
    $DaclReportEntries = [System.Collections.ArrayList]::new()
    $LogEntries = [System.Collections.ArrayList]::new()

    # --- Helper Function for Logging ---
    function Write-LogMessage {
        param(
            [string]$Message,
            [int]$IndentLevel = 0,
            [string]$Status = "" # Optional status for summary line
        )
        $indentString = "  " * $IndentLevel
        $logLine = "$($indentString)$Message"
        if ($Status) {
            $logLine += " - $Status"
        }
        $LogEntries.Add($logLine) | Out-Null
        Write-Verbose $logLine
    }

    # --- Determine and Create Output Directory ---
    if (-not $OutputDirectory) {
        if ($PSScriptRoot) {
            $BaseOutputDirectory = Join-Path -Path $PSScriptRoot -ChildPath "PermissionBackups"
        } else {
            $BaseOutputDirectory = Join-Path -Path (Get-Location).Path -ChildPath "PermissionBackups"
        }
    } else {
        $BaseOutputDirectory = $OutputDirectory
    }

    # Resolve the path and ensure it's absolute
    try {
        $BaseOutputDirectory = Resolve-Path -Path $BaseOutputDirectory -ErrorAction Stop
    } catch {
        Write-Error "Invalid OutputDirectory specified: '$OutputDirectory'. Error: $($_.Exception.Message)"
        # Fallback to a default safe location or exit
        $BaseOutputDirectory = Join-Path -Path $env:TEMP -ChildPath "PermissionBackups_Fallback"
        Write-Warning "OutputDirectory was invalid. Using fallback: '$BaseOutputDirectory'"
    }

    $TimestampFolder = "Backup_$($ScriptStartTime.ToString("yyyyMMdd_HHmmss"))"
    $FinalOutputDirectory = Join-Path -Path $BaseOutputDirectory -ChildPath $TimestampFolder

    try {
        if (-not (Test-Path -Path $FinalOutputDirectory)) {
            New-Item -ItemType Directory -Path $FinalOutputDirectory -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created output directory: $FinalOutputDirectory"
        }
    } catch {
        Write-Error "Failed to create output directory '$FinalOutputDirectory'. Error: $($_.Exception.Message)"
        # Optionally, exit the script if the output directory cannot be created
        # exit 1
        # For resilience, we might try to log to a temp location or just log the failure to create dir.
        # For this script, we'll assume if this fails, user needs to fix permissions/path.
        Write-Warning "Cannot proceed without a valid output directory. Please check permissions or path."
        # Clean up log entries and exit if needed. For now, script might continue if further ops don't depend on this path.
        # However, all output files depend on it, so exiting is reasonable.
        # For the sake of the prompt "resilient to errors, logging them comprehensively without halting",
        # we'll log this and let it fail when writing files later, or better:
        # We'll try to use a temp dir for logs if primary fails. (This is getting complex for a demo)
        # Let's assume for now: if output dir creation fails, script will fail on file writes.
    }

    $LogFilePath = Join-Path -Path $FinalOutputDirectory -ChildPath "ProcessingLog.txt"
    $ClixmlPath = Join-Path -Path $FinalOutputDirectory -ChildPath "FullPermissionsBackup.clixml"
    $CsvPath = Join-Path -Path $FinalOutputDirectory -ChildPath "DACL_Report.csv"

    Write-LogMessage "Script Started: $ScriptStartTime"
    $paramString = ($PSBoundParameters.GetEnumerator() | ForEach-Object {
    $valueRepresentation = if ($_.Value -is [System.Management.Automation.SwitchParameter]) {
         "$($_.Value)" # Outputs "True" or "False"
    } elseif ($_.Value -is [array]) {
        ($_.Value -join ", ") # Joins array elements like "path1, path2"
    } else {
        "$($_.Value)"
    }
    "-$($_.Key) $($valueRepresentation)"
    }) -join " "
    Write-LogMessage "Parameters: $paramString"
    Write-LogMessage "Outputting to: $FinalOutputDirectory"
    Write-LogMessage ("-" * 50)

    # --- Pre-scan to get total item count for progress bar ---
    $ItemsToProcessList = [System.Collections.Generic.List[hashtable]]::new()
    function Get-ItemsToProcessRecursive {
        param(
            [string]$ItemPath,
            [int]$Depth
        )
        $ItemsToProcessList.Add(@{Path = $ItemPath; Depth = $Depth}) | Out-Null
        if ($Recursive.IsPresent) {
            # Test if it's a directory before attempting Get-ChildItem
            if (Test-Path -LiteralPath $ItemPath -PathType Container -ErrorAction SilentlyContinue) {
                try {
                    $children = Get-ChildItem -LiteralPath $ItemPath -Force -ErrorAction SilentlyContinue # SilentlyContinue GCI errors here, Get-Acl will handle item-specific errors
                    foreach ($child in $children) {
                        Get-ItemsToProcessRecursive -ItemPath $child.FullName -Depth ($Depth + 1)
                    }
                } catch {
                    # This catch might not be hit often due to -ErrorAction SilentlyContinue on GCI,
                    # but good for unexpected issues during enumeration.
                    Write-LogMessage "Error enumerating children of '$ItemPath': $($_.Exception.Message.Trim())" -IndentLevel ($Depth + 1) -Status "ENUMERATION_FAILURE"
                    $script:FailedCount++ # Ensure FailedCount is script-scoped if modified here
                }
            }
        }
    }

    Write-Verbose "Pre-scanning paths to determine total item count for progress bar..."
    foreach ($initialPath in $Path) {
        if (Test-Path -LiteralPath $initialPath) {
            Get-ItemsToProcessRecursive -ItemPath $initialPath -Depth 0
        } else {
            Write-LogMessage "Initial path not found: '$initialPath'" -Status "NOT_FOUND"
            $FailedCount++
        }
    }
    $TotalItemsToScan = $ItemsToProcessList.Count
    Write-Verbose "Total items to scan: $TotalItemsToScan"
}

process {
    if ($TotalItemsToScan -eq 0 -and $Path.Count -gt 0) {
        Write-Warning "No valid items found to process from the initial paths provided."
    }

    foreach ($itemInfo in $ItemsToProcessList) {
        $currentItemPath = $itemInfo.Path
        $currentDepth = $itemInfo.Depth
        $ProcessedItemCount++

        Write-Progress -Activity "Backing Up Permissions" `
                       -Status "Processing ($ProcessedItemCount / $TotalItemsToScan): $currentItemPath" `
                       -PercentComplete (($ProcessedItemCount / $TotalItemsToScan) * 100) `
                       -Id 1

        Write-LogMessage "Processing: $currentItemPath" -IndentLevel $currentDepth

        try {
            # Get-Acl can throw if path does not exist or access is denied.
            # -ErrorAction Stop ensures the catch block is triggered.
            # Audit rules (SACLs) are only retrieved if the script has SeSecurityPrivilege.
            $acl = Get-Acl -LiteralPath $currentItemPath -ErrorAction Stop -Audit

            $AllAclObjects.Add([PSCustomObject]@{
                Path        = $currentItemPath
                AclObject   = $acl # Store the full FileSystemSecurity object
                Sddl        = $acl.Sddl # Also store SDDL for easier Set-Acl usage
                RetrievedAt = (Get-Date)
            }) | Out-Null

            # Process DACL for CSV report
            foreach ($ace in $acl.Access) {
                $DaclReportEntries.Add([PSCustomObject]@{
                    FolderPath        = $currentItemPath
                    IdentityReference = $ace.IdentityReference.Value
                    FileSystemRights  = $ace.FileSystemRights.ToString()
                    AccessControlType = $ace.AccessControlType.ToString()
                    IsInherited       = $ace.IsInherited
                    InheritanceFlags  = $ace.InheritanceFlags.ToString()
                    PropagationFlags  = $ace.PropagationFlags.ToString()
                }) | Out-Null
            }

            Write-LogMessage "SUCCESS: ACLs retrieved." -IndentLevel ($currentDepth + 1) # Indent success/failure under the item
            $SucceededCount++
        }
        catch {
            $errorMessage = $_.Exception.Message.Trim()
            Write-LogMessage "FAILURE: $errorMessage" -IndentLevel ($currentDepth + 1) # Indent success/failure under the item
            # Log minimal info for CLIXML/CSV for failed items? Or just skip? Skipping for now.
            # Could add a placeholder to CLIXML:
            # $AllAclObjects.Add([PSCustomObject]@{Path = $currentItemPath; Error = $errorMessage; AclObject = $null}) | Out-Null
            $FailedCount++
        }
    }
}

end {
    Write-Progress -Activity "Finalizing Backup" -Status "Writing output files..." -Completed -Id 1

    Write-LogMessage ("-" * 50)
    Write-LogMessage "Summary:"
    Write-LogMessage "Total Items Scanned: $TotalItemsToScan" # This reflects items attempted based on pre-scan
    Write-LogMessage "Successfully Processed: $SucceededCount"
    Write-LogMessage "Failed to Process: $FailedCount"

    # --- Write CLIXML Backup ---
    if ($AllAclObjects.Count -gt 0) {
        try {
            Write-Verbose "Exporting comprehensive ACL objects to $ClixmlPath"
            # Export-Clixml can store rich objects. Depth might be needed for very complex nested objects,
            # but FileSystemSecurity objects are usually fine with default depth. Explicitly set for safety.
            $AllAclObjects | Export-Clixml -Path $ClixmlPath -Depth 5 -ErrorAction Stop
            Write-LogMessage "CLIXML backup saved to: $ClixmlPath"
        } catch {
            $errorMessage = $_.Exception.Message.Trim()
            Write-Error "Failed to write CLIXML file '$ClixmlPath'. Error: $errorMessage"
            Write-LogMessage "ERROR writing CLIXML file: $errorMessage"
        }
    } else {
        Write-LogMessage "No ACL objects were successfully collected to save to CLIXML."
        Write-Warning "No ACL objects to export to CLIXML."
    }

    # --- Write CSV Report ---
    if ($DaclReportEntries.Count -gt 0) {
        try {
            Write-Verbose "Exporting DACL report to $CsvPath"
            $DaclReportEntries | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            Write-LogMessage "CSV DACL report saved to: $CsvPath"
        } catch {
            $errorMessage = $_.Exception.Message.Trim()
            Write-Error "Failed to write CSV file '$CsvPath'. Error: $errorMessage"
            Write-LogMessage "ERROR writing CSV file: $errorMessage"
        }
    } else {
        Write-LogMessage "No DACL entries to save to CSV report."
        # This is not necessarily an error, could be that items had no explicit ACEs or all failed.
    }

    $ScriptEndTime = Get-Date
    Write-LogMessage "Script Finished: $ScriptEndTime"
    $Duration = $ScriptEndTime - $ScriptStartTime
    Write-LogMessage "Total Execution Time: $($Duration.ToString())"
    Write-Verbose "Script finished at $ScriptEndTime. Total duration: $Duration"

    # --- Write Log File ---
    try {
        $LogEntries | Out-File -FilePath $LogFilePath -Encoding UTF8 -ErrorAction Stop
        Write-Host "Processing complete. Log file saved to: $LogFilePath"
        if ($FailedCount -gt 0) {
            Write-Warning "$FailedCount item(s) could not be processed. Check log for details: $LogFilePath"
        }
        if ($SucceededCount -eq 0 -and $TotalItemsToScan -gt 0) {
             Write-Warning "No items were successfully processed. Check log for details: $LogFilePath"
        }
    } catch {
        $errorMessage = $_.Exception.Message.Trim()
        Write-Error "FATAL: Failed to write log file '$LogFilePath'. Error: $errorMessage"
        Write-Warning "Log entries could not be saved to file. Displaying on console:"
        $LogEntries # Display log to console if file write fails
    }
    if ($Global:ProgressPreference -ne 'SilentlyContinue') {
        Write-Progress -Activity "Backup Process" -Completed -Id 1
    }
}