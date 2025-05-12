<#
.SYNOPSIS
    Synchronizes 8.3 short names from a source directory to an identical destination directory.
    Assumes destination directory structure and long file/folder names are identical to source.

.DESCRIPTION
    This script performs the following actions:
    1. Checks for Administrator privileges and self-elevates if necessary.
    2. Prompts for and enables 8.3 name creation on the destination volume if not already enabled.
    3. Recursively scans the source directory, collecting the 8.3 short names for all files and folders.
       This information is stored in memory as an array of custom objects.
    4. Iterates through the collected items and applies the corresponding 8.3 short name to each item
       in the destination directory using 'fsutil file setshortname'.

.PARAMETER SourcePath
    The full path to the source directory. This directory MUST have 8.3 short names.

.PARAMETER DestinationPath
    The full path to the destination directory. This directory's content and structure MUST be
    identical to the SourcePath (e.g., after a 'robocopy /mir /copyall' operation).
    8.3 short names will be created/updated here.

.EXAMPLE
    .\Sync-ShortNames.ps1 -SourcePath "C:\SourceData" -DestinationPath "D:\DestinationCopy"

.EXAMPLE
    .\Sync-ShortNames.ps1 -SourcePath "C:\SourceData" -DestinationPath "D:\DestinationCopy" -Verbose
    Runs the script with verbose output for more detailed logging.

.NOTES
    - Requires Administrator privileges to run 'fsutil'.
    - The destination volume must support 8.3 name creation. The script will attempt to enable it.
    - This script assumes the long file names and directory structure are IDENTICAL between
      source and destination. It only focuses on applying the short names.
    - For very large directory structures, this script might take a considerable amount of time.
    - The 'Scripting.FileSystemObject' COM object is used for reliable short name retrieval.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the source directory with existing 8.3 names.")]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourcePath,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the destination directory (identical structure to source).")]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$DestinationPath
)

#region Administrator Check
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Warning "This script requires Administrator privileges to run 'fsutil'. Please re-run as Administrator."
    # Attempt to self-elevate
    try {
        $scriptArgs = $MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) `"$($_.Value)`"" }
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -File `"$($MyInvocation.MyCommand.Path)`" $scriptArgs" -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to self-elevate. Please run the script manually as Administrator."
    }
    exit 1
}
#endregion Administrator Check

#region 8.3 Name Enablement
function Enable-8dot3NameOnVolume ([string]$Path) {
    $drive = (Get-Item -Path $Path).PSDrive.Name + ":"
    Write-Verbose "Checking 8.3 name status for volume $drive"

    try {
        $statusOutput = fsutil 8dot3name query $drive 2>&1
        Write-Verbose "fsutil query output: $statusOutput"

        # Registry settings for 8dot3name creation:
        # 0: Enable 8dot3 name creation on all volumes on the system.
        # 1: Disable 8dot3 name creation on all volumes on the system.
        # 2: Set 8dot3 name creation on a per volume basis.
        # 3: Disable 8dot3 name creation on all volumes except the system volume.

        $registryValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisable8dot3NameCreation" -ErrorAction SilentlyContinue
        $globalSetting = if ($registryValue) { $registryValue.NtfsDisable8dot3NameCreation } else { 0 } # Default to 0 (enabled) if registry key not found

        if ($statusOutput -match "The registry state is (\d)") { # Windows 8/Server 2012 and later
            $volumeState = $matches[1]
            if ($volumeState -eq 1) { # 1 means 8.3 creation is disabled for this volume
                Write-Host "8.3 name creation is disabled for volume $drive."
                if ($PSCmdlet.ShouldProcess("volume $drive", "Enable 8.3 name creation")) {
                    Write-Host "Attempting to enable 8.3 name creation for volume $drive..."
                    fsutil 8dot3name set $drive 0 # 0: Enable 8dot3 name creation for this volume
                    Start-Sleep -Seconds 2 # Give it a moment
                    $statusOutput = fsutil 8dot3name query $drive
                    if ($statusOutput -match "The registry state is 0") {
                        Write-Host "Successfully enabled 8.3 name creation for volume $drive." -ForegroundColor Green
                    } else {
                        Write-Error "Failed to enable 8.3 name creation for volume $drive. Output: $statusOutput"
                        return $false
                    }
                } else {
                    Write-Warning "8.3 name creation not enabled by user. Script may not function as expected."
                    return $false
                }
            } elseif ($volumeState -eq 0) {
                 Write-Host "8.3 name creation is already enabled for volume $drive." -ForegroundColor Green
            } else { # This covers states 2 and 3 on a per-volume basis query; if not 0, it's effectively disabled for our needs here.
                Write-Warning "8.3 name status for $drive is '$volumeState' (typically per-volume, and this volume is not explicitly enabled, or global setting overrides)."
                 if ($PSCmdlet.ShouldProcess("volume $drive", "Enable 8.3 name creation specifically for this volume (fsutil 8dot3name set $drive 0)")) {
                    Write-Host "Attempting to enable 8.3 name creation for volume $drive..."
                    fsutil 8dot3name set $drive 0 # 0: Enable 8dot3 name creation for this volume
                    Start-Sleep -Seconds 2
                    $statusOutput = fsutil 8dot3name query $drive
                    if ($statusOutput -match "The registry state is 0") {
                        Write-Host "Successfully enabled 8.3 name creation for volume $drive." -ForegroundColor Green
                    } else {
                        Write-Error "Failed to enable 8.3 name creation for volume $drive. Output: $statusOutput"
                        return $false
                    }
                } else {
                    Write-Warning "8.3 name creation not enabled by user. Script may not function as expected."
                    return $false
                }
            }
        } elseif ($globalSetting -eq 1 -or $globalSetting -eq 3) { # Older systems or global disable
             Write-Host "Global 8.3 name creation setting (NtfsDisable8dot3NameCreation=$globalSetting) indicates it's disabled or restricted."
             if ($PSCmdlet.ShouldProcess("system", "Enable 8.3 name creation globally (set NtfsDisable8dot3NameCreation to 0 via 'fsutil 8dot3name set 0')")) {
                Write-Host "Attempting to enable 8.3 name creation globally (fsutil 8dot3name set 0)..."
                fsutil 8dot3name set 0 # This sets the GLOBAL NtfsDisable8dot3NameCreation registry value to 0
                Start-Sleep -Seconds 2
                # Re-query specifically for the target volume
                $statusOutput = fsutil 8dot3name query $drive
                if ($statusOutput -match "The registry state is 0" -or $statusOutput -match "0 \(8dot3 name creation is enabled on all volumes\)") {
                    Write-Host "Successfully enabled 8.3 name creation globally, and it applies to volume $drive." -ForegroundColor Green
                } else {
                    Write-Error "Failed to enable 8.3 name creation globally or confirm for $drive. Output: $statusOutput"
                    return $false
                }
            } else {
                Write-Warning "Global 8.3 name creation not enabled by user. Script may not function as expected."
                return $false
            }
        }
        else { # Default case: globalSetting is 0 (enabled) or 2 (per volume, and specific volume state was not 1)
            Write-Host "8.3 name creation appears to be enabled for volume $drive (or globally)." -ForegroundColor Green
        }
        return $true
    }
    catch {
        # FIXED LINE 150: Removed the extra colon after $drive
        Write-Error "Error checking/setting 8.3 name status for volume $drive. Error details: $($_.Exception.Message)"
        return $false
    }
}

if (-not (Enable-8dot3NameOnVolume -Path $DestinationPath)) {
    Write-Error "Cannot proceed without 8.3 name creation enabled on the destination volume. Exiting."
    exit 1
}
#endregion 8.3 Name Enablement

#region Main Script Logic
$SourcePath = (Resolve-Path -Path $SourcePath).ProviderPath
$DestinationPath = (Resolve-Path -Path $DestinationPath).ProviderPath

Write-Host "Source Path: $SourcePath"
Write-Host "Destination Path: $DestinationPath"

$fso = New-Object -ComObject Scripting.FileSystemObject
$shortNameCache = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    Write-Host "Phase 1: Collecting short names from source '$SourcePath'..."
    $sourceItems = Get-ChildItem -Path $SourcePath -Recurse -Force -ErrorAction SilentlyContinue
    $totalItems = $sourceItems.Count
    $currentItem = 0

    foreach ($item in $sourceItems) {
        $currentItem++
        # FIXED LINE 179: Using -f format operator for robustness
        $progressStatus = "Processing item {0} of {1}: {2}" -f $currentItem, $totalItems, $item.Name
        Write-Progress -Activity "Collecting Source Short Names" -Status $progressStatus -PercentComplete (($currentItem / $totalItems) * 100)

        $relativePath = $item.FullName.Substring($SourcePath.Length)
        if ($relativePath.StartsWith('\') -or $relativePath.StartsWith('/')) {
            $relativePath = $relativePath.Substring(1)
        }
        Write-Verbose "Processing source item: $($item.FullName) | Relative: $relativePath"

        $shortName = $null
        try {
            if ($item.PSIsContainer) {
                $shortName = $fso.GetFolder($item.FullName).ShortName
            } else {
                $shortName = $fso.GetFile($item.FullName).ShortName
            }
        }
        catch {
            Write-Warning "Could not retrieve short name for $($item.FullName): $($_.Exception.Message)"
        }

        if (-not [string]::IsNullOrWhiteSpace($shortName)) {
            $shortNameCache.Add([PSCustomObject]@{
                RelativePath = $relativePath
                ShortName    = $shortName
                IsDirectory  = $item.PSIsContainer
                SourceFullName = $item.FullName
            })
            Write-Verbose "Collected: RelPath='$relativePath', ShortName='$shortName', IsDir='$($item.PSIsContainer)'"
        } else {
            Write-Verbose "No valid short name found for source item '$($item.FullName)'. It might not have one."
        }
    }
    Write-Progress -Activity "Collecting Source Short Names" -Completed

    if ($shortNameCache.Count -eq 0) {
        Write-Warning "No items with short names found in the source. Nothing to do."
        exit 0
    }

    Write-Host "Collected $($shortNameCache.Count) items with short names from source."

    Write-Host "Phase 2: Applying short names to destination '$DestinationPath'..."
    $totalToApply = $shortNameCache.Count
    $appliedCount = 0

    $sortedCache = $shortNameCache | Sort-Object @{Expression = {($_.RelativePath -split '[\\/]').Count}}, IsDirectory -Descending

    foreach ($entry in $sortedCache) {
        $appliedCount++
        $destinationItemPath = Join-Path -Path $DestinationPath -ChildPath $entry.RelativePath
        # FIXED LINE 237: Using -f format operator for robustness
        $progressStatusApply = "Item {0} of {1}: Setting '{2}' for '{3}'" -f $appliedCount, $totalToApply, $entry.ShortName, $entry.RelativePath
        Write-Progress -Activity "Applying Short Names to Destination" -Status $progressStatusApply -PercentComplete (($appliedCount / $totalToApply) * 100)

        Write-Verbose "Attempting to set short name for: '$destinationItemPath' to '$($entry.ShortName)'"

        if (-not (Test-Path $destinationItemPath)) {
            Write-Warning "Destination item '$destinationItemPath' does not exist. Skipping. (Source: $($entry.SourceFullName))"
            continue
        }

        $destItem = Get-Item $destinationItemPath -ErrorAction SilentlyContinue
        if (!$destItem) {
             Write-Warning "Could not get destination item info for '$destinationItemPath'. Skipping."
             continue
        }
        if ($destItem.PSIsContainer -ne $entry.IsDirectory) {
            Write-Warning "Type mismatch: Source item '$($entry.SourceFullName)' (IsDir: $($entry.IsDirectory)) and Destination item '$destinationItemPath' (IsDir: $($destItem.PSIsContainer)). Skipping."
            continue
        }

        if ($PSCmdlet.ShouldProcess($destinationItemPath, "Set Short Name to '$($entry.ShortName)'")) {
            try {
                $fsutilOutput = fsutil file setshortname $destinationItemPath $entry.ShortName 2>&1
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "fsutil failed for '$destinationItemPath' with short name '$($entry.ShortName)'. Exit code: $LASTEXITCODE. Output: $fsutilOutput"
                } elseif ($fsutilOutput -match "Error:") {
                     Write-Error "fsutil reported an error for '$destinationItemPath' with short name '$($entry.ShortName)'. Output: $fsutilOutput"
                }
                else {
                    Write-Verbose "Successfully set short name for '$destinationItemPath' to '$($entry.ShortName)'."
                }
            }
            catch {
                Write-Error "Error setting short name for '$destinationItemPath' to '$($entry.ShortName)': $($_.Exception.Message)"
            }
        } else {
            Write-Warning "Skipped setting short name for '$destinationItemPath' due to -WhatIf or user cancellation."
        }
    }
    Write-Progress -Activity "Applying Short Names to Destination" -Completed
    Write-Host "Finished applying short names."

}
catch {
    Write-Error "An unexpected error occurred: $($_.Exception.Message)"
    Write-Error "Stack Trace: $($_.ScriptStackTrace)"
}
finally {
    if ($fso) {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) | Out-Null
        $fso = $null
        # Trigger garbage collection for COM object sooner, though not strictly necessary for script exit.
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    Write-Host "Script finished."
}
#endregion Main Script Logic