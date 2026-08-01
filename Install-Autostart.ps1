<#
    PC Temp Monitor - install / remove auto-start at login.
    Creates a Scheduled Task that runs the monitor elevated at every login
    (no UAC prompt at boot, because the task itself carries the elevation).

    Run:   Install-Autostart.cmd            (install)
           Install-Autostart.cmd -Uninstall (remove)
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'PC Temp Monitor'
$script = Join-Path $root 'Start-Monitor.ps1'

# --- Self-elevate -----------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    if ($Uninstall) { $a += '-Uninstall' }
    Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $a
    exit
}

# --- Uninstall --------------------------------------------------------------
if ($Uninstall) {
    schtasks.exe /Delete /TN "$taskName" /F | Out-Null
    Write-Host "Auto-start removed." -ForegroundColor Yellow
    Start-Sleep 4
    exit
}

# --- Install ----------------------------------------------------------------
$tr = '"powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '"'
schtasks.exe /Create /TN "$taskName" /SC ONLOGON /RL HIGHEST /F /TR $tr
if ($LASTEXITCODE -ne 0) { Write-Warning "Failed to create the task (exit $LASTEXITCODE)."; Start-Sleep 6; exit 1 }

Write-Host ""
Write-Host "Auto-start installed - PC Temp Monitor will launch at every login." -ForegroundColor Green
Write-Host "Starting it now so you don't have to log out..." -ForegroundColor Green
schtasks.exe /Run /TN "$taskName" | Out-Null
Start-Sleep 6

# show the address to open on the phone
$ip = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
        Sort-Object { $_.InterfaceAlias -notmatch 'Wi-Fi|WLAN' } |
        Select-Object -First 1 -ExpandProperty IPAddress
Write-Host ""
Write-Host "On your phone (same WiFi), open:  http://$ip`:8085" -ForegroundColor Cyan
Write-Host "To remove auto-start later, run Uninstall-Autostart.cmd" -ForegroundColor DarkGray
Write-Host ""
Write-Host "You can close this window." -ForegroundColor Green
Start-Sleep 8
