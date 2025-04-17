# Function to create a VM without an ISO
function NoISO {
  param(
    [string]$name,
    [string]$mem,
    [string]$vhdxpath
  )

  try {
    # Remove existing NAT network
    Get-NetNat | Remove-NetNat -Confirm:$false | Out-Null

    # Create a new Internal Virtual Switch
    New-VMSwitch -Name "NATSwitch" -SwitchType Internal | Out-Null

    # Set IP address for the new switch
    New-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 24 -InterfaceAlias "vEthernet (NATSwitch)" | Out-Null

    # Create a new NAT network
    New-NetNat -Name "VMNat" -InternalIPInterfaceAddressPrefix 192.168.1.0/24 | Out-Null

    # Create a new VM 
    New-VM -Name $name -MemoryStartupBytes ([int64]$mem * 1GB) -Generation 2 -VHDPath $vhdxpath -SwitchName "NATSwitch" | Out-Null

    # Set the VM to boot from the existing VHDX
    $D = Get-VMHardDiskDrive -VMName $name
    Set-VMFirmware -VMName $name -FirstBootDevice $D | Out-Null

  }
  catch {
    Write-Error "Error creating VM: $_"
    # Undo changes
    Remove-VM -Name $name -Force -Confirm:$false
    Remove-VMSwitch -Name "NATSwitch" -Force -Confirm:$false
    Remove-NetNat -Name "VMNat" -Confirm:$false
    Remove-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 24 -Confirm:$false
  }
}

# Function to create a VM with an ISO
function WithISO {
  param(
    [string]$name,
    [string]$mem,
    [string]$vhdxpath,
    [string]$vhdxsize,
    [string]$ISOpath
  )

  try {
    # Remove existing NAT network
    Get-NetNat | Remove-NetNat -Confirm:$false | Out-Null

    # Create a new Internal Virtual Switch
    New-VMSwitch -Name "NATSwitch" -SwitchType Internal | Out-Null

    # Set IP address for the new switch
    New-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 24 -InterfaceAlias "vEthernet (NATSwitch)" | Out-Null

    # Create a new NAT network
    New-NetNat -Name "VMNat" -InternalIPInterfaceAddressPrefix 192.168.1.0/24 | Out-Null

    # Create a new VM 
    New-VM -Name $name -MemoryStartupBytes ([int64]$mem * 1GB) -Generation 2 -NewVHDPath $vhdxpath -NewVHDSizeBytes ([int64]$vhdxsize * 1GB) -SwitchName "NATSwitch"  | Out-Null

    # Add a DVD drive to the VM
    Add-VMDvdDrive -VMName $name -Path $ISOpath  | Out-Null

    # Set the VM to boot from the CD/DVD drive
    $D = Get-VMDvdDrive -VMName $name
    Set-VMFirmware -VMName $name -FirstBootDevice $D | Out-Null

  }
  catch {
    Write-Error "Error creating VM: $_"
    # Undo changes
    Remove-VM -Name $name -Force -Confirm:$false
    Remove-VMDvdDrive -VMName $name -Confirm:$false
    Remove-VMSwitch -Name "NATSwitch" -Force -Confirm:$false
    Remove-NetNat -Name "VMNat" -Confirm:$false
    Remove-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 24 -Confirm:$false
  }
}

# Prompt the user for input
Write-Host " *** Only use this script for a fresh Hyper-V host without preconfigured NAT *** "
Write-Host "This script will create the first VM connect to the NAT"
Write-Host "For additional VM, please create it via Hyper-V or powershell separately, connect to the NATSwitch and configure Network as per the instruction at the end of this script"
$haveVHDX = Read-Host "Do you already have a VHDX with OS? (y/n)"

if ($haveVHDX -eq "y") {
  $name = Read-Host "Enter the name of the VM"
  $mem = Read-Host "Enter the amount of memory in GB (Whole number)" 
  $vhdxpath = Read-Host "Enter the VHDX path (e.g.: D:\VHD\MyVM.vhdx)"
  NoISO $name $mem $vhdxpath
  Write-Host " "
  Write-Host "Please set up the NIC inside your VM as follow:"
  Write-Host "IP: 192.168.1.x where x can be anything other than 1"
  Write-Host "Mask: 255.255.255.0"
  Write-Host "Gateway: 192.168.1.1"
  Write-Host "A DNS server (e.g.: 1.1.1.1 or 8.8.8.8)"
  Read-Host -Prompt "Press Enter to exit"
} elseif ($haveVHDX -eq "n") {
  $name = Read-Host "Enter the name of the VM"
  $mem = Read-Host "Enter the amount of memory in GB (Whole number)"
    $vhdxpath = Read-Host "Enter the VHDX path (e.g.: D:\VHD\MyVM.vhdx)"
  $vhdxsize = Read-Host "Enter the size of the VHDX in GB (Whole number)"
  $ISOpath = Read-Host "Enter the path of the ISO (e.g.: D:\iso\MyVM.iso)"
  WithISO $name $mem $vhdxpath $vhdxsize $ISOpath
  Write-Host " "
  Write-Host "Please set up the NIC inside your VM as follow:"
  Write-Host "IP: 192.168.1.x where x can be anything other than 1"
  Write-Host "Mask: 255.255.255.0"
  Write-Host "Gateway: 192.168.1.1"
  Write-Host "A DNS server (e.g.: 1.1.1.1 or 8.8.8.8)"
  Read-Host -Prompt "Press Enter to exit"
} else {
  Write-Host "Invalid input. Please enter y or n."
}