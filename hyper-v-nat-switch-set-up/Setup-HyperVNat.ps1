<#
.SYNOPSIS
Creates a Hyper-V Virtual Switch and configures it for Network Address Translation (NAT).

.DESCRIPTION
This script automates the setup of a NAT network on a Hyper-V host.
It performs the following actions:
1. Checks for administrative privileges.
2. Checks if a NetNat configuration already exists. If so, prompts the user to remove it.
3. Checks if a Virtual Switch with the default name 'NetNat' exists. If so, prompts for an alternative name.
4. Creates an 'Internal' type Virtual Switch with the specified name.
5. Finds the network adapter associated with the newly created switch.
6. Assigns a static IP address (default: 192.168.1.1/24) to the switch's adapter, serving as the gateway.
7. Creates the NetNat configuration linked to the IP subnet.
8. Reports progress throughout the process.
9. Provides a summary of the created resources and configuration details for VMs.

.NOTES
Author: Asher Le
Date:   2025-04-23
Requires: Hyper-V PowerShell Module, Administrator privileges.
#>

#Requires -Modules Hyper-V
#Requires -RunAsAdministrator

# --- Configuration ---
$DefaultSwitchName = "NetNat"
$IpAddress = "192.168.1.1"
$PrefixLength = 24 # Corresponds to subnet mask 255.255.255.0
$NatSubnet = "192.168.1.0/$PrefixLength"
$NatName = "HyperVNatNetwork" # Internal name for the NetNat object

# --- Script Variables ---
$ScriptSteps = @() # Array to hold summary steps
$ErrorOccurred = $false
$FinalSwitchName = $DefaultSwitchName
$NatRemoved = $false
$NatCreated = $false
$SwitchCreated = $false
$IpConfigured = $false

# --- Helper Functions ---
function Log-Step {
    param([string]$Message, [string]$Type = "Info")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "[$Timestamp] $Message"
    Write-Host $FormattedMessage
    $ScriptSteps += $FormattedMessage
}

function Log-Error {
    param([string]$Message, [System.Exception]$Exception = $null)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ErrorMessage = "[$Timestamp] ERROR: $Message"
    if ($Exception) {
        $ErrorMessage += " Details: $($Exception.Message)"
    }
    Write-Host $ErrorMessage -ForegroundColor Red
    $ScriptSteps += $ErrorMessage
    $global:ErrorOccurred = $true
}

# --- Main Script Logic ---

Log-Step "Starting NAT Network setup script."

# 1. Check for Admin Privileges (Handled by #Requires -RunAsAdministrator)
Log-Step "Checked for Administrator privileges: Granted."

# 2. Check for existing NetNat
Log-Step "Checking for existing NetNat configurations..."
try {
    $existingNat = Get-NetNat -ErrorAction SilentlyContinue
    if ($existingNat) {
        Log-Step "Found existing NetNat configuration: '$($existingNat.Name)' using subnet '$($existingNat.InternalIPInterfaceAddressPrefix)'." -Type "Warning"
        Write-Host "WARNING: An existing NetNat configuration was found." -ForegroundColor Yellow

        $choice = Read-Host "Do you want to REMOVE the existing NetNat ('$($existingNat.Name)') and proceed? (y/n)"
        if ($choice -eq 'y') {
            Log-Step "User chose to remove the existing NetNat."
            try {
                Write-Host "Attempting to remove existing NetNat '$($existingNat.Name)'..."
                Remove-NetNat -Name $existingNat.Name -Confirm:$false -ErrorAction Stop
                Log-Step "Successfully removed existing NetNat '$($existingNat.Name)'."
                $NatRemoved = $true
            } catch {
                Log-Error "Failed to remove existing NetNat '$($existingNat.Name)'." $_.Exception
                # Stop the script as we cannot proceed reliably
                return
            }
        } else {
            Log-Step "User chose not to remove the existing NetNat. Script aborted."
            $ErrorOccurred = $true # Treat as an error/stop condition for summary
            return
        }
    } else {
        Log-Step "No existing NetNat configuration found. Proceeding."
    }
} catch {
    Log-Error "An error occurred while checking for NetNat." $_.Exception
    return # Stop script on unexpected error
}

# 3. Check for existing VMSwitch
Log-Step "Checking for existing Virtual Switch named '$FinalSwitchName'..."
try {
    $existingSwitch = Get-VMSwitch -Name $FinalSwitchName -ErrorAction SilentlyContinue
    while ($existingSwitch) {
        Log-Step "Virtual Switch named '$FinalSwitchName' already exists." -Type "Warning"
        Write-Host "WARNING: A Virtual Switch named '$FinalSwitchName' already exists." -ForegroundColor Yellow
        $newSwitchName = Read-Host "Please enter an alternative name for the new switch, or press Enter to abort"

        if ([string]::IsNullOrWhiteSpace($newSwitchName)) {
            Log-Step "User aborted script when prompted for alternative switch name."
            $ErrorOccurred = $true
            return
        }

        # Check if the *new* name is also taken
        if (Get-VMSwitch -Name $newSwitchName -ErrorAction SilentlyContinue) {
            Log-Step "The alternative name '$newSwitchName' is also already in use. Please try again." -Type "Warning"
            Write-Host "WARNING: The name '$newSwitchName' is also in use." -ForegroundColor Yellow
            $existingSwitch = $true # Force loop to continue
        } else {
            Log-Step "User provided alternative switch name: '$newSwitchName'."
            $FinalSwitchName = $newSwitchName
            $existingSwitch = $null # Clear the flag to exit the loop
        }
    }
    Log-Step "Using '$FinalSwitchName' as the Virtual Switch name."

} catch {
    Log-Error "An error occurred while checking for the Virtual Switch." $_.Exception
    return
}


# 4. Create the Virtual Switch
Log-Step "Attempting to create Virtual Switch '$FinalSwitchName' (Type: Internal)..."
try {
    New-VMSwitch -Name $FinalSwitchName -SwitchType Internal -ErrorAction Stop
    Log-Step "Successfully created Virtual Switch '$FinalSwitchName'."
    $SwitchCreated = $true
} catch {
    Log-Error "Failed to create Virtual Switch '$FinalSwitchName'." $_.Exception
    return # Cannot proceed without the switch
}

# 5. Get the Network Adapter for the Switch by Name Convention
$TargetAdapterName = "vEthernet ($FinalSwitchName)" # Construct the expected adapter name based on the chosen switch name
Log-Step "Attempting to retrieve the network adapter named '$TargetAdapterName'..."
$adapter = $null
try {
    # Wait a moment for the adapter to be fully available and named correctly
    # This is important as the adapter registration might take a few seconds after switch creation.
    Log-Step "Waiting a few seconds for adapter '$TargetAdapterName' to register..."
    Start-Sleep -Seconds 5 # Adjust sleep time if needed, 5 is usually sufficient

    # Attempt to get the adapter directly by its expected name
    $adapter = Get-NetAdapter -Name $TargetAdapterName -ErrorAction Stop

    # Check if we successfully got an adapter object (ErrorAction Stop should catch failure, but double-checking is safe)
    if ($adapter) {
        Log-Step "Successfully found network adapter: '$($adapter.Name)' (Interface Index: $($adapter.InterfaceIndex))."
    } else {
         # This path should ideally not be reached if ErrorAction Stop works as expected
        Log-Error "Could not find the network adapter named '$TargetAdapterName' after waiting. The adapter might not have been created or named as expected."
        # Attempt cleanup if possible, then exit
        if ($SwitchCreated) {
            Log-Step "Attempting cleanup: Removing Virtual Switch '$FinalSwitchName'..."
            Remove-VMSwitch -Name $FinalSwitchName -Force -ErrorAction SilentlyContinue
        }
        return # Exit script
    }

} catch {
    # Catch errors from Get-NetAdapter (e.g., adapter not found)
    Log-Error "Failed to retrieve the network adapter named '$TargetAdapterName'. It might not exist, might have a different name, or hasn't registered yet." $_.Exception
    Write-Host "Common issue: Sometimes the adapter takes longer to appear. You might try running the script again." -ForegroundColor Yellow
    # Attempt cleanup if possible, then exit
    if ($SwitchCreated) {
        Log-Step "Attempting cleanup: Removing Virtual Switch '$FinalSwitchName'..."
        Remove-VMSwitch -Name $FinalSwitchName -Force -ErrorAction SilentlyContinue
    }
    return # Exit script
}

# 6. Set IP Address on the Adapter
Log-Step "Attempting to configure IP address '$IpAddress/$PrefixLength' on adapter '$($adapter.Name)'..."
try {
    # Check if the IP is already configured (e.g., from a previous failed run)
    $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $IpAddress -ErrorAction SilentlyContinue
    if ($existingIP) {
         Log-Step "IP address $IpAddress is already configured on adapter '$($adapter.Name)'. Skipping configuration." -Type "Warning"
         Write-Host "WARNING: IP address $IpAddress is already configured on adapter '$($adapter.Name)'. Skipping configuration." -ForegroundColor Yellow
         $IpConfigured = $true # Consider it configured
    } else {
        New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $IpAddress -PrefixLength $PrefixLength -ErrorAction Stop
        Log-Step "Successfully configured IP address '$IpAddress/$PrefixLength' on adapter '$($adapter.Name)'."
        $IpConfigured = $true
    }
} catch {
    Log-Error "Failed to configure IP address '$IpAddress/$PrefixLength' on adapter '$($adapter.Name)'." $_.Exception
    # Attempt cleanup (remove switch) as NAT setup will likely fail
    if ($SwitchCreated) { Remove-VMSwitch -Name $FinalSwitchName -Force -ErrorAction SilentlyContinue }
    return
}

# 7. Create the NetNat
Log-Step "Attempting to create NetNat '$NatName' for subnet '$NatSubnet'..."
try {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatSubnet -ErrorAction Stop
    Log-Step "Successfully created NetNat '$NatName' for subnet '$NatSubnet'."
    $NatCreated = $true
} catch {
    Log-Error "Failed to create NetNat '$NatName' for subnet '$NatSubnet'." $_.Exception
    # Attempt cleanup (remove IP and switch)
    if ($IpConfigured) { Remove-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $IpAddress -Confirm:$false -ErrorAction SilentlyContinue }
    if ($SwitchCreated) { Remove-VMSwitch -Name $FinalSwitchName -Force -ErrorAction SilentlyContinue }
    return
}

# --- Final Summary ---
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host " Script Execution Summary" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan

if ($ErrorOccurred) {
    Write-Host "Script finished with errors. Please review the log above." -ForegroundColor Red
    Write-Host "Summary of attempted actions:" -ForegroundColor Yellow
} else {
    Write-Host "Script finished successfully." -ForegroundColor Green
    Write-Host "Summary of actions performed:" -ForegroundColor Green
}

Write-Host "`nSteps Taken:"
$ScriptSteps | ForEach-Object { Write-Host "- $_" }

Write-Host "`n--- Configuration Details ---"
if ($SwitchCreated) {
    Write-Host "Virtual Switch Created : '$FinalSwitchName' (Type: Internal)" -ForegroundColor Green
} else {
     Write-Host "Virtual Switch Creation: Not completed or failed." -ForegroundColor Yellow
}

if ($IpConfigured) {
    Write-Host "Gateway IP Assigned    : '$IpAddress' (on adapter '$($adapter.Name)')" -ForegroundColor Green
} else {
     Write-Host "Gateway IP Assignment  : Not completed or failed." -ForegroundColor Yellow
}

if ($NatCreated) {
     Write-Host "NAT Network Created    : '$NatName' for Subnet '$NatSubnet'" -ForegroundColor Green
} elseif ($NatRemoved) {
     Write-Host "Existing NAT Removed   : Yes" -ForegroundColor Yellow
     Write-Host "NAT Network Creation : Not completed or failed." -ForegroundColor Yellow
} else {
     Write-Host "NAT Network Creation : Not completed or failed." -ForegroundColor Yellow
}


if (-not $ErrorOccurred -and $SwitchCreated -and $IpConfigured -and $NatCreated) {
    Write-Host "`n--- VM Configuration ---" -ForegroundColor Cyan
    Write-Host "Configure your Virtual Machines connected to the '$FinalSwitchName' switch with:"
    Write-Host " - IP Address : Any IP in the $NatSubnet range (e.g., 192.168.1.100)"

    $subnetMaskString = ""
        try {
            # Assuming IPv4 based on script's usage ($IpAddress = "192.168.1.1")
            if (([IPAddress]$IpAddress).AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                # Calculate the subnet mask integer representation
                $maskInt = [uint32]::MaxValue -shl (32 - $PrefixLength)

                # Convert the integer to bytes
                $maskBytes = [System.BitConverter]::GetBytes($maskInt)

                # On little-endian systems (like Windows), the bytes are in reverse order for IP address notation. Reverse them.
                if ([System.BitConverter]::IsLittleEndian) {
                    [array]::Reverse($maskBytes)
                }

                # Join the bytes with dots to form the correct string
                $subnetMaskString = $maskBytes -join '.'

            } else {
                 # Placeholder if you ever adapt the script for IPv6
                 $subnetMaskString = "(Mask for non-IPv4 address not calculated)"
            }
        } catch {
            # Fallback in case of calculation error
            $subnetMaskString = "(Error calculating mask)"
            Log-Error "Failed to calculate subnet mask string from prefix length '$PrefixLength'." $_.Exception
        }
    Write-Host " - Subnet Mask: $subnetMaskString (or Prefix Length /$PrefixLength)"


    Write-Host " - Gateway    : $IpAddress"
    Write-Host " - DNS Server : Typically your host machine's DNS or public DNS (e.g., 8.8.8.8, 1.1.1.1)"
}

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "Script execution finished."
Write-Host "----------------------------------------" -ForegroundColor Cyan
Read-Host "`nPress Enter to exit..."