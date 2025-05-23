[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DirectoryPath,

    [Parameter(Mandatory = $false)]
    [int]$ShowTopNFiles = 10,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath
)

# Script Start Time
$scriptStartTime = Get-Date

# Clear any previous gciErrors variable from the session to avoid accumulation
Remove-Variable gciErrors -ErrorAction SilentlyContinue

# --- Helper Function: Format File Size ---
function Format-FileSize {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    if ($Bytes -eq $null -or $Bytes -lt 0) { return "N/A" }
    if ($Bytes -eq 0) { return "0 Bytes" }

    $suffixes = "Bytes", "KB", "MB", "GB", "TB", "PB", "EB"
    $index = 0
    $size = [double]$Bytes
    while ($size -ge 1024 -and $index -lt ($suffixes.Length - 1)) {
        $size /= 1024
        $index++
    }
    return "{0:N2} {1}" -f $size, $suffixes[$index]
}

# --- Initial Validations ---
Write-Host "Starting Directory Space Analysis for: $DirectoryPath" -ForegroundColor Yellow
try {
    $resolvedPathItem = Get-Item -Path $DirectoryPath -ErrorAction Stop
    if (-not $resolvedPathItem.PSIsContainer) {
        Write-Error "Error: Path '$DirectoryPath' exists but is not a directory."
        exit 1
    }
    $DirectoryPath = $resolvedPathItem.FullName # Normalize to full path
}
catch {
    Write-Error "Error: Directory '$DirectoryPath' does not exist or is not accessible. $($_.Exception.Message)"
    exit 1
}

# --- Initialize Variables ---
$allFilesData = [System.Collections.Generic.List[PSCustomObject]]::new()
$skippedItems = [System.Collections.Generic.List[string]]::new()
$totalFilesScanned = 0
$totalSizeScanned = 0L
$ownerRetrievalFailures = 0

# --- Data Collection ---
Write-Host "Phase 1: Scanning directory and collecting file data..."
$activity = "Scanning Files in '$((Get-Item $DirectoryPath).Name)'"
$status = "Initializing scan..."
Write-Progress -Activity $activity -Status $status -PercentComplete 0 -Id 1

$itemsToScan = Get-ChildItem -Path $DirectoryPath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +gciErrors
$filesToProcess = @($itemsToScan | Where-Object { -not $_.PSIsContainer })
$totalFileCountEstimate = $filesToProcess.Count
$processedFileCount = 0

if ($gciErrors -and $gciErrors.Count -gt 0) {
    foreach ($err in $gciErrors) {
        Write-Warning "Initial Scan Error: Could not access '$($err.TargetObject)' - $($err.Exception.Message)"
        $skippedItems.Add("Folder/Item: $($err.TargetObject) (Reason: $($err.Exception.Message))")
    }
}

if ($totalFileCountEstimate -eq 0) {
     Write-Progress -Activity $activity -Status "No files found to process or directory is empty/inaccessible." -Completed -Id 1
     Write-Warning "No files found in '$DirectoryPath' or subdirectories. The directory might be empty or fully inaccessible."
} else {
    foreach ($fileInfo in $filesToProcess) {
        $processedFileCount++
        $percentComplete = if ($totalFileCountEstimate -gt 0) { ($processedFileCount / $totalFileCountEstimate) * 100 } else { 100 }
        Write-Progress -Activity $activity -Status "Processing file $processedFileCount of $totalFileCountEstimate : $($fileInfo.Name)" -PercentComplete $percentComplete -Id 1

        $fileOwnerStr = "N/A (Default)"
        try {
            $acl = Get-Acl -Path $fileInfo.FullName -ErrorAction Stop
            $fileOwnerStr = $acl.Owner.ToString()
        }
        catch [System.Management.Automation.ItemNotFoundException] { $fileOwnerStr = "Error: Item not found for ACL"; $ownerRetrievalFailures++ }
        catch [System.IO.PathTooLongException] { $fileOwnerStr = "Error: Path too long for ACL"; $ownerRetrievalFailures++ }
        catch [System.UnauthorizedAccessException] { $fileOwnerStr = "Access Denied (Get-Acl)"; $ownerRetrievalFailures++ }
        catch { $fileOwnerStr = "Error Retrieving Owner: $($_.Exception.GetType().Name)"; $ownerRetrievalFailures++ }

        $fileData = [PSCustomObject]@{
            FullName      = $fileInfo.FullName
            Name          = $fileInfo.Name
            Extension     = if ($fileInfo.Extension) { $fileInfo.Extension.ToLower() } else { '' }
            SizeInBytes   = $fileInfo.Length
            CreationTime  = $fileInfo.CreationTime 
            LastWriteTime = $fileInfo.LastWriteTime 
            LastAccessTime= $fileInfo.LastAccessTime
            Owner         = $fileOwnerStr
            CreationDate  = $fileInfo.CreationTime.Date 
            LastWriteDate = $fileInfo.LastWriteTime.Date 
        }
        $allFilesData.Add($fileData)
        $totalFilesScanned++
        $totalSizeScanned += $fileInfo.Length
    }
    Write-Progress -Activity $activity -Status "Scan Complete." -Completed -Id 1
}

Write-Host "Phase 1 Complete: Collected data for $totalFilesScanned files. Total size: $(Format-FileSize $totalSizeScanned)."

# --- Analysis and Summarization ---
Write-Host "`nPhase 2: Analyzing data and generating summaries..."
$reportOutput = [System.Text.StringBuilder]::new()

function Add-ReportEntry {
    param (
        [string]$Title,
        $Data,
        [switch]$IsRawString
    )
    [void]$reportOutput.AppendLine()
    [void]$reportOutput.AppendLine(("-" * 80))
    [void]$reportOutput.AppendLine($Title)
    [void]$reportOutput.AppendLine(("-" * $Title.Length))

    Write-Host "`n" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Green
    Write-Host (("-" * $Title.Length)) -ForegroundColor Green

    if ($Data -and ($Data.Count -gt 0 -or $IsRawString)) { # Check if $Data has items or is raw string
        if ($IsRawString) {
            [void]$reportOutput.AppendLine($Data)
            Write-Host $Data
        } else {
            $formattedData = $Data | Format-Table -AutoSize | Out-String
            [void]$reportOutput.AppendLine($formattedData)
            $Data | Format-Table -AutoSize
        }
    } else {
        $noDataMsg = "No data to display for this section."
        [void]$reportOutput.AppendLine($noDataMsg)
        Write-Host $noDataMsg
    }
}

function Add-ReportSimpleLine {
    param ([string]$Line)
    [void]$reportOutput.AppendLine($Line)
    Write-Host $Line
}

# A. Summary by Extension Type
if ($allFilesData.Count -gt 0) {
    $extensionSummary = $allFilesData | Group-Object Extension |
        ForEach-Object {
            [PSCustomObject]@{
                IntermediateKey = $_.Name 
                FileCount       = $_.Count
                TotalSizeBytes  = ($_.Group | Measure-Object SizeInBytes -Sum).Sum
            }
        } |
        Sort-Object TotalSizeBytes -Descending |
        Select-Object @{Name = "Extension"; Expression = { if ([string]::IsNullOrEmpty($_.IntermediateKey)) { "[No Extension]" } else { $_.IntermediateKey } }},
                      @{Name = "Count"; Expression = { $_.FileCount }},
                      @{Name = "TotalSizeReadable"; Expression = { Format-FileSize $_.TotalSizeBytes }},
                      @{Name = "Percentage (%)"; Expression = {
                            if ($_.TotalSizeBytes -ne $null -and $totalSizeScanned -gt 0) {
                                "{0:N2}" -f (($_.TotalSizeBytes / $totalSizeScanned) * 100)
                            } elseif ($_.TotalSizeBytes -eq 0) {
                                "0.00"
                            } else { "" }
                        }}
    Add-ReportEntry -Title "Summary by File Extension Type" -Data $extensionSummary
} else { Add-ReportEntry -Title "Summary by File Extension Type" -Data $null }

# B. Summary by Creation Time (Grouped by Date)
if ($allFilesData.Count -gt 0) {
    $creationDateSummary = $allFilesData | Group-Object CreationDate |
                ForEach-Object {
            $keyFromGroup = $_.Name
            $dateForSort = $keyFromGroup # Default to original key (could be DateTime, null, or string)

            if ($keyFromGroup -is [string]) {
                # Attempt to parse the string key into a DateTime object.
                # -as [datetime] returns $null on failure instead of throwing an error.
                $parsedDate = $keyFromGroup -as [datetime]
                if ($parsedDate) { # If parsing was successful
                    $dateForSort = $parsedDate
                }
                # If $keyFromGroup is a string but not parsable, $dateForSort remains the original string.
            }

            [PSCustomObject]@{
                IntermediateDate  = $dateForSort # This will be used for Sort-Object
                IntermediateCount = $_.Count
                IntermediateBytes = ($_.Group | Measure-Object SizeInBytes -Sum).Sum
            }
        } |
        Sort-Object IntermediateDate -Descending |
        Select-Object @{Name = "CreationDate"; Expression = {
                            $key = $_.IntermediateDate
                            if ($key -is [datetime]) {
                                $key.ToString("yyyy-MM-dd")
                            } elseif ($key -eq $null) {
                                "[DATE_WAS_NULL]"
                            } else {
                                # Output the type of the key if it's unexpected
                                "[UNEXPECTED_TYPE: $($key.GetType().FullName) VALUE: '$($key)']"
                            }
                        }},
                      @{Name = "Count"; Expression = { $_.IntermediateCount }},
                      @{Name = "TotalSizeReadable"; Expression = { Format-FileSize $_.IntermediateBytes }},
                      @{Name = "Percentage (%)"; Expression = {
                            if ($_.IntermediateBytes -ne $null -and $totalSizeScanned -gt 0) {
                                "{0:N2}" -f (($_.IntermediateBytes / $totalSizeScanned) * 100)
                            } elseif ($_.IntermediateBytes -eq 0) {
                                "0.00"
                            } else { "" }
                        }}
    Add-ReportEntry -Title "Summary by File Creation Date (Most Recent First)" -Data $creationDateSummary
} else { Add-ReportEntry -Title "Summary by File Creation Date (Most Recent First)" -Data $null }

# C. Summary by Last Write Time (Grouped by Date)
if ($allFilesData.Count -gt 0) {
    $lastWriteDateSummary = $allFilesData | Group-Object LastWriteDate |
        ForEach-Object {
            $keyFromGroup = $_.Name
            $dateForSort = $keyFromGroup # Default to original key (could be DateTime, null, or string)

            if ($keyFromGroup -is [string]) {
                # Attempt to parse the string key into a DateTime object.
                # -as [datetime] returns $null on failure instead of throwing an error.
                $parsedDate = $keyFromGroup -as [datetime]
                if ($parsedDate) { # If parsing was successful
                    $dateForSort = $parsedDate
                }
                # If $keyFromGroup is a string but not parsable, $dateForSort remains the original string.
            }

            [PSCustomObject]@{
                IntermediateDate  = $dateForSort # This will be used for Sort-Object
                IntermediateCount = $_.Count
                IntermediateBytes = ($_.Group | Measure-Object SizeInBytes -Sum).Sum
            }
        } |
        Sort-Object IntermediateDate -Descending |
        Select-Object @{Name = "LastWriteDate"; Expression = {
                            $key = $_.IntermediateDate
                            if ($key -is [datetime]) {
                                $key.ToString("yyyy-MM-dd")
                            } elseif ($key -eq $null) {
                                "[DATE_WAS_NULL]"
                            } else {
                                "[UNEXPECTED_TYPE: $($key.GetType().FullName) VALUE: '$($key)']"
                            }
                        }},
                      @{Name = "Count"; Expression = { $_.IntermediateCount }},
                      @{Name = "TotalSizeReadable"; Expression = { Format-FileSize $_.IntermediateBytes }},
                      @{Name = "Percentage (%)"; Expression = {
                            if ($_.IntermediateBytes -ne $null -and $totalSizeScanned -gt 0) {
                                "{0:N2}" -f (($_.IntermediateBytes / $totalSizeScanned) * 100)
                            } elseif ($_.IntermediateBytes -eq 0) {
                                "0.00"
                            } else { "" }
                        }}
    Add-ReportEntry -Title "Summary by File Last Write Date (Most Recent First)" -Data $lastWriteDateSummary
} else { Add-ReportEntry -Title "Summary by File Last Write Date (Most Recent First)" -Data $null }

# D. Summary by File Owner
if ($allFilesData.Count -gt 0) {
    $ownerSummary = $allFilesData | Group-Object Owner |
        ForEach-Object {
            [PSCustomObject]@{
                IntermediateOwner = $_.Name 
                IntermediateCount = $_.Count
                IntermediateBytes = ($_.Group | Measure-Object SizeInBytes -Sum).Sum
            }
        } |
        Sort-Object IntermediateBytes -Descending |
        Select-Object @{Name = "Owner"; Expression = { if ([string]::IsNullOrEmpty($_.IntermediateOwner)) { "[Not Specified/Empty]" } else { $_.IntermediateOwner } }},
                      @{Name = "Count"; Expression = { $_.IntermediateCount }},
                      @{Name = "TotalSizeReadable"; Expression = { Format-FileSize $_.IntermediateBytes }},
                      @{Name = "Percentage (%)"; Expression = {
                            if ($_.IntermediateBytes -ne $null -and $totalSizeScanned -gt 0) {
                                "{0:N2}" -f (($_.IntermediateBytes / $totalSizeScanned) * 100)
                            } elseif ($_.IntermediateBytes -eq 0) {
                                "0.00"
                            } else { "" }
                        }}
    Add-ReportEntry -Title "Summary by File Owner" -Data $ownerSummary
    if ($ownerRetrievalFailures -gt 0) {
        $ownerNote = "Note: Owner information could not be retrieved or had errors for $ownerRetrievalFailures files (see specific owner values like 'Access Denied', 'Error Retrieving Owner', etc.)."
        Add-ReportSimpleLine $ownerNote
    }
} else { Add-ReportEntry -Title "Summary by File Owner" -Data $null }

# E.1. Top N Largest Files
if ($allFilesData.Count -gt 0) {
    $topNFiles = $allFilesData | Sort-Object SizeInBytes -Descending | Select-Object -First $ShowTopNFiles |
        Select-Object FullName,
                      @{Name = "Size"; Expression = { Format-FileSize $_.SizeInBytes }},
                      @{Name = "LastWriteTime"; Expression = {$_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")}},
                      Owner
    Add-ReportEntry -Title "Top $ShowTopNFiles Largest Files" -Data $topNFiles
} else { Add-ReportEntry -Title "Top $ShowTopNFiles Largest Files" -Data $null }

# E.2. Largest Folders (Top Level)
$folderSizeData = [ordered]@{}
$canonicalScannedPath = (Resolve-Path $DirectoryPath).ProviderPath.TrimEnd('\/')

$filesInRoot = $allFilesData | Where-Object { (Split-Path $_.FullName -Parent).TrimEnd('\/') -eq $canonicalScannedPath }
if ($filesInRoot.Count -gt 0) {
    $sizeInRoot = ($filesInRoot | Measure-Object SizeInBytes -Sum).Sum
    $countInRoot = $filesInRoot.Count
    $folderSizeData["[Files directly in '$((Get-Item $DirectoryPath).Name)']"] = @{ Size = $sizeInRoot; FileCount = $countInRoot }
}

$immediateSubFolders = Get-ChildItem -Path $DirectoryPath -Directory -Force -ErrorAction SilentlyContinue
foreach ($subFolder in $immediateSubFolders) {
    $subFolderPath = $subFolder.FullName
    $subFolderPathForMatch = $subFolderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    
    $filesInSubFolder = $allFilesData | Where-Object { $_.FullName.StartsWith($subFolderPathForMatch, [System.StringComparison]::OrdinalIgnoreCase) }
    
    $sizeInSubFolder = 0L
    $countInSubFolder = 0
    $sumResult = $null
    if ($filesInSubFolder.Count -gt 0) {
        $sumResult = ($filesInSubFolder | Measure-Object SizeInBytes -Sum).Sum
        $countInSubFolder = $filesInSubFolder.Count
    }
    $sizeInSubFolder = if ($sumResult -eq $null) { 0L } else { [long]$sumResult }

    $folderSizeData[$subFolder.Name] = @{ Size = $sizeInSubFolder; FileCount = $countInSubFolder }
}

if ($folderSizeData.Keys.Count -gt 0) {
    $topLevelFolderSummary = $folderSizeData.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            FolderName          = $_.Name
            TotalFiles          = $_.Value.FileCount
            TotalSizeBytes      = $_.Value.Size 
            IntermediatePercentage = if ($_.Value.Size -ne $null -and $totalSizeScanned -gt 0) {
                                        "{0:N2}" -f (($_.Value.Size / $totalSizeScanned) * 100)
                                    } elseif ($_.Value.Size -eq 0) {
                                        "0.00"
                                    } else { "" }
        }
    } | Sort-Object TotalSizeBytes -Descending |
      Select-Object FolderName, 
                    TotalFiles, 
                    @{Name = "TotalSizeReadable"; Expression = { Format-FileSize $_.TotalSizeBytes }},
                    @{Name = "Percentage (%)"; Expression = { $_.IntermediatePercentage }}
    
    Add-ReportEntry -Title "Summary by Top-Level Folder Size (within '$((Get-Item $DirectoryPath).Name)')" -Data $topLevelFolderSummary
} else { Add-ReportEntry -Title "Summary by Top-Level Folder Size (within '$((Get-Item $DirectoryPath).Name)')" -Data $null }


# F. Overall Summary
$totalFoldersScanned = (Get-ChildItem -Path $DirectoryPath -Recurse -Directory -Force -ErrorAction SilentlyContinue).Count

$overallSummaryObject = [PSCustomObject]@{
    ScannedDirectory        = $DirectoryPath
    TotalSizeOfDirectory    = Format-FileSize $totalSizeScanned
    TotalFilesFound         = $totalFilesScanned
    TotalFoldersFound       = $totalFoldersScanned
    ItemsSkippedDueToAccess = $skippedItems.Count
}
$overallSummaryString = $overallSummaryObject | Format-List | Out-String
Add-ReportEntry -Title "Overall Directory Summary" -Data $overallSummaryString.TrimEnd() -IsRawString

if ($skippedItems.Count -gt 0) {
    Add-ReportSimpleLine "`nSkipped Items/Paths Due to Access Errors during initial scan:"
    $skippedItems | ForEach-Object { Add-ReportSimpleLine "- $_" }
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Add-ReportSimpleLine ("`n" + ("-" * 80))
Add-ReportSimpleLine ("Script execution time: {0:N2} seconds" -f $scriptDuration.TotalSeconds)
Add-ReportSimpleLine ("Report generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

if ($ReportPath) {
    $ReportOutputDirectory = $ReportPath 

    # --- Generate the filename ---
    # 1. Get the base name of the scanned directory from $resolvedPathItem (which is validated)
    $dirScannedNamePart = Split-Path -Path $resolvedPathItem.FullName -Leaf
    
    # Handle cases where Split-Path might return an empty, purely whitespace, or problematic name (like just '/')
    if ([string]::IsNullOrWhiteSpace($dirScannedNamePart) -or $dirScannedNamePart -eq '/' -or $dirScannedNamePart -eq '\') {
        # For root paths (e.g., "C:\", "/"), try to use the drive/mount name.
        if ($resolvedPathItem.FullName -eq $resolvedPathItem.PSDrive.Root) {
            $dirScannedNamePart = $resolvedPathItem.PSDrive.Name + "_root"
        } else {
            # Generic fallback if the leaf name is unusual but not a clear drive root
            $dirScannedNamePart = "target_scan" 
        }
    }

    # 2. Sanitize the directory name part for safe use in a filename

    $sanitizedDirScannedName = $dirScannedNamePart -replace '[\\/:*?"<>|]+', '_' -replace '\s+', '_' -replace '_+', '_'
    $sanitizedDirScannedName = $sanitizedDirScannedName.Trim('_')

    # If, after all sanitization, the name part is empty (e.g., original was just '///' or purely invalid chars), use a default.
    if ([string]::IsNullOrWhiteSpace($sanitizedDirScannedName)) {
        $sanitizedDirScannedName = "storage_scan_report" # Default base name if derived one is empty
    }
    
    # 3. Get the current datetime string in a sortable and unique format
    $datetimeString = Get-Date -Format 'yyyyMMddHHmmss'
    
    # 4. Construct the filename
    $fileName = "$($sanitizedDirScannedName)_storage_summary_$($datetimeString).txt"
    
    # 5. Construct the full path for the report file
    $finalOutputFilePath = Join-Path -Path $ReportOutputDirectory -ChildPath $fileName
    # --- End of filename generation ---

    Write-Host "`nSaving report to: $finalOutputFilePath" -ForegroundColor Yellow
    try {
        $fileReportHeader = @"
Directory Space Analysis Report
=================================
Scanned Directory: $DirectoryPath
Report Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Analysis Duration: $($scriptDuration.TotalSeconds.ToString("N2")) seconds
Total Files Scanned: $totalFilesScanned
Total Scanned Size: $(Format-FileSize $totalSizeScanned)
Skipped Items (Initial Scan): $($skippedItems.Count)
Owner Retrieval Failures (Get-Acl related): $ownerRetrievalFailures
=================================
"@
        $finalReportContent = $fileReportHeader + "`n" + $reportOutput.ToString()
        
        # Ensure the $ReportOutputDirectory exists.
        if (-not (Test-Path -Path $ReportOutputDirectory -PathType Container)) {
            Write-Host "Creating report directory: $ReportOutputDirectory"
            try {
                New-Item -Path $ReportOutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Error "Failed to create report directory '$ReportOutputDirectory': $($_.Exception.Message)"
                # Optionally, exit or throw here if directory creation is critical
                throw "Cannot proceed without report directory." 
            }
        }

        Set-Content -Path $finalOutputFilePath -Value $finalReportContent -Encoding UTF8 -Force
        Write-Host "Report saved successfully to '$finalOutputFilePath'." -ForegroundColor Green
    }
    catch {
        Write-Error "Error saving report to '$finalOutputFilePath': $($_.Exception.Message)"
    }
}

Write-Host "`nAnalysis complete." -ForegroundColor Green