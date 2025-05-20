param (
    [ValidateSet("Full", "RestoreOnly")]
    [string]$Mode = "Full",

    [string]$WinREBackupPathFullMode = "$PSScriptRoot\WinRE_Backup_$(Get-Date -Format 'yyyyMMdd-HHmmss')", # Default for full mode, not user-specified

    [Parameter(Mandatory = $false)] # Mandatory only if Mode is RestoreOnly
    [string]$WinREBackupPathRestoreMode
)

# --- Configuration ---
$global:WinREFolderName = "Recovery\WindowsRE" # Standard WinRE path within its partition
$global:NewRecoveryPartitionLabel = "Recovery"
$global:MinRecoveryPartitionSpaceMB = 300 # Minimum recommended, adjust if needed

# --- Helper Functions ---

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "ACTION")]
        [string]$Level = "INFO",
        [switch]$NoNewLine
    )
    $Color = @{
        INFO    = "White"
        WARN    = "Yellow"
        ERROR   = "Red"
        SUCCESS = "Green"
        ACTION  = "Cyan"
    }
    if ($NoNewLine) {
        Write-Host -Message "[$Level] $Message" -ForegroundColor $Color[$Level] -NoNewline
    } else {
        Write-Host -Message "[$Level] $Message" -ForegroundColor $Color[$Level]
    }
}

function Test-Admin {
    Write-Log "Checking for Administrator privileges..."
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script must be run as Administrator." "ERROR"
        Write-Log "Please re-run the script with Administrator privileges." "ACTION"
        exit 1
    }
    Write-Log "Administrator privileges confirmed." "SUCCESS"
}

function Get-OSDisk {
    Write-Log "Identifying OS disk..."
    try {
        $osPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' -and $_.Type -ne "Recovery" } | Select-Object -First 1
        if (-not $osPartition) {
            Write-Log "Could not find the OS partition (C:)." "ERROR"
            return $null
        }
        $osDisk = Get-Disk -Number $osPartition.DiskNumber
        Write-Log "OS Disk found: Disk $($osDisk.Number) ($($osDisk.FriendlyName))" "SUCCESS"
        return $osDisk
    }
    catch {
        Write-Log "Error identifying OS disk: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-WinREInfo {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$OSDisk # The OS Disk object
    )
    Write-Log "Fetching current WinRE configuration..."
    $reagentInfo = reagentc /info
    $reagentOutput = $reagentInfo -join "`n"

    if ($LASTEXITCODE -ne 0) {
        Write-Log "reagentc /info failed. Output: $reagentOutput" "ERROR"
        return $null
    }
    Write-Log "reagentc /info output:`n$reagentOutput"

    $statusLine = $reagentInfo | Where-Object { $_ -match "Windows RE status:" }
    $locationLine = $reagentInfo | Where-Object { $_ -match "Windows RE location:" }

    if (-not ($statusLine -match "Enabled")) {
        Write-Log "Windows RE is not currently enabled or location is not set." "WARN"
        Write-Log "If in 'Full' mode, this script expects an active WinRE to backup." "WARN"
        # For Full mode, we might need to be stricter or allow finding a partition by ID/name
        if ($Mode -eq "Full") {
             Write-Log "Cannot proceed in 'Full' mode without an active WinRE to backup and identify." "ERROR"
             return $null
        }
        return @{ IsEnabled = $false } # Allow RestoreOnly to proceed without an initial active WinRE
    }

    if (-not $locationLine) {
        Write-Log "Could not determine WinRE location from reagentc /info." "ERROR"
        return $null
    }

    # Regex to extract disk and partition index from \\?\GLOBALROOT\device\harddiskX\partitionY
    $match = [regex]::Match($locationLine, 'harddisk(\d+)\\partition(\d+)')
    if (-not $match.Success) {
        Write-Log "Could not parse WinRE location: $locationLine" "ERROR"
        return $null
    }

    $winreDiskIndex = [int]$match.Groups[1].Value
    $winrePartitionIndex = [int]$match.Groups[2].Value

    Write-Log "WinRE reported on Disk $winreDiskIndex, Partition $winrePartitionIndex."

    if ($winreDiskIndex -ne $OSDisk.DiskNumber) {
        Write-Log "WinRE is on a different disk (Disk $winreDiskIndex) than the OS disk (Disk $($OSDisk.DiskNumber)). This script is designed for WinRE on the OS disk." "ERROR"
        return $null
    }

    try {
        $winrePartition = Get-Partition -DiskNumber $winreDiskIndex -PartitionNumber $winrePartitionIndex
        if (-not $winrePartition) {
            Write-Log "Could not get partition object for WinRE at Disk $winreDiskIndex, Partition $winrePartitionIndex." "ERROR"
            return $null
        }
        Write-Log "Current WinRE Partition: Number $($winrePartition.PartitionNumber), Size: $([Math]::Round($winrePartition.Size / 1MB, 0)) MB, Offset: $($winrePartition.Offset)" "SUCCESS"
        return @{
            IsEnabled        = $true
            DiskNumber       = $winrePartition.DiskNumber
            PartitionNumber  = $winrePartition.PartitionNumber
            PartitionObject  = $winrePartition
            OriginalSizeMB   = [Math]::Ceiling($winrePartition.Size / 1MB) # Use ceiling for safety margin
            LocationPath     = ($locationLine -split ':       ')[1].Trim()
        }
    }
    catch {
        Write-Log "Error getting WinRE partition details: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Find-UnusedDriveLetter {
    Write-Log "Finding an unused drive letter..."
    $usedLetters = (Get-Volume).DriveLetter | Where-Object { $_ } | ForEach-Object { "$_`:\" }
    $candidateLetter = ''
    foreach ($letterCode in (68..90)) { # D to Z
        $letter = [char]$letterCode
        if ("$($letter):\" -notin $usedLetters) {
            $candidateLetter = $letter
            break
        }
    }
    if ($candidateLetter) {
        Write-Log "Found unused drive letter: $candidateLetter" "SUCCESS"
        return $candidateLetter
    }
    else {
        Write-Log "Could not find an unused drive letter (D-Z)." "ERROR"
        return $null
    }
}

function Run-DiskpartScript {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Commands
    )
    $tempScriptPath = Join-Path $env:TEMP "diskpart_temp_script.txt"
    $Commands | Out-File -FilePath $tempScriptPath -Encoding ascii -Force
    Write-Log "Executing DiskPart script:" "INFO"
    $Commands | ForEach-Object { Write-Log "  $_" "INFO" }

    $process = Start-Process diskpart -ArgumentList "/s `"$tempScriptPath`"" -Wait -PassThru -WindowStyle Hidden
    Remove-Item $tempScriptPath -ErrorAction SilentlyContinue

    if ($process.ExitCode -eq 0) {
        Write-Log "DiskPart script executed successfully." "SUCCESS"
        return $true
    } else {
        Write-Log "DiskPart script failed with exit code $($process.ExitCode)." "ERROR"
        # Diskpart output is not easily captured. User might need to check disk management.
        return $false
    }
}

function Backup-WinREPartition {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$WinREPartitionObject,
        [Parameter(Mandatory = $true)]
        [string]$BackupDestinationPath
    )
    Write-Log "Backing up WinRE partition (Disk $($WinREPartitionObject.DiskNumber), Partition $($WinREPartitionObject.PartitionNumber))..."
    $tempLetter = Find-UnusedDriveLetter
    if (-not $tempLetter) { return $false }

    $diskpartAssign = @(
        "select disk $($WinREPartitionObject.DiskNumber)",
        "select partition $($WinREPartitionObject.PartitionNumber)",
        "assign letter=$tempLetter"
    )
    if (-not (Run-DiskpartScript -Commands $diskpartAssign)) {
        Write-Log "Failed to assign drive letter to WinRE partition." "ERROR"
        return $false
    }

    Start-Sleep -Seconds 3 
    if (-not (Test-Path "$($tempLetter):")) {
        Write-Log "Drive letter $tempLetter was not successfully assigned or is not accessible." "ERROR"
        $diskpartRemoveErrorAssign = @( # Define this variable if not already defined in this path
            "select disk $($WinREPartitionObject.DiskNumber)",
            "select partition $($WinREPartitionObject.PartitionNumber)",
            "remove" 
        )
        Run-DiskpartScript -Commands $diskpartRemoveErrorAssign
        return $false
    }
    Write-Log "WinRE partition assigned to $tempLetter`:"

    if (-not (Test-Path $BackupDestinationPath)) {
        try {
            New-Item -Path $BackupDestinationPath -ItemType Directory -Force | Out-Null
            Write-Log "Created backup directory: $BackupDestinationPath" "SUCCESS"
        } catch {
            Write-Log "Failed to create backup directory '$BackupDestinationPath': $($_.Exception.Message)" "ERROR"
            return $false 
        }
    }

    Write-Log "Copying files from $tempLetter`:\ to $BackupDestinationPath using robocopy..."
    $sourceRobo = "$($tempLetter):"
    $destRobo = $BackupDestinationPath
    $RoboLogPath = Join-Path $env:TEMP "robocopy_backup_WinRE_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    $robocopyArgs = [System.Collections.Generic.List[string]]::new()
    $robocopyArgs.Add("`"$sourceRobo`"")
    $robocopyArgs.Add("`"$destRobo`"")
    $robocopyArgs.Add("*.*")
    $robocopyArgs.Add("/E")
    $robocopyArgs.Add("/COPY:DATS") 
    $robocopyArgs.Add("/DCOPY:T")   
    $robocopyArgs.Add("/XJ")
    $robocopyArgs.Add("/XD") 
    $robocopyArgs.Add("`"System Volume Information`"") 
    $robocopyArgs.Add("/XD") 
    $robocopyArgs.Add("`"\$RECYCLE.BIN`"") 
    $robocopyArgs.Add("/R:1")
    $robocopyArgs.Add("/W:1")
    $robocopyArgs.Add("/NFL")
    $robocopyArgs.Add("/NDL")
    $robocopyArgs.Add("/NJH")
    $robocopyArgs.Add("/NJS")
    $robocopyArgs.Add("/NC")
    $robocopyArgs.Add("/NS")
    $robocopyArgs.Add("/NP")
    $robocopyArgs.Add("/LOG+:`"$RoboLogPath`"")

    $copyProcessRan = $false
    $filesCopiedSuccessfully = $false
    try {
        Write-Log "Robocopy arguments being passed: $($robocopyArgs -join ' ')" "INFO"
        $process = Start-Process robocopy -ArgumentList $robocopyArgs.ToArray() -Wait -PassThru -WindowStyle Hidden
        $copyProcessRan = $true

        if ($process.ExitCode -lt 8) {
            Write-Log "Robocopy backup completed successfully (Exit Code: $($process.ExitCode))." "SUCCESS"
            $filesCopiedSuccessfully = $true
            if (Test-Path $RoboLogPath) { 
                Write-Log "Robocopy log (success) from '$RoboLogPath':" "INFO"
                Get-Content $RoboLogPath | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
                Remove-Item $RoboLogPath -ErrorAction SilentlyContinue -Force 
            }

            # --- Ensure backup folder is not System or Hidden using attrib.exe ---
            Write-Log "Ensuring backup folder '$BackupDestinationPath' is not System/Hidden..." "INFO"
            $attribProcess = Start-Process -FilePath "attrib.exe" -ArgumentList "-S -H `"$BackupDestinationPath`"" -Wait -PassThru -WindowStyle Hidden
            if ($attribProcess.ExitCode -eq 0) {
                # Verify
                $backupFolderItem = Get-Item -Path $BackupDestinationPath -Force -ErrorAction SilentlyContinue # -Force to see hidden/system
                if ($backupFolderItem -and `
                    -not ($backupFolderItem.Attributes -band [System.IO.FileAttributes]::Hidden) -and `
                    -not ($backupFolderItem.Attributes -band [System.IO.FileAttributes]::System)) {
                    Write-Log "Backup folder '$BackupDestinationPath' attributes successfully cleared (not System/Hidden)." "SUCCESS"
                } elseif ($backupFolderItem) {
                    Write-Log "Attrib.exe ran, but backup folder '$BackupDestinationPath' may still have System/Hidden attributes. Attributes: $($backupFolderItem.Attributes)" "WARN"
                } else {
                     Write-Log "Attrib.exe ran, but could not re-verify attributes for '$BackupDestinationPath'." "WARN"
                }
            } else {
                Write-Log "attrib.exe failed to clear attributes for '$BackupDestinationPath'. Exit Code: $($attribProcess.ExitCode). It may remain System/Hidden." "ERROR"
            }

        } else {
            Write-Log "Robocopy backup reported issues. Exit Code: $($process.ExitCode)." "ERROR"
            Write-Log "This is a Robocopy error code indicating problems with the copy operation." "WARN"
            if (Test-Path $RoboLogPath) {
                Write-Log "Robocopy log content from '$RoboLogPath':" "INFO"
                Get-Content $RoboLogPath | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
            } else {
                Write-Log "Robocopy log file NOT FOUND at '$RoboLogPath'. This often means Robocopy failed to parse arguments before creating the log." "ERROR"
            }
            $filesCopiedSuccessfully = $false
        }
    } catch {
        Write-Log "Exception occurred while trying to run Robocopy for backup: $($_.Exception.Message)" "ERROR"
        if (Test-Path $RoboLogPath) {
            Write-Log "Robocopy log content (from exception context) '$RoboLogPath':" "INFO"
            Get-Content $RoboLogPath | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
        } else {
             Write-Log "Robocopy log file NOT FOUND (from exception context) at '$RoboLogPath'." "ERROR"
        }
        $copyProcessRan = $false 
        $filesCopiedSuccessfully = $false
    } finally {
        Write-Log "Attempting cleanup of drive letter $tempLetter for Disk $($WinREPartitionObject.DiskNumber) Partition $($WinREPartitionObject.PartitionNumber)..." "INFO"
        $diskpartRemoveCmds = @(
            "select disk $($WinREPartitionObject.DiskNumber)",
            "select partition $($WinREPartitionObject.PartitionNumber)",
            "remove"
        )
        if (-not (Run-DiskpartScript -Commands $diskpartRemoveCmds)) {
            if (Get-Volume -DriveLetter $tempLetter -ErrorAction SilentlyContinue) {
                 Write-Log "Diskpart failed to remove drive letter $tempLetter. As the partition will be deleted next, this might be acceptable." "WARN"
            } else {
                 Write-Log "Drive letter $tempLetter is no longer assigned or was already removed." "INFO"
            }
        } else {
            Write-Log "Diskpart command to remove letter from original WinRE partition executed." "INFO"
        }
    }
    return ($copyProcessRan -and $filesCopiedSuccessfully)
}

function Disable-CurrentWinRE {
    Write-Log "Disabling current Windows RE..."
    reagentc /disable
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Windows RE disabled successfully." "SUCCESS"
        # Verify
        $reagentInfo = reagentc /info
        if (($reagentInfo | Where-Object { $_ -match "Windows RE status:" }) -match "Disabled") {
            Write-Log "Verification: Windows RE is Disabled." "SUCCESS"
            return $true
        } else {
            Write-Log "Verification failed: Windows RE still appears enabled after 'reagentc /disable'." "ERROR"
            $reagentInfo | ForEach-Object { Write-Log "  $_" }
            return $false
        }
    } else {
        Write-Log "reagentc /disable failed. Exit code: $LASTEXITCODE" "ERROR"
        reagentc /info | ForEach-Object { Write-Log "  $_" }
        return $false
    }
}

function Delete-RecoveryPartition {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$WinREPartitionObject
    )
    Write-Log "Deleting old recovery partition (Disk $($WinREPartitionObject.DiskNumber), Partition $($WinREPartitionObject.PartitionNumber))..."
    $diskpartDelete = @(
        "select disk $($WinREPartitionObject.DiskNumber)",
        "select partition $($WinREPartitionObject.PartitionNumber)",
        "delete partition override"
    )
    if (Run-DiskpartScript -Commands $diskpartDelete) {
        Write-Log "Old recovery partition deleted successfully." "SUCCESS"
        return $true
    } else {
        Write-Log "Failed to delete old recovery partition." "ERROR"
        return $false
    }
}
function Create-NewRecoveryPartitionOnOSDisk {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$OSDisk,
        [Parameter(Mandatory = $true)]
        [int]$RequiredSizeMB
    )
    Write-Log "Step: Creating new partition (Disk $($OSDisk.Number), Size ${RequiredSizeMB}MB, Label '$($global:NewRecoveryPartitionLabel)'). ID will be set later." "ACTION"

    $diskpartCreate = @(
        "select disk $($OSDisk.Number)",
        "create partition primary size=$RequiredSizeMB",
        "format fs=ntfs quick label=`"$global:NewRecoveryPartitionLabel`"" # Use final label now
    )

    if (-not (Run-DiskpartScript -Commands $diskpartCreate)) {
        Write-Log "DiskPart: Failed to create and format new partition." "ERROR"
        return $null
    }

    Write-Log "DiskPart: Create/format script reported success. Waiting for OS to update partition table (5 seconds)..." "INFO"
    Start-Sleep -Seconds 5

    Write-Log "Identifying newly created partition..." "INFO"
    $allPartitionsOnDisk = Get-Partition -DiskNumber $OSDisk.Number -ErrorAction SilentlyContinue
    
    if (-not $allPartitionsOnDisk) {
        Write-Log "Get-Partition returned NO PARTITIONS for Disk $($OSDisk.Number) after creation attempt. This is highly unusual." "ERROR"
        return $null
    }

    Write-Log "All partitions currently on Disk $($OSDisk.Number) (Target Size: ${RequiredSizeMB}MB, Target Label: '$($global:NewRecoveryPartitionLabel)'):" "INFO"
    $allPartitionsOnDisk | ForEach-Object {
        $calculatedSizeMB = [Math]::Round($_.Size / 1MB)
        $sizeMatchDebug = ([Math]::Abs($calculatedSizeMB - $RequiredSizeMB) -lt 50)
        $currentLabel = ""
        try { $currentLabel = (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } catch {}
        $labelMatchDebug = ($currentLabel -eq $global:NewRecoveryPartitionLabel)
        $logMessage = "  - PNum:$($_.PartitionNumber), Offset:$($_.Offset), SizeMB:$calculatedSizeMB (SizeMatch:$sizeMatchDebug), Type:'$($_.Type)', Label:'$currentLabel' (LabelMatch:$labelMatchDebug), GptType:'$($_.GptType)'"
        Write-Log $logMessage "INFO"
    }
    
    $newPartition = $null # Initialize

    # --- Attempt 1: Find by label and size (most reliable after format with label) ---
    Write-Log "Identification Attempt 1: Matching label '$($global:NewRecoveryPartitionLabel)' and size..." "INFO"
    # Use ForEach-Object to process and collect, then Sort-Object
    $candidatesAttempt1 = $allPartitionsOnDisk | ForEach-Object {
        $currentP = $_
        $vol = Get-Volume -Partition $currentP -ErrorAction SilentlyContinue
        if ($vol -and $vol.FileSystemLabel -eq $global:NewRecoveryPartitionLabel) {
            $partitionSizeMB = [Math]::Round($currentP.Size / 1MB)
            if (([Math]::Abs($partitionSizeMB - $RequiredSizeMB) -lt 50)) {
                Write-Log "    - PNum $($currentP.PartitionNumber) (Attempt 1): Candidate (Label and Size match)." "INFO"
                $currentP # Output to pipeline
            }
        }
    } | Sort-Object -Property Offset -Descending -ErrorAction SilentlyContinue

    if ($candidatesAttempt1) {
        $newPartition = if ($candidatesAttempt1 -is [array]) { $candidatesAttempt1[0] } else { $candidatesAttempt1 }
        Write-Log "DEBUG (Attempt 1): Identified partition based on label and size." "INFO"
    }

    # --- Attempt 2: If label match failed (e.g., label not set/read correctly), try by size and common types ---
    if (-not $newPartition) {
        Write-Log "Identification Attempt 1 (by label) failed or yielded no partition. Trying Attempt 2 (by size and common type)..." "WARN"
        $candidatesAttempt2 = $allPartitionsOnDisk | Where-Object {
            $partitionSizeMBLocal = [Math]::Round($_.Size / 1MB) # Use local var inside Where-Object
            $sizeMatchesLocal = ([Math]::Abs($partitionSizeMBLocal - $RequiredSizeMB) -lt 50)
            $typeMatchesLocal = ($_.Type -eq 'Basic data partition' -or $_.Type -eq 'Primary') # GPT 'Basic' or MBR 'Primary' before ID is set
            
            if ($sizeMatchesLocal -and $typeMatchesLocal) { Write-Log "    - PNum $($_.PartitionNumber) (Attempt 2): Candidate (Size and Basic/Primary Type match)." "INFO" }
            # elseif ($sizeMatchesLocal) { Write-Log "    - PNum $($_.PartitionNumber) (Attempt 2): Size matches, Type ($($_.Type)) not Basic/Primary." "INFO" }
            $sizeMatchesLocal -and $typeMatchesLocal
        } | Sort-Object -Property Offset -Descending -ErrorAction SilentlyContinue

        if ($candidatesAttempt2) {
            $newPartition = if ($candidatesAttempt2 -is [array]) { $candidatesAttempt2[0] } else { $candidatesAttempt2 }
            Write-Log "DEBUG (Attempt 2): Identified partition based on size and common type." "INFO"
        }
    }

    # --- Final Check ---
    if ($newPartition) {
        Write-Log "New partition (pre-ID set) successfully identified: Disk $($newPartition.DiskNumber), Partition $($newPartition.PartitionNumber), Size $([Math]::Round($newPartition.Size / 1MB))MB" "SUCCESS"
        return $newPartition
    } else {
        Write-Log "Could not definitively identify the newly created partition after all attempts." "ERROR"
        Write-Log "Please check Disk Management. The detailed partition list was logged above." "INFO"
        return $null
    }
}

function Set-RecoveryPartitionAttributes {
    param (
        [Parameter(Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimInstance]$PartitionObject,
        [Parameter(Mandatory=$true)]
        [string]$PartitionStyle
    )

    if (-not $PartitionObject) {
        Write-Log "Set-RecoveryPartitionAttributes: Received a null PartitionObject. Cannot proceed." "ERROR"
        return $false
    }

    Write-Log "Step: Setting Recovery Partition ID & Attributes (Disk $($PartitionObject.DiskNumber), Partition $($PartitionObject.PartitionNumber))..." "ACTION"

    $diskpartCmdsSetId = @(
        "select disk $($PartitionObject.DiskNumber)",
        "select partition $($PartitionObject.PartitionNumber)"
    )

    $expectedGptTypeGuid = [guid]'{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $expectedGptTypeStringNoBraces = $expectedGptTypeGuid.ToString('D') # XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    $expectedMbrType = 0x27
    $gptAttributes = "gpt attributes=0x8000000000000001"

    if ($PartitionStyle -eq "GPT") {
        $diskpartCmdsSetId += "set id=""$expectedGptTypeStringNoBraces"""
        Write-Log "Disk is GPT. Setting ID to '$expectedGptTypeStringNoBraces'."
    } elseif ($PartitionStyle -eq "MBR") {
        $diskpartCmdsSetId += "set id=$([string]::Format('{0:X2}', $expectedMbrType))"
        Write-Log "Disk is MBR. Setting ID to '$([string]::Format('0x{0:X2}', $expectedMbrType))'."
    } else {
        Write-Log "Unknown or unsupported partition style: '$PartitionStyle' for Disk $($PartitionObject.DiskNumber). Cannot set ID." "ERROR"
        return $false
    }

    if (-not (Run-DiskpartScript -Commands $diskpartCmdsSetId)) {
        Write-Log "DiskPart: Failed to set recovery partition ID." "ERROR"
        return $false
    }
    Write-Log "DiskPart: 'set id' command executed." "SUCCESS"
    Start-Sleep -Seconds 2

    if ($PartitionStyle -eq "GPT") {
        Write-Log "Disk is GPT. Setting GPT attributes to '$gptAttributes'."
        $diskpartCmdsSetAttrib = @(
            "select disk $($PartitionObject.DiskNumber)",
            "select partition $($PartitionObject.PartitionNumber)",
            $gptAttributes
        )
        if (-not (Run-DiskpartScript -Commands $diskpartCmdsSetAttrib)) {
            Write-Log "DiskPart: Failed to set GPT attributes for recovery partition." "WARN"
        } else {
            Write-Log "DiskPart: '$gptAttributes' command executed." "SUCCESS"
        }
        Start-Sleep -Seconds 2
    }

    Write-Log "Verifying partition ID and attributes after DiskPart operations. Waiting (5 seconds)..." "INFO"
    Start-Sleep -Seconds 5

    $updatedPartition = $null
    $attempts = 0
    $maxAttempts = 3
    
    while (-not $updatedPartition -and $attempts -lt $maxAttempts) {
        $attempts++
        Write-Log "Verification Attempt #$attempts (using Get-Partition) to fetch updated partition details..." "INFO"
        try {
            $updatedPartition = Get-Partition -DiskNumber $PartitionObject.DiskNumber -PartitionNumber $PartitionObject.PartitionNumber -ErrorAction Stop
            if ($updatedPartition) {
                Write-Log "Get-Partition: Successfully fetched partition details." "INFO"
            }
        } catch {
            Write-Log "Get-Partition Attempt #$attempts : Error: $($_.Exception.Message)." "WARN"
            if ($attempts -lt $maxAttempts) { Start-Sleep -Seconds 2 }
        }
    }

    $idCorrect = $false
    $attributesCorrect = ($PartitionStyle -ne "GPT") # Assume true for MBR, will be checked for GPT

    # --- Primary Verification via Get-Partition ---
    if ($updatedPartition) {
        if ($PartitionStyle -eq "GPT") {
            if ($updatedPartition.GptType -ne $null) {
                if ($updatedPartition.GptType -eq $expectedGptTypeGuid) {
                    $foundGptTypeStringForLog = if ($updatedPartition.GptType) { $updatedPartition.GptType.ToString('B') } else { "(null GptType property)" }
                    Write-Log "Get-Partition Verification: GPT ID MISMATCH. Expected: '$($expectedGptTypeGuid.ToString('B'))', Found: '$foundGptTypeStringForLog'." "WARN"
                } else {
                    Write-Log "Get-Partition Verification: GPT ID MISMATCH. Expected: '$($expectedGptTypeGuid.ToString('B'))', Found: '$($updatedPartition.GptType.ToString('B'))'." "WARN"
                }
            } else {
                Write-Log "Get-Partition Verification: GptType property is NULL. Cannot confirm ID with this method." "WARN"
            }
            # Attribute check via Get-Partition
            if ($updatedPartition.IsHidden) {
                Write-Log "Get-Partition Verification: Partition IS Hidden (consistent with attributes)." "INFO"
                $attributesCorrect = $true
            } else {
                Write-Log "Get-Partition Verification: Partition IS NOT Hidden." "WARN"
                $attributesCorrect = $false 
            }
        } elseif ($PartitionStyle -eq "MBR") {
            if ($updatedPartition.MbrType -eq $expectedMbrType) {
                Write-Log "Get-Partition Verification: MBR Type matches." "SUCCESS"
                $idCorrect = $true
            } else {
                Write-Log "Get-Partition Verification: MBR Type MISMATCH." "WARN"
            }
        }
    } else {
        Write-Log "Get-Partition Verification: Failed to fetch partition object. Cannot verify using this method." "ERROR"
    }

    # --- Secondary Verification via Diskpart (if Get-Partition was inconclusive for GPT ID) ---
    if ($PartitionStyle -eq "GPT" -and -not $idCorrect) {
        Write-Log "Secondary Verification (using Diskpart output) for GPT ID..." "INFO"
        $diskpartDetailCmds = @(
            "select disk $($PartitionObject.DiskNumber)",
            "select partition $($PartitionObject.PartitionNumber)",
            "detail partition"
        )
        $tempDetailScriptPath = Join-Path $env:TEMP "diskpart_detail_temp.txt"
        $tempDetailOutputPath = Join-Path $env:TEMP "diskpart_detail_out.txt"
        $diskpartDetailCmds | Out-File -FilePath $tempDetailScriptPath -Encoding ascii -Force
        
        # Diskpart output redirection is a bit tricky. We'll capture to a file.
        $dpProcess = Start-Process diskpart -ArgumentList "/s `"$tempDetailScriptPath`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $tempDetailOutputPath
        
        if ($dpProcess.ExitCode -eq 0 -and (Test-Path $tempDetailOutputPath)) {
            $detailOutput = Get-Content $tempDetailOutputPath
            Remove-Item $tempDetailScriptPath -ErrorAction SilentlyContinue
            Remove-Item $tempDetailOutputPath -ErrorAction SilentlyContinue

            $typeLine = $detailOutput | Where-Object { $_ -match "^\s*Type\s*:\s*([0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})" }
            if ($typeLine) {
                $foundGptIdString = ($typeLine -split ":")[1].Trim()
                Write-Log "Diskpart Detail Output: Found Type line: '$typeLine'. Parsed ID: '$foundGptIdString'." "INFO"
                if ($foundGptIdString -eq $expectedGptTypeStringNoBraces) {
                    Write-Log "Diskpart Detail Verification: GPT ID matches ('$foundGptIdString')." "SUCCESS"
                    $idCorrect = $true
                } else {
                    Write-Log "Diskpart Detail Verification: GPT ID MISMATCH. Expected: '$expectedGptTypeStringNoBraces', Found: '$foundGptIdString'." "ERROR"
                }
            } else {
                Write-Log "Diskpart Detail Verification: Could not find or parse 'Type' line from diskpart output." "WARN"
                # Write-Log "Diskpart detail output for review:`n$($detailOutput -join "`n")" "INFO" # Uncomment for deep debug
            }
        } else {
            Write-Log "Diskpart Detail Verification: Failed to execute diskpart or get output. ExitCode: $($dpProcess.ExitCode)" "ERROR"
            Remove-Item $tempDetailScriptPath -ErrorAction SilentlyContinue
            Remove-Item $tempDetailOutputPath -ErrorAction SilentlyContinue
        }
    }

    # --- Final Decision and User Prompt if Necessary ---
    if ($idCorrect -and $attributesCorrect) {
        Write-Log "Partition ID and relevant attributes appear correctly set based on verifications." "SUCCESS"
        return $true
    } else {
        Write-Log "Automated verification for Partition ID or Attributes failed or was inconclusive." "WARN"
        if ($PartitionStyle -eq "GPT") {
            Write-Log "Expected GPT ID: $expectedGptTypeStringNoBraces" "INFO"
            Write-Log "Expected GPT Attributes result in partition being Hidden." "INFO"
        } elseif ($PartitionStyle -eq "MBR") {
            Write-Log "Expected MBR Type: 0x27" "INFO"
        }
        
        Write-Log "Please MANUALLY VERIFY the partition settings using 'diskpart'." "ACTION"
        Write-Log "In diskpart: select disk $($PartitionObject.DiskNumber), then select partition $($PartitionObject.PartitionNumber), then 'detail partition'." "ACTION"
        
        $choice = Read-Host -Prompt "Based on your manual check, are the Partition ID and attributes correctly set for a recovery partition? (Yes/No)"
        if ($choice -match '^y(es)?$') {
            Write-Log "User confirmed partition settings are correct. Proceeding with caution." "WARN"
            return $true # Proceed based on user override
        } else {
            Write-Log "User indicated partition settings are NOT correct or chose not to proceed. Aborting attribute setup." "ERROR"
            return $false
        }
    }
}

function Restore-WinREDataToPartition {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$TargetPartition,
        [Parameter(Mandatory = $true)]
        [string]$SourceBackupPath
    )
    Write-Log "Restoring WinRE data to new partition (Disk $($TargetPartition.DiskNumber), Partition $($TargetPartition.PartitionNumber))..."
    if (-not (Test-Path $SourceBackupPath -PathType Container)) {
        Write-Log "Backup source path '$SourceBackupPath' does not exist or is not a folder." "ERROR"
        return $false
    }

    $tempLetter = Find-UnusedDriveLetter
    if (-not $tempLetter) { return $false }

    $diskpartAssign = @(
        "select disk $($TargetPartition.DiskNumber)",
        "select partition $($TargetPartition.PartitionNumber)",
        "assign letter=$tempLetter"
    )
    if (-not (Run-DiskpartScript -Commands $diskpartAssign)) {
        Write-Log "Failed to assign drive letter to the new recovery partition." "ERROR"
        return $false
    }
    Start-Sleep -Seconds 3 
     if (-not (Test-Path "$($tempLetter):")) {
        Write-Log "Drive letter $tempLetter was not successfully assigned to new partition or is not accessible." "ERROR"
        $diskpartRemoveErrorAssign = @(
            "select disk $($TargetPartition.DiskNumber)",
            "select partition $($TargetPartition.PartitionNumber)",
            "remove"
        )
        Run-DiskpartScript -Commands $diskpartRemoveErrorAssign 
        return $false
    }
    Write-Log "New recovery partition assigned to $tempLetter`:"
    
    $sourceRobo = $SourceBackupPath 
    $destinationRobo = "$($tempLetter):" 
    $RoboLogPathRestore = Join-Path $env:TEMP "robocopy_restore_WinRE_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    Write-Log "Copying files from '$sourceRobo' to '$destinationRobo' using robocopy..."
    
    $robocopyArgs = [System.Collections.Generic.List[string]]::new()
    $robocopyArgs.Add("`"$sourceRobo`"")
    $robocopyArgs.Add("`"$destinationRobo`"")
    $robocopyArgs.Add("*.*")
    $robocopyArgs.Add("/E")      
    $robocopyArgs.Add("/COPY:DATS")
    $robocopyArgs.Add("/DCOPY:T")  
    $robocopyArgs.Add("/XJ")       
    $robocopyArgs.Add("/R:1")
    $robocopyArgs.Add("/W:1")
    $robocopyArgs.Add("/NFL")
    $robocopyArgs.Add("/NDL")
    $robocopyArgs.Add("/NJH")
    $robocopyArgs.Add("/NJS")
    $robocopyArgs.Add("/NC")
    $robocopyArgs.Add("/NS")
    $robocopyArgs.Add("/NP")
    $robocopyArgs.Add("/LOG+:`"$RoboLogPathRestore`"")
    
    $copyProcessRan = $false
    $filesCopiedSuccessfully = $false
    try {
        Write-Log "Robocopy arguments being passed: $($robocopyArgs -join ' ')" "INFO"
        $process = Start-Process robocopy -ArgumentList $robocopyArgs.ToArray() -Wait -PassThru -WindowStyle Hidden
        $copyProcessRan = $true

        if ($process.ExitCode -lt 8) {
            Write-Log "Robocopy data restoration completed successfully (Exit Code: $($process.ExitCode))." "SUCCESS"
            $filesCopiedSuccessfully = $true
            if (Test-Path $RoboLogPathRestore) { 
                Write-Log "Robocopy log (success) from '$RoboLogPathRestore':" "INFO"
                Get-Content $RoboLogPathRestore | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
                Remove-Item $RoboLogPathRestore -ErrorAction SilentlyContinue -Force 
            }

            $expectedWinREPathOnNewPart = Join-Path -Path $destinationRobo -ChildPath $global:WinREFolderName
            if (-not (Test-Path (Join-Path $expectedWinREPathOnNewPart "winre.wim"))) {
                 Write-Log "winre.wim not found at expected location '$expectedWinREPathOnNewPart\winre.wim' after robocopy." "WARN"
                 Write-Log "This might cause issues with 'reagentc /setreimage'. Ensure your backup contains the 'Recovery\WindowsRE' structure if reagentc fails." "WARN"
            }
        } else {
            Write-Log "Error during Robocopy data restoration. Exit Code: $($process.ExitCode)." "ERROR"
            if (Test-Path $RoboLogPathRestore) {
                Write-Log "Robocopy log content from '$RoboLogPathRestore':" "INFO"
                Get-Content $RoboLogPathRestore | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
            } else {
                Write-Log "Robocopy log file NOT FOUND at '$RoboLogPathRestore'. This often means Robocopy failed to parse arguments before creating the log." "ERROR"
            }
            $filesCopiedSuccessfully = $false
        }
    } catch {
        Write-Log "Exception occurred while trying to run Robocopy for restore: $($_.Exception.Message)" "ERROR"
        if (Test-Path $RoboLogPathRestore) {
            Write-Log "Robocopy log content (from exception context) '$RoboLogPathRestore':" "INFO"
            Get-Content $RoboLogPathRestore | ForEach-Object { Write-Log "  ROBO-LOG: $_" "INFO" }
        } else {
            Write-Log "Robocopy log file NOT FOUND (from exception context) at '$RoboLogPathRestore'." "ERROR"
        }
        $copyProcessRan = $false
        $filesCopiedSuccessfully = $false
    } finally {
        Write-Log "Attempting cleanup of drive letter $tempLetter for Disk $($TargetPartition.DiskNumber) Partition $($TargetPartition.PartitionNumber)..." "INFO"
        $diskpartRemoveCmds = @(
            "select disk $($TargetPartition.DiskNumber)",
            "select partition $($TargetPartition.PartitionNumber)",
            "remove"
        )
        if (-not (Run-DiskpartScript -Commands $diskpartRemoveCmds)) {
            if (Get-Volume -DriveLetter $tempLetter -ErrorAction SilentlyContinue) {
                 Write-Log "Diskpart failed to remove drive letter $tempLetter from new recovery partition. Manual intervention may be required." "WARN"
            } else {
                 Write-Log "Drive letter $tempLetter is no longer assigned or was already removed from new recovery partition." "INFO"
            }
        } else {
            Write-Log "Diskpart command to remove letter from new recovery partition executed." "INFO"
        }
    }
    return ($copyProcessRan -and $filesCopiedSuccessfully)
}

function Setup-NewWinRE {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$NewRecoveryPartition,
        [Parameter(Mandatory = $true)]
        [string]$OSDriveLetter = "C"
    )
    Write-Log "Setting up Windows RE on the new partition..."
    $tempLetter = Find-UnusedDriveLetter
    if (-not $tempLetter) { return $false }

    $diskpartAssign = @(
        "select disk $($NewRecoveryPartition.DiskNumber)",
        "select partition $($NewRecoveryPartition.PartitionNumber)",
        "assign letter=$tempLetter"
    )
    if (-not (Run-DiskpartScript -Commands $diskpartAssign)) {
        Write-Log "Failed to assign temp drive letter for reagentc setup." "ERROR"
        return $false
    }
    Start-Sleep -Seconds 2
    if (-not (Test-Path "$($tempLetter):")) {
        Write-Log "Drive letter $tempLetter was not successfully assigned for reagentc or is not accessible." "ERROR"
        Run-DiskpartScript -Commands ("select disk $($NewRecoveryPartition.DiskNumber)","select partition $($NewRecoveryPartition.PartitionNumber)","remove letter=$tempLetter")
        return $false
    }


    $winrePathOnNewPart = Join-Path -Path "$($tempLetter):" -ChildPath $global:WinREFolderName
    Write-Log "WinRE path for reagentc: $winrePathOnNewPart"
    Write-Log "Target OS: $($OSDriveLetter):\Windows"

    if (-not (Test-Path (Join-Path $winrePathOnNewPart "winre.wim"))) {
         Write-Log "winre.wim not found at '$winrePathOnNewPart\winre.wim'. Cannot set up WinRE." "ERROR"
         # Attempt removal of letter
         Run-DiskpartScript -Commands ("select volume $tempLetter", "remove")
         return $false
    }

    Write-Log "Running: reagentc /setreimage /path `"$winrePathOnNewPart`" /target $($OSDriveLetter):\Windows"
    reagentc /setreimage /path "$winrePathOnNewPart" /target "$($OSDriveLetter):\Windows"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reagentc /setreimage failed. Exit code: $LASTEXITCODE" "ERROR"
        reagentc /info | ForEach-Object { Write-Log "  $_" }
        # Attempt removal of letter
        Run-DiskpartScript -Commands ("select volume $tempLetter", "remove")
        return $false
    }
    Write-Log "reagentc /setreimage successful." "SUCCESS"

    Write-Log "Running: reagentc /enable"
    reagentc /enable
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reagentc /enable failed. Exit code: $LASTEXITCODE" "ERROR"
        reagentc /info | ForEach-Object { Write-Log "  $_" }
        # Attempt removal of letter
        Run-DiskpartScript -Commands ("select volume $tempLetter", "remove")
        return $false
    }
    Write-Log "reagentc /enable successful." "SUCCESS"

    # Verify
    $reagentInfo = reagentc /info
    $reagentOutput = $reagentInfo -join "`n"
    Write-Log "Final reagentc /info output:`n$reagentOutput"

    $statusLine = $reagentInfo | Where-Object { $_ -match "Windows RE status:" }
    $locationLine = $reagentInfo | Where-Object { $_ -match "Windows RE location:" }

    if (($statusLine -match "Enabled") -and ($locationLine -match "harddisk$($NewRecoveryPartition.DiskNumber)\\partition$($NewRecoveryPartition.PartitionNumber)")) {
        Write-Log "Verification: Windows RE is Enabled and points to the new partition." "SUCCESS"
        $finalSuccess = $true
    } else {
        Write-Log "Verification failed: Windows RE status or location is not as expected." "ERROR"
        $finalSuccess = $false
    }

    $diskpartRemove = @(
        "select volume $tempLetter",
        "remove"
    )
    if (-not (Run-DiskpartScript -Commands $diskpartRemove)) {
        Write-Log "Failed to remove drive letter $tempLetter. Manual intervention may be required." "WARN"
    } else {
        Write-Log "Temp Drive letter $tempLetter removed."
    }

    return $finalSuccess
}


# --- Main Script Logic ---
Test-Admin

$OSDisk = Get-OSDisk
if (-not $OSDisk) {
    Write-Log "Exiting due to OS Disk identification failure." "ACTION"
    exit 1
}

# Validate parameters based on mode
if ($Mode -eq "RestoreOnly") {
    if (-not $WinREBackupPathRestoreMode) {
        Write-Log "Parameter -WinREBackupPathRestoreMode is required when Mode is 'RestoreOnly'." "ERROR"
        exit 1
    }
    if (-not (Test-Path $WinREBackupPathRestoreMode -PathType Container)) {
        Write-Log "Provided WinRE backup path '$WinREBackupPathRestoreMode' does not exist or is not a folder." "ERROR"
        exit 1
    }
    Write-Log "Mode: RestoreOnly. Backup Source: $WinREBackupPathRestoreMode"
} else { # Full Mode
    Write-Log "Mode: Full. Backup will be created at: $WinREBackupPathFullMode"
}


$OriginalWinREInfo = Get-WinREInfo -OSDisk $OSDisk
if ($Mode -eq "Full") {
    if (-not $OriginalWinREInfo -or -not $OriginalWinREInfo.IsEnabled) {
        Write-Log "Could not get information about the current (enabled) WinRE partition or it's not on the OS disk." "ERROR"
        Write-Log "This script in 'Full' mode requires an existing, enabled WinRE on the OS disk to backup." "ACTION"
        exit 1
    }
    Write-Log "Original WinRE Partition Size: $($OriginalWinREInfo.OriginalSizeMB) MB"
    $RequiredRecoveryPartitionSizeMB = $OriginalWinREInfo.OriginalSizeMB
    if ($RequiredRecoveryPartitionSizeMB -lt $global:MinRecoveryPartitionSpaceMB) {
        Write-Log "Original WinRE partition size ($($RequiredRecoveryPartitionSizeMB)MB) is less than minimum recommended ($($global:MinRecoveryPartitionSpaceMB)MB). Using minimum for new partition." "WARN"
        $RequiredRecoveryPartitionSizeMB = $global:MinRecoveryPartitionSpaceMB
    }

    Write-Log "--- Starting WinRE Relocation Process (Full) ---" "ACTION"

    # 1. Backup Existing WinRE
    if (-not (Backup-WinREPartition -WinREPartitionObject $OriginalWinREInfo.PartitionObject -BackupDestinationPath $WinREBackupPathFullMode)) {
        Write-Log "WinRE backup failed. Aborting." "ERROR"
        exit 1
    }
    $EffectiveBackupPath = $WinREBackupPathFullMode

    # 2. Disable WinRE
    if (-not (Disable-CurrentWinRE)) {
        Write-Log "Failed to disable WinRE. This is critical. Aborting." "ERROR"
        Write-Log "You may need to manually check 'reagentc /info' and disk management." "ACTION"
        exit 1
    }

    # 3. Delete Old Recovery Partition
    if (-not (Delete-RecoveryPartition -WinREPartitionObject $OriginalWinREInfo.PartitionObject)) {
        Write-Log "Failed to delete the old recovery partition. Aborting." "ERROR"
        Write-Log "The system might be in an inconsistent state. Check Disk Management and reagentc /info." "ACTION"
        exit 1
    }

    # 4. User Interaction for C: Drive Expansion
    Write-Log "-----------------------------------------------------------------------" "ACTION"
    Write-Log "The old recovery partition has been deleted." "SUCCESS"
    Write-Log "ACTION REQUIRED: Please manually expand your C: drive now using Disk Management (diskmgmt.msc)." "ACTION"
    Write-Log "IMPORTANT: Leave at least $RequiredRecoveryPartitionSizeMB MB of UNALLOCATED space at the END of Disk $($OSDisk.Number) for the new recovery partition." "ACTION"
    Write-Log "-----------------------------------------------------------------------" "ACTION"
    Read-Host -Prompt "Press Enter to continue AFTER you have expanded C: and left space..."

} elseif ($Mode -eq "RestoreOnly") {
    Write-Log "--- Starting WinRE Restoration Process (RestoreOnly) ---" "ACTION"
    Write-Log "Please ensure you have ALREADY EXPANDED C: and left unallocated space at the end of Disk $($OSDisk.Number)." "ACTION"
    
    $RequiredRecoveryPartitionSizeMB = $global:MinRecoveryPartitionSpaceMB # Default
    $userInputCorrected = $false

    while (-not $userInputCorrected) {
        $userSizeInputRaw = Read-Host -Prompt "Enter the approximate size (in MB) of the unallocated space you left for the new recovery partition (e.g., 550, 750MB, 1GB). Minimum $global:MinRecoveryPartitionSpaceMB MB"
        
        $numericPart = $userSizeInputRaw -replace '(?i)\s*(MB|GB)$' # Remove optional MB/GB suffix and any preceding space
        $multiplier = 1

        if ($userSizeInputRaw -match '(?i)GB$') {
            $multiplier = 1024
        }

        if (($numericPart -as [double]) -ne $null) { # Check if it's a number after stripping suffix
            $calculatedSizeMB = [Math]::Floor([double]$numericPart * $multiplier) # Use Floor to get an integer MB value

            if ($calculatedSizeMB -ge $global:MinRecoveryPartitionSpaceMB) {
                $RequiredRecoveryPartitionSizeMB = [int]$calculatedSizeMB # Cast to int for diskpart
                Write-Log "Will attempt to create a new recovery partition of $RequiredRecoveryPartitionSizeMB MB."
                $userInputCorrected = $true
            } else {
                Write-Log "Input '$userSizeInputRaw' ($calculatedSizeMB MB) is less than the minimum required $global:MinRecoveryPartitionSpaceMB MB. Please try again." "WARN"
            }
        } else {
            Write-Log "Invalid input '$userSizeInputRaw'. Please enter a number (e.g., 550), or a number followed by MB or GB (e.g., 750MB, 1GB)." "WARN"
        }
    }
    $EffectiveBackupPath = $WinREBackupPathRestoreMode
}


# --- Common Steps for Full (after C: expand) and RestoreOnly ---

# 5. Create New Recovery Partition
Write-Log "--- Stage: Creating New Recovery Partition ---" "ACTION"
$NewRecoveryPartition = Create-NewRecoveryPartitionOnOSDisk -OSDisk $OSDisk -RequiredSizeMB $RequiredRecoveryPartitionSizeMB
if (-not $NewRecoveryPartition) {
    Write-Log "Failed to create the new recovery partition. Aborting." "ERROR"
    Write-Log "Check Disk Management for the state of Disk $($OSDisk.Number)." "ACTION"
    exit 1
}

# 6. Restore Data to New Partition
Write-Log "--- Stage: Restoring WinRE Data ---" "ACTION"
if (-not (Restore-WinREDataToPartition -TargetPartition $NewRecoveryPartition -SourceBackupPath $EffectiveBackupPath)) {
    Write-Log "Failed to restore WinRE data to the new partition. Aborting." "ERROR"
    Write-Log "The new partition exists but may be empty or incomplete. Details: $($NewRecoveryPartition | Format-List | Out-String)" "ACTION"
    # Consider deleting the newly created (but now problematic) partition
    exit 1
}

# Step 6.5: Set Recovery Partition Attributes (ID)
Write-Log "--- Stage: Setting Recovery Partition Attributes (ID) ---" "ACTION"
$osDiskActual = Get-Disk -Number $OSDisk.Number 
$osDiskPartitionStyle = $osDiskActual.PartitionStyle
if (-not (Set-RecoveryPartitionAttributes -PartitionObject $NewRecoveryPartition -PartitionStyle $osDiskPartitionStyle)) {
    Write-Log "Failed to set recovery partition attributes (ID). WinRE setup might fail or the partition may not be recognized correctly." "ERROR"
    Write-Log "You may need to manually set the partition ID using diskpart. For GPT: 'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac'. For MBR: 'set id=27'." "ACTION"
    exit 1
}

# 7. Setup WinRE using reagentc
Write-Log "--- Stage: Setting up WinRE with reagentc ---" "ACTION"
# Re-fetch the partition object as its attributes (like GptType/MbrType) have changed and reagentc might rely on the OS seeing this.
$FinalizedRecoveryPartition = Get-Partition -DiskNumber $NewRecoveryPartition.DiskNumber -PartitionNumber $NewRecoveryPartition.PartitionNumber
if (-not $FinalizedRecoveryPartition) {
    Write-Log "Critical error: Could not re-fetch the recovery partition object after setting its ID. Cannot proceed with reagentc." "ERROR"
    exit 1
}

if (-not (Setup-NewWinRE -NewRecoveryPartition $FinalizedRecoveryPartition -OSDriveLetter "C")) {
    Write-Log "Failed to setup WinRE on the new partition using reagentc." "ERROR"
    Write-Log "The data should be restored, and ID set, but WinRE is not active. Check 'reagentc /info'." "ACTION"
    Write-Log "New partition details: Disk $($FinalizedRecoveryPartition.DiskNumber), Partition $($FinalizedRecoveryPartition.PartitionNumber)" "INFO"
    exit 1
}

Write-Log "-----------------------------------------------------------------------" "SUCCESS"
Write-Log "WinRE Relocation/Restoration Process Completed Successfully!" "SUCCESS"
Write-Log "Final WinRE Status:" "INFO"
reagentc /info | ForEach-Object { Write-Log "  $_" "INFO" }
Write-Log "-----------------------------------------------------------------------" "SUCCESS"

if ($Mode -eq "Full") {
    Write-Log "Backup of original WinRE is available at: $EffectiveBackupPath" "INFO"
}