<#
    PC Temp Monitor - collector
    Reads hardware sensors via LibreHardwareMonitorLib and serves a live
    dashboard + JSON API on http://localhost:<port>.

    Must run as Administrator to read CPU / motherboard / RAM temps.
#>
param(
    [int]$Port = 8085,
    [string]$FpsCsv = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path $root 'lib'
if (-not $FpsCsv) { $FpsCsv = Join-Path $root 'fps.csv' }

# --- Load LibreHardwareMonitor + dependencies ------------------------------
# Load every dependency DLL first so the main lib resolves its references.
Get-ChildItem -Path $libDir -Filter '*.dll' | ForEach-Object {
    try { [void][System.Reflection.Assembly]::LoadFrom($_.FullName) } catch { }
}

# --- Admin check ------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator - CPU / motherboard / RAM temps will likely be empty."
}

# Windows boot time (for uptime) - read once
try { $script:bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { $script:bootTime = Get-Date }

# --- Set up the Computer object --------------------------------------------
$computer = New-Object LibreHardwareMonitor.Hardware.Computer

# Enable each category defensively (property names vary across versions).
$flags = @(
    'IsCpuEnabled', 'IsGpuEnabled', 'IsMemoryEnabled', 'IsMotherboardEnabled',
    'IsStorageEnabled', 'IsControllerEnabled', 'IsPsuEnabled', 'IsBatteryEnabled',
    'IsNetworkEnabled'
)
foreach ($f in $flags) {
    if ($computer.PSObject.Properties.Name -contains $f) {
        try { $computer.$f = $true } catch { }
    }
}

$computer.Open()
Write-Host "Sensor library opened." -ForegroundColor Green

# --- Helpers ----------------------------------------------------------------
function Update-HardwareTree($hw) {
    try { $hw.Update() } catch { }
    foreach ($sh in $hw.SubHardware) { Update-HardwareTree $sh }
}

function Get-Category($hardwareType) {
    switch -Wildcard ($hardwareType.ToString()) {
        'Cpu'          { 'CPU';         break }
        'Gpu*'         { 'GPU';         break }
        'Memory'       { 'RAM';         break }
        'Motherboard'  { 'Motherboard'; break }
        'SuperIO'      { 'Motherboard'; break }
        'Storage'      { 'Storage';     break }
        'Psu'          { 'PSU';         break }
        'Cooler'       { 'Cooling';     break }
        'EmbeddedController' { 'Controller'; break }
        'Battery'      { 'Battery';     break }
        default        { $hardwareType.ToString() }
    }
}

function Get-Unit($sensorType) {
    switch ($sensorType.ToString()) {
        'Temperature' { [char]0x00B0 + 'C'; break }   # degree sign + C
        'Load'        { '%';   break }
        'Fan'         { 'RPM'; break }
        'Power'       { 'W';   break }
        'Voltage'     { 'V';   break }
        'Clock'       { 'MHz'; break }
        'Current'     { 'A';   break }
        'Data'        { 'GB';  break }
        'Throughput'  { 'MB/s';break }
        default       { '' }
    }
}

# Collect all sensors from a hardware node and its descendants.
function Collect-Sensors($hw, $category) {
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $hw.Sensors) {
        # skip null, NaN and Infinity - they produce invalid JSON and break the dashboard
        if ($null -ne $s.Value -and -not [double]::IsNaN([double]$s.Value) -and -not [double]::IsInfinity([double]$s.Value)) {
            [void]$out.Add([pscustomobject]@{
                name  = [string]$s.Name
                type  = $s.SensorType.ToString()
                value = [math]::Round([double]$s.Value, 1)
                unit  = Get-Unit $s.SensorType
            })
        }
    }
    foreach ($sh in $hw.SubHardware) {
        foreach ($item in (Collect-Sensors $sh $category)) { [void]$out.Add($item) }
    }
    return $out
}

# --- FPS via PresentMon (stdout stream) -------------------------------------
# PresentMon opens its -output_file with an exclusive lock, so no other process
# can read it. Instead we spawn PresentMon with -output_stdout and parse frames
# on a background thread, keeping the latest FPS in a synchronized state object
# that the HTTP handler reads instantly.
$script:FpsState = [hashtable]::Synchronized(@{ app = $null; value = $null; ts = [datetime]::MinValue })
$script:FpsRunspace = $null
$script:FpsPowerShell = $null

function Start-FpsReader {
    param([string]$PresentMon)
    if (-not (Test-Path $PresentMon)) { Write-Warning "presentmon.exe not found - FPS disabled."; return }
    try { Get-Process presentmon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}

    $logPath = Join-Path (Split-Path -Parent $PresentMon) 'fps_reader.log'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('FpsState', $script:FpsState)
    $rs.SessionStateProxy.SetVariable('PmExe', $PresentMon)
    $rs.SessionStateProxy.SetVariable('LogPath', $logPath)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        function log($m){ try { "$([DateTime]::Now.ToString('HH:mm:ss')) $m" | Out-File -FilePath $LogPath -Append -Encoding utf8 } catch {} }
        log "reader thread started"
        $deny = @('dwm.exe','explorer.exe','ApplicationFrameHost.exe','SearchHost.exe',
                  'SearchApp.exe','StartMenuExperienceHost.exe','TextInputHost.exe',
                  'ShellExperienceHost.exe','SystemSettings.exe','LockApp.exe','WidgetBoard.exe')
        while ($true) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $PmExe
                $psi.Arguments = '-captureall -output_stdout -stop_existing_session -no_top'
                $psi.RedirectStandardOutput = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                log "presentmon started pid=$($proc.Id)"
                $sr = $proc.StandardOutput
                $cols = ($sr.ReadLine()) -split ','
                $iApp  = [Array]::IndexOf($cols, 'Application')
                $iTime = [Array]::IndexOf($cols, 'TimeInSeconds')
                $iMs   = [Array]::IndexOf($cols, 'msBetweenPresents')
                log "header cols=$($cols.Count) iApp=$iApp iTime=$iTime iMs=$iMs"
                if ($iTime -lt 0 -or $iMs -lt 0) { try { $proc.Kill() } catch {}; Start-Sleep 3; continue }
                $win = New-Object System.Collections.Generic.List[object]
                $since = 0; $logged = $false
                while ($null -ne ($line = $sr.ReadLine())) {
                    $c = $line -split ','
                    if ($c.Count -le $iMs) { continue }
                    [double]$t = 0; [double]$m = 0
                    if (-not [double]::TryParse($c[$iTime], [ref]$t)) { continue }
                    if (-not [double]::TryParse($c[$iMs], [ref]$m)) { continue }
                    if ($m -le 0) { continue }
                    $app = if ($iApp -ge 0) { $c[$iApp] } else { '' }
                    if ($deny -contains $app) { continue }
                    $win.Add([pscustomobject]@{ app = $app; t = $t; ms = $m })
                    $cut = $t - 1.5
                    while ($win.Count -gt 0 -and $win[0].t -lt $cut) { $win.RemoveAt(0) }
                    if (++$since -ge 8) {
                        $since = 0
                        if ($win.Count -ge 4) {
                            $g = $win | Group-Object app | Sort-Object Count -Descending | Select-Object -First 1
                            $sel = $win | Where-Object { $_.app -eq $g.Name }
                            $avg = ($sel | Measure-Object -Property ms -Average).Average
                            if ($avg -gt 0) {
                                $FpsState.app   = ($g.Name -replace '\.exe$','')
                                $FpsState.value = [math]::Round(1000.0 / $avg, 1)
                                $FpsState.ts    = Get-Date
                                if (-not $logged) { log "first FPS update app=$($FpsState.app) value=$($FpsState.value)"; $logged = $true }
                            }
                        }
                    }
                }
                log "stdout ended; presentmon exited=$($proc.HasExited)"
                try { $proc.WaitForExit() } catch {}
            } catch { log "ERROR: $($_.Exception.Message)"; Start-Sleep 3 }
            Start-Sleep 2   # PresentMon exited (game closed / session lost) - relaunch
        }
    })
    $script:FpsPowerShell = $ps
    $script:FpsRunspace = $rs
    [void]$ps.BeginInvoke()
    Write-Host "FPS reader started (PresentMon stdout)." -ForegroundColor Green
}

function Get-Fps {
    $st = $script:FpsState
    if ($null -eq $st -or $null -eq $st.value) { return $null }
    if (((Get-Date) - $st.ts).TotalSeconds -gt 4) { return $null }   # no frames lately = no game
    return [pscustomobject]@{ app = $st.app; value = $st.value }
}

function Get-SensorSnapshot {
    $groups = New-Object System.Collections.ArrayList
    foreach ($hw in $computer.Hardware) {
        Update-HardwareTree $hw
        $cat = Get-Category $hw.HardwareType
        $sensors = Collect-Sensors $hw $cat
        if ($sensors.Count -gt 0) {
            [void]$groups.Add([pscustomobject]@{
                category = $cat
                name     = [string]$hw.Name
                sensors  = @($sensors)
            })
        }
    }
    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        hostname  = $env:COMPUTERNAME
        admin     = $isAdmin
        uptime    = [int]((Get-Date) - $script:bootTime).TotalSeconds
        fps       = (Get-Fps)
        groups    = @($groups)
    }
}

# --- Dashboard html (read fresh per request so edits need no restart) ------
$dashboardPath = Join-Path $root 'dashboard.html'
function Get-DashboardHtml {
    if (Test-Path $dashboardPath) { Get-Content -Path $dashboardPath -Raw -Encoding UTF8 }
    else { '<h1>dashboard.html missing</h1>' }
}

# --- Start FPS capture (needs admin for the ETW trace session) -------------
if ($isAdmin) {
    Start-FpsReader -PresentMon (Join-Path $root 'presentmon.exe')
} else {
    Write-Warning "Not admin - FPS capture disabled (PresentMon needs elevation)."
}

# --- HTTP server ------------------------------------------------------------
$listener = New-Object System.Net.HttpListener
if ($isAdmin) {
    # bind all interfaces so phones on the same WiFi can reach us
    $listener.Prefixes.Add("http://+:$Port/")
} else {
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
}
try {
    $listener.Start()
} catch {
    # fall back to loopback-only if the wildcard bind is refused
    Write-Warning "Wildcard bind failed ($_). Falling back to localhost only."
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    try { $listener.Start() } catch { Write-Error "Could not start HTTP listener on port $Port. $_"; exit 1 }
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  PC Temp Monitor is running" -ForegroundColor Cyan
Write-Host "  Local dashboard : http://localhost:$Port" -ForegroundColor Cyan
Write-Host "  On the phone    : http://localhost:$Port  (via adb reverse)" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C in this window to stop." -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req = $context.Request
        $res = $context.Response
        try {
            $path = $req.Url.AbsolutePath
            $res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
            $res.Headers.Add('Access-Control-Allow-Origin', '*')

            if ($path -eq '/data.json' -or $path -eq '/data') {
                $snapshot = Get-SensorSnapshot
                $json = $snapshot | ConvertTo-Json -Depth 8 -Compress
                $bytes = $utf8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/' -or $path -eq '/index.html') {
                $bytes = $utf8.GetBytes((Get-DashboardHtml))
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/sw.js') {
                # minimal service worker with a fetch handler - required so Chrome
                # installs the page as a real standalone/fullscreen app (WebAPK)
                $sw = "self.addEventListener('install',function(e){self.skipWaiting();});" +
                      "self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim());});" +
                      "self.addEventListener('fetch',function(e){});"
                $bytes = $utf8.GetBytes($sw)
                $res.ContentType = 'application/javascript; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/manifest.webmanifest') {
                $manifest = @'
{
  "name": "PC Temps",
  "short_name": "PC Temps",
  "start_url": "/",
  "scope": "/",
  "display": "fullscreen",
  "orientation": "landscape",
  "background_color": "#000000",
  "theme_color": "#000000",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ]
}
'@
                $bytes = $utf8.GetBytes($manifest)
                $res.ContentType = 'application/manifest+json; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/icon-192.png' -or $path -eq '/icon-512.png') {
                $iconPath = Join-Path $root ($path.TrimStart('/'))
                if (Test-Path $iconPath) {
                    $bytes = [System.IO.File]::ReadAllBytes($iconPath)
                    $res.ContentType = 'image/png'
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else { $res.StatusCode = 404 }
            }
            else {
                $res.StatusCode = 404
                $bytes = $utf8.GetBytes('Not found')
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        } catch {
            try { $res.StatusCode = 500 } catch { }
            Write-Warning "Request error: $_"
        } finally {
            try { $res.OutputStream.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $computer.Close()
    try { Get-Process presentmon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    try { if ($script:FpsPowerShell) { $script:FpsPowerShell.Dispose() } } catch {}
    try { if ($script:FpsRunspace) { $script:FpsRunspace.Dispose() } } catch {}
    Write-Host "Stopped." -ForegroundColor Yellow
}
