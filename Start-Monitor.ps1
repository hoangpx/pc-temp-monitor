<#
    PC Temp Monitor - launcher (WiFi mode)
    1. Elevates to Administrator (needed to read CPU/motherboard/RAM temps
       and to bind the network port)
    2. Opens the Windows Firewall for the port
    3. Prints the http://<your-ip>:<port> address to open on the phone
    4. Starts the sensor collector (this window stays open; Ctrl+C to stop)
    Your phone just needs to be on the same WiFi - no cable, no adb.
#>
param(
    [int]$Port = 8085
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Self-elevate to Administrator -----------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges (needed to read hardware temps)..." -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path
    $argList = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Port', $Port)
    Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList
    exit
}

# --- Free the port if a previous instance is still holding it ---------------
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*collector.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { (Get-Process -Id $_.ProcessId).Kill() } catch {} }
    Start-Sleep -Milliseconds 600
} catch { }

# --- Windows Firewall: let phones on the same WiFi reach us -----------------
if (-not (Get-NetFirewallRule -DisplayName "PC Temp Monitor" -ErrorAction SilentlyContinue)) {
    try {
        New-NetFirewallRule -DisplayName "PC Temp Monitor" -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
        Write-Host "Firewall rule added for port $Port." -ForegroundColor DarkGray
    } catch { Write-Warning "Could not add firewall rule (open port $Port manually): $_" }
}

# --- Figure out the WiFi/LAN address to open on the phone -------------------
$ip = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
        Sort-Object { $_.InterfaceAlias -notmatch 'Wi-Fi|WLAN' } |
        Select-Object -First 1 -ExpandProperty IPAddress

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  On your phone (same WiFi), open in a browser:" -ForegroundColor Cyan
Write-Host "      http://$ip`:$Port" -ForegroundColor Green
Write-Host "  (Keep this window open. Ctrl+C to stop.)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# --- Start the collector (blocking) ----------------------------------------
# The collector binds all interfaces (admin), reads sensors + FPS, and cleans
# up PresentMon on exit.
Get-Process presentmon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
& (Join-Path $root 'collector.ps1') -Port $Port
