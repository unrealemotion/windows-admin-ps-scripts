#Requires -Modules ActiveDirectory

[CmdletBinding()]
param (
    # Optional: Specify a path to export the raw data to CSV
    [Parameter(Mandatory=$false)]
    [string]$ExportCsvPath
)

# --- Configuration ---
# Specify a specific OU if needed, otherwise searches the whole domain
# Example: $searchBase = 'OU=Workstations,DC=yourdomain,DC=com'
$searchBase = $null
$adFilter = 'Enabled -eq $true' # Filter for active computer accounts

# --- Script Start ---

Write-Host "Starting OS Disk Partition Information Collection..." -ForegroundColor Yellow

# Check if Active Directory module is available
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Active Directory PowerShell module is not installed. Please install RSAT for Active Directory Domain Services."
    Exit 1
}

# Import necessary module
Import-Module ActiveDirectory -ErrorAction Stop

# Get computer list from Active Directory, including DistinguishedName for OU info
Write-Host "Querying Active Directory for computer accounts..."
try {
    $searchParams = @{
        Filter     = $adFilter
        Properties = 'Name', 'DistinguishedName' # Added DistinguishedName
    }
    if ($searchBase) {
        $searchParams.SearchBase = $searchBase
    }
    # Store the full AD objects now
    $adComputers = Get-ADComputer @searchParams
    Write-Host "Found $($adComputers.Count) enabled computer accounts."
}
catch {
    Write-Error "Failed to query Active Directory. Error: $($_.Exception.Message)"
    Exit 1
}

# Array to hold the results
$results = @()

# Process each computer
Write-Host "Processing computers..."
$totalComputers = $adComputers.Count
$processedCount = 0

foreach ($adComputer in $adComputers) {
    $processedCount++
    $computerName = $adComputer.Name
    Write-Progress -Activity "Processing Computers" -Status "Checking $($computerName) ($($processedCount)/$($totalComputers))" -PercentComplete (($processedCount / $totalComputers) * 100)

    # Extract OU Path from DistinguishedName
    # Takes the part after the first comma (removes CN=ComputerName,)
    $ouPath = $adComputer.DistinguishedName -replace '^CN=[^,]+,(.*)$', '$1'
    # Handle cases where computer might be in root Computers container (no OU= prefix)
    if ($ouPath -eq $adComputer.DistinguishedName) { # Regex didn't match/replace
         $ouPath = "Container: " + ($adComputer.DistinguishedName -split ',',2)[1] # Try splitting instead
         if ($ouPath -eq $adComputer.DistinguishedName) { # Still no luck
            $ouPath = "OU Path Not Determined"
         }
    }


    # Define common properties for the result object
    $resultProperties = @{
        ComputerName   = $computerName
        OUPath         = $ouPath
        DiskNumber     = 'N/A'
        DiskType       = 'N/A'
        PartitionCount = 'N/A'
        PartitionTypes = 'N/A'
    }

    # Check reachability via WinRM
    if (-not (Test-WSMan -ComputerName $computerName -ErrorAction SilentlyContinue)) {
        Write-Warning "[$computerName] Unreachable via WinRM. Skipping."
        $resultProperties.DiskType = 'Unreachable'
        $results += [PSCustomObject]$resultProperties
        continue # Skip to the next computer
    }

    # Attempt to get disk information remotely
    #Write-Host "[$computerName] Reachable. Querying disk information..." # Reduced verbosity
    try {
        # Use Invoke-Command to run commands on the remote machine
        $remoteData = Invoke-Command -ComputerName $computerName -ScriptBlock {
            # Find the disk marked as the System disk
            $osDisk = Get-Disk | Where-Object -Property IsSystem -eq $true | Select-Object -First 1

            if ($osDisk) {
                # Get all partitions on the specific OS disk, sorted by partition number
                $partitions = Get-Partition -DiskNumber $osDisk.Number | Sort-Object PartitionNumber

                # Extract partition types, filter out any null/empty types, and join them
                $partitionTypes = ($partitions.Type | Where-Object { $_ -ne $null -and $_ -ne '' }) -join ', '
                if (-not $partitionTypes) { $partitionTypes = 'N/A'} # Handle case where all types are empty/null

                # Create an object with the collected data
                [PSCustomObject]@{
                    DiskNumber     = $osDisk.Number
                    DiskType       = $osDisk.PartitionStyle # MBR or GPT
                    PartitionCount = $partitions.Count
                    PartitionTypes = $partitionTypes
                }
            }
            else {
                # Handle cases where no system disk is found
                [PSCustomObject]@{
                    DiskNumber     = 'N/A'
                    DiskType       = 'OS Disk Not Found'
                    PartitionCount = 'N/A'
                    PartitionTypes = 'N/A'
                }
            }
        } -ErrorAction Stop # Stop if Invoke-Command itself fails

        # Update the result properties with remotely gathered data
        $resultProperties.DiskNumber = $remoteData.DiskNumber
        $resultProperties.DiskType = $remoteData.DiskType
        $resultProperties.PartitionCount = $remoteData.PartitionCount
        $resultProperties.PartitionTypes = $remoteData.PartitionTypes
        # Write-Host "[$computerName] Successfully processed." # Reduced verbosity

    }
    catch {
        # Catch errors during remote execution
        $errorMessage = $_.Exception.Message.Split([Environment]::NewLine)[0] # Get first line of error
        Write-Warning "[$computerName] Error collecting data: $errorMessage"
        $resultProperties.DiskType = 'Error'
        $resultProperties.PartitionTypes = "Error: $errorMessage"
    }
    finally{
         # Add the result object (success, error, or unreachable) to the main results array
         $results += [PSCustomObject]$resultProperties
    }
}
Write-Progress -Activity "Processing Computers" -Completed

Write-Host "`nProcessing complete."

# --- Output ---

if ($results) {
    Write-Host "--- Results Grouped by OU ---" -ForegroundColor Yellow

    # Group the results by OUPath
    $groupedResults = $results | Group-Object -Property OUPath | Sort-Object Name # Sort OUs alphabetically

    foreach ($group in $groupedResults) {
        Write-Host "`nOU: $($group.Name)" -ForegroundColor Cyan
        # Sort computers within the OU group alphabetically and format the table
        $group.Group |
            Sort-Object ComputerName |
            Select-Object ComputerName, DiskNumber, DiskType, PartitionCount, PartitionTypes |
            Format-Table -AutoSize
    }

    # Optional: Export RAW data to CSV if path provided
    if ($PSBoundParameters.ContainsKey('ExportCsvPath')) {
       Write-Host "`nExporting raw data to CSV: $ExportCsvPath" -ForegroundColor Yellow
       try {
           # Sort the raw data by OU then ComputerName for the CSV export
           $results | Sort-Object OUPath, ComputerName |
             Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
           Write-Host "Export successful." -ForegroundColor Green
       } catch {
           Write-Error "Failed to export results to CSV '$ExportCsvPath'. Error: $($_.Exception.Message)"
       }
    }

} else {
    Write-Host "No results were collected." -ForegroundColor Yellow
}

Write-Host "`nScript finished." -ForegroundColor Yellow