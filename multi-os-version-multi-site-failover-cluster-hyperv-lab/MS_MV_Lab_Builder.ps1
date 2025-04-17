<#
.SYNOPSIS
Automates the creation of multiple Hyper-V lab environments based on template VHDX files.

.DESCRIPTION
This script iterates through specified Windows Server VHDX template files (e.g., 2016.vhdx, 2019.vhdx, 2022.vhdx).
For each template, it creates a distinct lab environment simulating a multi-site configuration.
Each environment includes dedicated directories, internal virtual switches, and virtual machines (DC, Nodes, iSCSI Target, Gateway)
configured with specific resources and network connections. VM VHDX files are copied from the template
and renamed for each VM.

.REQUIREMENTS
- Windows Operating System with Hyper-V role enabled.
- PowerShell 5.1 or later.
- Hyper-V PowerShell Module installed (usually included with the Hyper-V role).
- Script must be run with Administrator privileges.
- Source VHDX template files must exist at the specified location.
- Target base drive must exist and have sufficient space.

.INPUTS
- Source VHDX template files: Defined in the $SourceBaseNames array.
- Location of source VHDX files: Defined in the $SourceVHDXLocation variable.
- Base drive for lab environments: Defined in the $LabBaseDrive variable.

.OUTPUTS
- Creates directories, Hyper-V virtual switches, and virtual machines.
- Outputs progress messages to the console.

.EXAMPLE
.\Create-HyperVLabEnvironments.ps1
Runs the script with the predefined settings. Ensure the variables $SourceVHDXLocation, $LabBaseDrive, and $SourceBaseNames are set correctly before execution.

.NOTES
Version: 1.2 (Added iSCSI Target Server per site)
Author: Asher Le
Date:    2025-04-14
Ensure the source VHDX templates are generalized (Sysprep'd) for best results.
The script includes checks for existing items (directories, switches, VMs) and will skip creation if they already exist, issuing a warning.
#>

#region Script Requirements Check
# Check for Administrator Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run with Administrator privileges." -ErrorAction Stop
}

# Check if Hyper-V Module is available
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Error "Hyper-V PowerShell module is not available. Please ensure the Hyper-V role is installed." -ErrorAction Stop
}
#endregion

#region Configuration Variables
# --- INPUTS ---
[string]$SourceVHDXLocation = "C:\template\"
[string]$LabBaseDrive = "L:\"
[string[]]$SourceBaseNames = @("2016", "2019", "2022") # Base names derived from VHDX files (without extension)

# --- VM Configuration ---
[long]$DCMemory = 2GB
[long]$NodeMemory = 4GB
[long]$iSCSIMemory = 2GB # Memory for the iSCSI Target server
[long]$GatewayMemory = 2GB
[int]$VMGeneration = 2
#endregion

#region Main Script Logic

Write-Host "Starting Hyper-V Lab Environment Creation Process..." -ForegroundColor Cyan

# Iterate through each specified base name (e.g., "2016", "2019", "2022")
foreach ($BaseName in $SourceBaseNames) {
    Write-Host "--------------------------------------------------" -ForegroundColor Cyan
    Write-Host "Processing Lab Environment for Base: $BaseName" -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Cyan

    # --- 1. Define Paths ---
    $SourceVHDXPath = Join-Path -Path $SourceVHDXLocation -ChildPath "$($BaseName).vhdx"
    $LabBasePath = Join-Path -Path $LabBaseDrive -ChildPath "${BaseName}_Lab"
    $Site1Path = Join-Path -Path $LabBasePath -ChildPath "Site_1"
    $Site2Path = Join-Path -Path $LabBasePath -ChildPath "Site_2"
    $Site3Path = Join-Path -Path $LabBasePath -ChildPath "Site_3"
    $GatewayPath = Join-Path -Path $LabBasePath -ChildPath "GateWay"

    Write-Host "Verifying Source Template VHDX: $SourceVHDXPath"
    if (-not (Test-Path -Path $SourceVHDXPath -PathType Leaf)) {
        Write-Warning "Source VHDX file not found for $BaseName at $SourceVHDXPath. Skipping this environment."
        continue # Skip to the next BaseName in the loop
    }

    # --- 2. Create Directory Structure ---
    Write-Host "Creating directory structure for $LabBasePath..."
    $DirectoriesToCreate = @($LabBasePath, $Site1Path, $Site2Path, $Site3Path, $GatewayPath)
    foreach ($DirPath in $DirectoriesToCreate) {
        if (-not (Test-Path -Path $DirPath)) {
            Write-Host "Creating directory: $DirPath"
            try {
                New-Item -ItemType Directory -Path $DirPath -Force -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Error "Failed to create directory $DirPath. Error: $($_.Exception.Message)"
                Write-Warning "Stopping processing for $BaseName due to directory creation failure."
                continue 2 # Continue to the next iteration of the outer foreach loop
            }
        } else {
            Write-Host "Directory already exists: $DirPath" -ForegroundColor Yellow
        }
    }

    # --- 3. Create Virtual Switches ---
    Write-Host "Creating Internal Virtual Switches for $BaseName..."
    for ($SiteNumber = 1; $SiteNumber -le 3; $SiteNumber++) {
        $SwitchName = "${BaseName}_Site_${SiteNumber}"
        Write-Host "Checking for Virtual Switch: $SwitchName"
        $ExistingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if (-not $ExistingSwitch) {
            Write-Host "Creating Internal Virtual Switch: $SwitchName"
            try {
                New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop
            }
            catch {
                Write-Error "Failed to create Virtual Switch $SwitchName. Error: $($_.Exception.Message)"
                # Optional: Decide whether to stop or continue
            }
        } else {
            Write-Host "Virtual Switch '$SwitchName' already exists." -ForegroundColor Yellow
        }
    }

    # --- 4. Create Virtual Machines ---
    Write-Host "Creating Virtual Machines for $BaseName Lab..."

    # --- Site VMs (DC, Node1, Node2, iSCSI for Sites 1, 2, 3) ---
    for ($SiteNumber = 1; $SiteNumber -le 3; $SiteNumber++) {
        $CurrentSitePath = Join-Path -Path $LabBasePath -ChildPath "Site_$SiteNumber"
        $CurrentSwitchName = "${BaseName}_Site_${SiteNumber}"

        # Define VM configurations for the current site including the new iSCSI server
        $SiteVMs = @(
            @{ NameSuffix = "DC";    Memory = $DCMemory;    NestedVirt = $false },
            @{ NameSuffix = "Node_1"; Memory = $NodeMemory; NestedVirt = $true  },
            @{ NameSuffix = "Node_2"; Memory = $NodeMemory; NestedVirt = $true  },
            @{ NameSuffix = "iSCSI"; Memory = $iSCSIMemory; NestedVirt = $false } # Added iSCSI Server Configuration
        )

        foreach ($VMConfig in $SiteVMs) {
            $VMName = "${BaseName}_Site_${SiteNumber}_$($VMConfig.NameSuffix)"
            $TargetVHDXPath = Join-Path -Path $CurrentSitePath -ChildPath "${VMName}.vhdx"

            Write-Host "Checking for VM: $VMName"
            $ExistingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue

            if (-not $ExistingVM) {
                Write-Host "Creating VM: $VMName"

                # Copy the VHDX template
                Write-Host "Copying template VHDX to $TargetVHDXPath..."
                try {
                    Copy-Item -Path $SourceVHDXPath -Destination $TargetVHDXPath -Force -ErrorAction Stop
                }
                catch {
                    Write-Error "Failed to copy VHDX for $VMName from $SourceVHDXPath. Error: $($_.Exception.Message)"
                    Write-Warning "Skipping creation of VM $VMName."
                    continue # Skip to the next VM in the inner loop
                }

                # Create the VM
                Write-Host "Creating VM $VMName in path $CurrentSitePath, connecting to $CurrentSwitchName..."
                try {
                   # Create VM and connect to the site switch directly
                   $NewVM = New-VM -Name $VMName `
                              -Generation $VMGeneration `
                              -MemoryStartupBytes $VMConfig.Memory `
                              -VHDPath $TargetVHDXPath `
                              -Path $CurrentSitePath `
                              -SwitchName $CurrentSwitchName `
                              -ErrorAction Stop

                   # Enable Nested Virtualization if required (only for Nodes)
                   if ($VMConfig.NestedVirt) {
                       Write-Host "Enabling Nested Virtualization for $VMName..."
                       Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction Stop
                   }
                   Write-Host "VM $VMName created successfully." -ForegroundColor Green
                }
                catch {
                    Write-Error "Failed to create VM $VMName. Error: $($_.Exception.Message)"
                    # Clean up copied VHDX if VM creation failed
                    if (Test-Path $TargetVHDXPath -PathType Leaf) {
                        Write-Warning "Attempting cleanup: Removing copied VHDX $TargetVHDXPath for failed VM $VMName"
                        Remove-Item $TargetVHDXPath -Force -ErrorAction SilentlyContinue
                    }
                }
            } else {
                Write-Host "VM '$VMName' already exists. Skipping creation." -ForegroundColor Yellow
                # Optional: Check/enable nested virt on existing Nodes if needed
                 if ($VMConfig.NestedVirt) {
                    $ProcSettings = Get-VMProcessor -VMName $VMName -ErrorAction SilentlyContinue
                    if ($ProcSettings -and (-not $ProcSettings.ExposeVirtualizationExtensions)) {
                         Write-Host "Enabling Nested Virtualization for existing VM $VMName..."
                         Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction SilentlyContinue
                    }
                 }
            }
            Write-Host "---" # Separator between VMs within a site
        } # End foreach VMConfig in SiteVMs
    } # End for SiteNumber

    # --- Gateway VM ---
    $VMName = "${BaseName}_GateWay"
    $TargetVHDXPath = Join-Path -Path $GatewayPath -ChildPath "${VMName}.vhdx"

    Write-Host "Checking for Gateway VM: $VMName"
    $ExistingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue

    if (-not $ExistingVM) {
        Write-Host "Creating Gateway VM: $VMName"

        # Copy the VHDX template FIRST
        Write-Host "Copying template VHDX to $TargetVHDXPath..."
        try {
            Copy-Item -Path $SourceVHDXPath -Destination $TargetVHDXPath -Force -ErrorAction Stop
        }
        catch {
            Write-Error "Failed to copy VHDX for $VMName from $SourceVHDXPath. Error: $($_.Exception.Message)"
            Write-Warning "Skipping creation of VM $VMName."
            continue # Skip the rest of the Gateway VM creation for this BaseName
        }

        # Create the VM configuration without VHD attached initially
        Write-Host "Creating VM $VMName shell in path $GatewayPath..."
        try {
            # Step 1: Create the VM Shell using -NoVHD
            $NewVM = New-VM -Name $VMName `
                      -Generation $VMGeneration `
                      -MemoryStartupBytes $GatewayMemory `
                      -Path $GatewayPath `
                      -NoVHD `
                      -ErrorAction Stop

            # Step 2: Attach the previously copied VHDX
            Write-Host "Attaching VHDX $TargetVHDXPath to $VMName..."
            Add-VMHardDiskDrive -VMName $VMName -Path $TargetVHDXPath -ErrorAction Stop

            # Step 3: Remove default network adapter (if any was added)
            Write-Host "Ensuring no default network adapters exist on $VMName..."
            Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter -ErrorAction SilentlyContinue

            # Step 4: Add and Connect the specific Network Adapters
            Write-Host "Adding and connecting network adapters for $VMName..."
            $AdapterSiteMap = @{
                "NIC_Site_1" = "${BaseName}_Site_1"
                "NIC_Site_2" = "${BaseName}_Site_2"
                "NIC_Site_3" = "${BaseName}_Site_3"
            }
            foreach ($AdapterName in $AdapterSiteMap.Keys) {
                $TargetSwitch = $AdapterSiteMap[$AdapterName]
                Write-Host "Adding adapter '$AdapterName' and connecting to '$TargetSwitch'..."
                Add-VMNetworkAdapter -VMName $VMName -Name $AdapterName -SwitchName $TargetSwitch -ErrorAction Stop
            }
             Write-Host "Gateway VM $VMName created and configured successfully." -ForegroundColor Green

        }
        catch {
            Write-Error "Failed to create or configure Gateway VM $VMName. Error: $($_.Exception.Message)"
            # Cleanup partially created resources if error occurred
             Write-Warning "Attempting cleanup for failed $VMName creation..."
            if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
                Write-Host "Removing partially created VM: $VMName"
                Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $TargetVHDXPath -PathType Leaf) {
                 Write-Host "Removing copied VHDX: $TargetVHDXPath"
                 Remove-Item $TargetVHDXPath -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host "VM '$VMName' already exists. Skipping creation." -ForegroundColor Yellow
    }

    Write-Host "Finished processing Lab Environment for Base: $BaseName" -ForegroundColor Green

} # End foreach BaseName

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Hyper-V Lab Environment Creation Process Completed." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

#endregion