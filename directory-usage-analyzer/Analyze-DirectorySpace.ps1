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
}

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
}

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
}

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
    if ($ownerRetrievalFailures -gt 0) {
        $ownerNote = "Note: Owner information could not be retrieved or had errors for $ownerRetrievalFailures files (see specific owner values like 'Access Denied', 'Error Retrieving Owner', etc.)."

    }
}

# E.1. Top N Largest Files
if ($allFilesData.Count -gt 0) {
    $topNFiles = $allFilesData | Sort-Object SizeInBytes -Descending | Select-Object -First $ShowTopNFiles |
        Select-Object FullName,
                      @{Name = "Size"; Expression = { Format-FileSize $_.SizeInBytes }},
                      @{Name = "LastWriteTime"; Expression = {$_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")}},
                      Owner
} 
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
    
}


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


$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime

# Helper function for HTML encoding data. Uses System.Net.WebUtility for better PS Core compatibility.
function Encode-HtmlData {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $InputObject
    )
    if ($null -eq $InputObject) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($InputObject.ToString())
}

# Helper function to generate an HTML table from an array of objects
function ConvertTo-TailwindHtmlTable {
    param(
        [string]$TableId,
        [string]$Title,
        [array]$Data,
        [System.Collections.IDictionary]$PropertyMapping # Keys are Headers, Values are PropertyNames or ScriptBlocks
    )

    if (-not $Data -or $Data.Count -eq 0) {
        $noDataMessage = "<p class='text-gray-600 italic mt-2'>No data available for this section.</p>"
        return $noDataMessage 
    }

    $htmlBuilder = [System.Text.StringBuilder]::new()
    [void]$htmlBuilder.AppendLine("<div class='overflow-x-auto'>")
    [void]$htmlBuilder.AppendLine("<table id='$TableId' class='min-w-full bg-white rounded-lg shadow overflow-hidden'>")
    [void]$htmlBuilder.AppendLine("  <thead class='bg-gray-800 text-white'>")
    [void]$htmlBuilder.AppendLine("    <tr>")
    foreach ($header in $PropertyMapping.Keys) {
        # Center header text as well for consistency, or keep text-left if preferred
        [void]$htmlBuilder.AppendLine("      <th class='py-3 px-4 text-center uppercase font-semibold text-sm'>$(Encode-HtmlData $header)</th>")
    }
    [void]$htmlBuilder.AppendLine("    </tr>")
    [void]$htmlBuilder.AppendLine("  </thead>")
    [void]$htmlBuilder.AppendLine("  <tbody class='text-gray-700 text-sm'>")

    foreach ($item in $Data) {
        [void]$htmlBuilder.AppendLine("    <tr class='border-b border-gray-200 hover:bg-gray-100 transition-colors duration-150 ease-in-out'>")
        foreach ($entry in $PropertyMapping.GetEnumerator()) {
            $header = $entry.Key # Not used in this loop iteration for cell value but kept for context
            $propertyOrScriptBlock = $entry.Value
            $cellValue = ""
            
            try {
                if ($propertyOrScriptBlock -is [string]) {
                    $props = $propertyOrScriptBlock.Split('.')
                    $currentValue = $item
                    foreach($propName in $props){
                        if($null -ne $currentValue -and $currentValue.PSObject.Properties[$propName]){
                            $currentValue = $currentValue.PSObject.Properties[$propName].Value
                        } else {
                            $currentValue = $null
                            break
                        }
                    }
                    $cellValue = Encode-HtmlData $currentValue
                } elseif ($propertyOrScriptBlock -is [ScriptBlock]) {
                    $cellValue = Invoke-Command -ScriptBlock $propertyOrScriptBlock -ArgumentList $item 
                } else {
                    $cellValue = "[Invalid PropertyMapping Value Type]"
                }
            }
            catch {
                $cellValue = "[Error Accessing Property: $($propertyOrScriptBlock)]"
                Write-Warning "Error processing property '$($propertyOrScriptBlock)' for item: $($item | Out-String). Error: $($_.Exception.Message)"
            }
            
            $textAlign = "text-center" 

            [void]$htmlBuilder.AppendLine("      <td class='py-3 px-4 $textAlign whitespace-nowrap'>$cellValue</td>")
        }
        [void]$htmlBuilder.AppendLine("    </tr>")
    }

    [void]$htmlBuilder.AppendLine("  </tbody>")
    [void]$htmlBuilder.AppendLine("</table>")
    [void]$htmlBuilder.AppendLine("</div>")
    return $htmlBuilder.ToString()
}



# --- HTML Report Generation ---
$reportGeneratedTime = Get-Date
$htmlContent = [System.Text.StringBuilder]::new()

# Tailwind CSS via CDN was chosen for modern styling with utility classes, providing flexibility and a professional look.
[void]$htmlContent.AppendLine("<!DOCTYPE html>")
[void]$htmlContent.AppendLine("<html lang='en'>")
[void]$htmlContent.AppendLine("<head>")
[void]$htmlContent.AppendLine("  <meta charset='UTF-8'>")
[void]$htmlContent.AppendLine("  <meta name='viewport' content='width=device-width, initial-scale=1.0'>")
[void]$htmlContent.AppendLine("  <title>Directory Space Analysis Report</title>")
[void]$htmlContent.AppendLine("  <script src='https://cdn.tailwindcss.com'></script>") # Tailwind CSS CDN
[void]$htmlContent.AppendLine("  <style>")
[void]$htmlContent.AppendLine("    /* Custom styles if needed, e.g., for specific table sorting icons or very specific tweaks */")
[void]$htmlContent.AppendLine("    body { font-family: 'Inter', sans-serif; }") 
[void]$htmlContent.AppendLine("    @media print { body { -webkit-print-color-adjust: exact; print-color-adjust: exact; } }") 
[void]$htmlContent.AppendLine("  </style>")
[void]$htmlContent.AppendLine("</head>")
[void]$htmlContent.AppendLine("<body class='bg-gray-100 text-gray-800 leading-normal tracking-normal p-0 m-0'>")
[void]$htmlContent.AppendLine("  <div class='container mx-auto p-4 md:p-6 lg:p-8'>") # Main container

# Header
[void]$htmlContent.AppendLine("    <header class='mb-8 p-6 bg-white rounded-lg shadow-lg text-center'>")
[void]$htmlContent.AppendLine("      <h1 class='text-3xl md:text-4xl font-bold text-indigo-600'>Directory Space Analysis Report</h1>")
[void]$htmlContent.AppendLine("      <p class='text-lg md:text-xl text-gray-700 mt-2'>Target Directory: <span class='font-semibold'>$(Encode-HtmlData $DirectoryPath)</span></p>")
[void]$htmlContent.AppendLine("      <p class='text-sm text-gray-500 mt-1'>Report Generated: $($reportGeneratedTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>")
[void]$htmlContent.AppendLine("    </header>")

[void]$htmlContent.AppendLine("    <main>")

# Section: Overall Summary
[void]$htmlContent.AppendLine("    <section id='overall-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
[void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Overall Summary</h2>")
[void]$htmlContent.AppendLine("      <div class='grid grid-cols-1 md:grid-cols-2 gap-4 text-sm'>")
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Scanned Directory:</strong> <span class='break-all'>$(Encode-HtmlData $overallSummaryObject.ScannedDirectory)</span></div>")
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Total Size of Directory:</strong> $(Encode-HtmlData $overallSummaryObject.TotalSizeOfDirectory)</div>") # Already formatted by Format-FileSize
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Total Files Found:</strong> $(Encode-HtmlData $overallSummaryObject.TotalFilesFound)</div>")
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Total Folders Found:</strong> $(Encode-HtmlData $overallSummaryObject.TotalFoldersFound)</div>") # $totalFoldersScanned
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Items Skipped (Initial Scan):</strong> $(Encode-HtmlData $overallSummaryObject.ItemsSkippedDueToAccess)</div>")
[void]$htmlContent.AppendLine("        <div><strong class='text-gray-600'>Owner Retrieval Failures:</strong> $(Encode-HtmlData $ownerRetrievalFailures)</div>")
[void]$htmlContent.AppendLine("      </div>")
[void]$htmlContent.AppendLine("    </section>")

# Section: Top N Largest Files
if ($topNFiles -and $topNFiles.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='top-n-files' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Top $($ShowTopNFiles) Largest Files</h2>")
    $topNFilesProps = [ordered]@{
        "File Name" = 'Name' # Assuming $topNFiles items have a Name property; if not, adjust or use FullName
        "Full Path" = 'FullName'
        "Size" = 'Size' # This is already formatted by Format-FileSize in the original data prep
        "Last Write Time" = 'LastWriteTime'
        "Owner" = 'Owner'
    }
    # Create a temporary projection if Name is not directly on $topNFiles but FullName is
    $projectedTopNFiles = $topNFiles | Select-Object FullName, @{N='Name';E={Split-Path $_.FullName -Leaf}}, Size, LastWriteTime, Owner
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "topNFilesTable" -Title "Top N Files" -Data $projectedTopNFiles -PropertyMapping $topNFilesProps))
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Summary by Top-Level Folder Size
if ($topLevelFolderSummary -and $topLevelFolderSummary.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='folder-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Summary by Top-Level Folder Size (within '$(Encode-HtmlData ((Get-Item $DirectoryPath).Name))')</h2>")
    $folderSummaryProps = [ordered]@{
        "Folder Name" = 'FolderName'
        "Total Files" = 'TotalFiles'
        "Total Size" = 'TotalSizeReadable'
        "Percentage (%)" = 'Percentage (%)'
    }
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "folderSummaryTable" -Title "Folder Summary" -Data $topLevelFolderSummary -PropertyMapping $folderSummaryProps))
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Summary by File Extension Type
if ($extensionSummary -and $extensionSummary.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='extension-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Summary by File Extension</h2>")
    $extSummaryProps = [ordered]@{
        "Extension" = 'Extension'
        "File Count" = 'Count'
        "Total Size" = 'TotalSizeReadable'
        "Percentage (%)" = 'Percentage (%)'
    }
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "extensionSummaryTable" -Title "Extension Summary" -Data $extensionSummary -PropertyMapping $extSummaryProps))
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Summary by File Owner
if ($ownerSummary -and $ownerSummary.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='owner-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Summary by File Owner</h2>")
    $ownerSummaryProps = [ordered]@{
        "Owner" = 'Owner'
        "File Count" = 'Count'
        "Total Size" = 'TotalSizeReadable'
        "Percentage (%)" = 'Percentage (%)'
    }
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "ownerSummaryTable" -Title "Owner Summary" -Data $ownerSummary -PropertyMapping $ownerSummaryProps))
    if ($ownerRetrievalFailures -gt 0) {
        [void]$htmlContent.AppendLine("      <p class='mt-3 text-sm text-orange-600'>Note: Owner information could not be retrieved or had errors for $($ownerRetrievalFailures) files.</p>")
    }
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Summary by Creation Date
if ($creationDateSummary -and $creationDateSummary.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='creation-date-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Summary by File Creation Date (Most Recent First)</h2>")
    $creationDateProps = [ordered]@{
        "Creation Date" = 'CreationDate'
        "File Count" = 'Count'
        "Total Size" = 'TotalSizeReadable'
        "Percentage (%)" = 'Percentage (%)'
    }
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "creationDateSummaryTable" -Title "Creation Date Summary" -Data $creationDateSummary -PropertyMapping $creationDateProps))
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Summary by Last Write Date
if ($lastWriteDateSummary -and $lastWriteDateSummary.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='last-write-date-summary' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-gray-700 mb-4 border-b pb-2'>Summary by File Last Write Date (Most Recent First)</h2>")
    $lastWriteDateProps = [ordered]@{
        "Last Write Date" = 'LastWriteDate'
        "File Count" = 'Count'
        "Total Size" = 'TotalSizeReadable'
        "Percentage (%)" = 'Percentage (%)'
    }
    [void]$htmlContent.AppendLine($(ConvertTo-TailwindHtmlTable -TableId "lastWriteDateSummaryTable" -Title "Last Write Date Summary" -Data $lastWriteDateSummary -PropertyMapping $lastWriteDateProps))
    [void]$htmlContent.AppendLine("    </section>")
}

# Section: Skipped Items
if ($skippedItems -and $skippedItems.Count -gt 0) {
    [void]$htmlContent.AppendLine("    <section id='skipped-items' class='mb-8 p-6 bg-white rounded-lg shadow-md'>")
    [void]$htmlContent.AppendLine("      <h2 class='text-2xl font-semibold text-orange-600 mb-4 border-b pb-2'>Skipped Items/Paths (Access Errors During Initial Scan)</h2>")
    [void]$htmlContent.AppendLine("      <ul class='list-disc list-inside text-sm text-gray-700 space-y-1 max-h-60 overflow-y-auto'>")
    foreach ($item in $skippedItems) {
        [void]$htmlContent.AppendLine("        <li class='break-all'>$(Encode-HtmlData $item)</li>")
    }
    [void]$htmlContent.AppendLine("      </ul>")
    [void]$htmlContent.AppendLine("    </section>")
}

[void]$htmlContent.AppendLine("    </main>")

# Footer
[void]$htmlContent.AppendLine("    <footer class='mt-10 py-6 text-center text-sm text-gray-500 border-t border-gray-300'>")
[void]$htmlContent.AppendLine("      <p>Script execution time: $(Encode-HtmlData (($scriptDuration.TotalSeconds).ToString('N2'))) seconds.</p>")
[void]$htmlContent.AppendLine("      <p>Asher Le © $($reportGeneratedTime.Year)</p>")
[void]$htmlContent.AppendLine("    </footer>")

[void]$htmlContent.AppendLine("  </div>") # End of container
[void]$htmlContent.AppendLine("</body>")
[void]$htmlContent.AppendLine("</html>")

# --- Save the HTML Report ---
# Determine output directory
$outputReportDirectory = $PSScriptRoot # Default to script's directory
if ($ReportPath) { # If ReportPath parameter is specified, use it as the directory
    $outputReportDirectory = $ReportPath
}

# Filename Generation (similar to original, but for .html)
$dirScannedNamePart = Split-Path -Path $resolvedPathItem.FullName -Leaf
if ([string]::IsNullOrWhiteSpace($dirScannedNamePart) -or $dirScannedNamePart -eq '/' -or $dirScannedNamePart -eq '\') {
    if ($resolvedPathItem.FullName -eq $resolvedPathItem.PSDrive.Root) {
        $dirScannedNamePart = $resolvedPathItem.PSDrive.Name + "_root"
    } else {
        $dirScannedNamePart = "target_scan"
    }
}
$sanitizedDirScannedName = $dirScannedNamePart -replace '[\\/:*?"<>|]+', '_' -replace '\s+', '_' -replace '_+', '_'
$sanitizedDirScannedName = $sanitizedDirScannedName.Trim('_')
if ([string]::IsNullOrWhiteSpace($sanitizedDirScannedName)) {
    $sanitizedDirScannedName = "storage_scan_report"
}
$datetimeStringForFile = Get-Date -Format 'yyyyMMddHHmmss'
$htmlFileName = "$($sanitizedDirScannedName)_storage_summary_$($datetimeStringForFile).html"
$finalHtmlReportPath = Join-Path -Path $outputReportDirectory -ChildPath $htmlFileName

Write-Host "`nSaving HTML report to: $finalHtmlReportPath" -ForegroundColor Yellow
try {
    if (-not (Test-Path -Path $outputReportDirectory -PathType Container)) {
        Write-Host "Creating report directory: $outputReportDirectory"
        New-Item -Path $outputReportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Set-Content -Path $finalHtmlReportPath -Value $htmlContent.ToString() -Encoding UTF8 -Force
    Write-Host "HTML Report saved successfully to '$finalHtmlReportPath'." -ForegroundColor Green
}
catch {
    Write-Error "Error saving HTML report to '$finalHtmlReportPath': $($_.Exception.Message)"
}

Write-Host "`nAnalysis complete." -ForegroundColor Green