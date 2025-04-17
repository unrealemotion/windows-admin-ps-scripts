#Requires -RunAsAdministrator

# --- Function to Download PsExec ---
function Download-PsExec {
    $webClient = New-Object System.Net.WebClient
    $psexecUrl = "https://download.sysinternals.com/files/PSTools.zip"
    $zipFile = "$env:TEMP\PSTools.zip"
    $extractPath = "$env:TEMP\PSTools"

    Write-Host "Downloading PsTools from $psexecUrl..."
    try {
        $webClient.DownloadFile($psexecUrl, $zipFile)
        Write-Host "PsTools downloaded to $zipFile"

        # Extract PsExec.exe
        Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
        $psexecPath = "$extractPath\PsExec.exe"

        if (Test-Path -Path $psexecPath) {
            Write-Host "PsExec.exe extracted to $psexecPath"
            return $psexecPath
        } else {
            Write-Error "Error: PsExec.exe not found after extraction."
            return $null
        }
    }
    catch {
        Write-Error "Error downloading or extracting PsTools: $_"
        return $null
    }
}

# --- Function to Disable WLMS Service ---
function Disable-WLMS {
    param(
        [string]$PsExecPath
    )

    # Check if PsExec path is valid
    if (!(Test-Path -Path $PsExecPath -PathType Leaf)) {
        Write-Error "Error: Invalid PsExec path: $PsExecPath"
        return
    }

    # Command to disable WLMS service using sc.exe via PsExec
    $arguments = @(
        "-s"          # Run as System
        "-accepteula" # Automatically accept the EULA
        "sc.exe"
        "config"
        "WLMS"
        "start=disabled"
    )

    Write-Host "Disabling WLMS service using PsExec..."
    try {
        Start-Process -FilePath $PsExecPath -ArgumentList $arguments -Wait -WindowStyle Hidden -ErrorAction Stop
        Write-Host "WLMS service startup type set to disabled."

        # Stop the service if it's running
        if ((Get-Service -Name WLMS).Status -eq "Running") {
            Write-Host "Stopping WLMS service..."
            Start-Process -FilePath $PsExecPath -ArgumentList "-s sc.exe stop WLMS" -Wait -WindowStyle Hidden -ErrorAction Stop
            Write-Host "WLMS service stopped."
        }
    }
    catch {
        Write-Error "Error disabling WLMS service: $_"
    }
}

# --- Main Script ---

# Prompt for internet access
while ($true) {
    $internetAccess = Read-Host -Prompt "Does this server have internet access? (y/n)"
    if ($internetAccess -eq "y") {
        $psexecPath = Download-PsExec
        if ($psexecPath) {
            Disable-WLMS -PsExecPath $psexecPath
        }
        break
    }
    elseif ($internetAccess -eq "n") {
        Write-Host "PsExec is required to disable the WLMS service."
        Write-Host "Please manually download PsExec from https://live.sysinternals.com/PsExec.exe and transfer it to this machine."
        $psexecPath = Read-Host -Prompt "Enter the full path to PsExec.exe on this machine (e.g., C:\Tools\PsExec.exe)"
        Disable-WLMS -PsExecPath $psexecPath
        break
    }
    else {
        Write-Host "Invalid input. Please enter 'y' or 'n'."
    }
}

# Prompt for reboot
while ($true) {
    $reboot = Read-Host -Prompt "Do you want to reboot the server now? (y/n)"
    if ($reboot -eq "y") {
        Write-Host "Rebooting..."
        Restart-Computer -Force
        break
    }
    elseif ($reboot -eq "n") {
        Write-Host "Reboot skipped."
        break
    }
    else {
        Write-Host "Invalid input. Please enter 'y' or 'n'."
    }
}

Write-Host "Script completed."