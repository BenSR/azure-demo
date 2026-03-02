<#
.SYNOPSIS
    Bootstraps the jumpbox VM with prerequisites for the test script.

.DESCRIPTION
    Called by the Custom Script Extension on first boot. Installs:
      1. Azure CLI   — for Key Vault certificate retrieval
      2. Git for Windows — bundles openssl, needed to build PFX from PEM certs

    Also copies the test script to C:\ for easy access.
#>

param(
    [Parameter(Mandatory)]
    [string]$TestScriptFileName
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # speeds up Invoke-WebRequest

Write-Host "=== Jumpbox Setup ===" -ForegroundColor Cyan

# ── 1. Copy test script to C:\ ──────────────────────────────────────────────
Write-Host "Copying test script to C:\..."
Copy-Item -Path ".\$TestScriptFileName" -Destination "C:\Test-Application-Jumpbox.ps1" -Force

# ── 2. Install Azure CLI ────────────────────────────────────────────────────
Write-Host "Installing Azure CLI..."
Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindowsx64" -OutFile ".\AzureCLI.msi"
Start-Process msiexec.exe -ArgumentList "/I AzureCLI.msi /quiet /norestart" -Wait
Write-Host "Azure CLI installed."

# ── 3. Install Git for Windows (includes openssl) ───────────────────────────
Write-Host "Installing Git for Windows..."
$gitInstallerUrl = "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-64-bit.exe"
Invoke-WebRequest -Uri $gitInstallerUrl -OutFile ".\GitInstall.exe"
Start-Process ".\GitInstall.exe" -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /COMPONENTS="ext\shellhere,assoc,assoc_sh"' -Wait

# Add Git's usr/bin (contains openssl) to the system PATH
$gitBinPath = "C:\Program Files\Git\usr\bin"
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$gitBinPath*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$gitBinPath", "Machine")
    Write-Host "Added $gitBinPath to system PATH."
}
Write-Host "Git for Windows installed."

Write-Host "=== Jumpbox setup complete ===" -ForegroundColor Green
