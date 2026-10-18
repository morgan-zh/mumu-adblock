<#
.SYNOPSIS
    MuMu Player ad / telemetry remover with full rollback (portable).

.DESCRIPTION
    Detects a MuMu Player installation, blocks its ad+telemetry domains via the
    Windows hosts file, disables the in-guest game center (com.mumu.store) over
    ADB, suppresses the auto-updater, stops MuMu background services and removes
    MuMu login autostart entries.

    Every change is recorded in a per-machine backup folder, so -Restore can undo
    everything on the SAME machine. No path, port, service name or package name
    is hard-coded to one PC: all of them are discovered at runtime.

.PARAMETER Action
    Apply    : run the ad removal (default).
    Restore  : undo the most recent apply on this machine.
    Verify   : read-only status report.
    Detect   : print detected install/serves/port/guest info and exit.

.PARAMETER DryRun
    Show what would change without writing anything.

.PARAMETER NoLaunch
    Never start the emulator; if it is not running, the in-guest step is skipped.

.PARAMETER Strict
    Also disable com.netease.nie.yosemite (NetEase promotion component) if present.

.PARAMETER BootTimeoutSec
    How long to wait for the Android guest to finish booting (default 180).

.EXAMPLE
    .\MuMu-AdBlock.ps1 -Action Detect
    .\MuMu-AdBlock.ps1 -DryRun
    .\MuMu-AdBlock.ps1
    .\MuMu-AdBlock.ps1 -Action Restore

.NOTES
    Requires Administrator (auto-elevates). Windows PowerShell 5.1+ / PowerShell 7+.
#>

[CmdletBinding(DefaultParameterSetName = 'Normal')]
param(
    [ValidateSet('Apply','Restore','Verify','Detect')]
    [string]$Action = 'Apply',

    [switch]$DryRun,
    [switch]$NoLaunch,
    [switch]$Strict,
    [int]$BootTimeoutSec = 180,

    # Optional path: console transcript of this run (also forwarded to the
    # elevated child, which is the only way to see its output by default).
    [string]$Transcript,

    # Internal: set on the elevated re-launch so we do not elevate again.
    [Parameter(ParameterSetName = 'Elevated')]
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$Script:Elevated = $false

# ---------------------------------------------------------------------------
# Configuration (the only "knowledge" the script has about MuMu)
# ---------------------------------------------------------------------------
$Script:Config = [ordered]@{
    HostsDomains   = @(
        'report.mumu.nie.netease.com'
        'sigma-agentlog-mumusdk.proxima.nie.netease.com'
        'sentry.netease.com'
        'fcount-api.webapp.163.com'
        'fcount-api.webapp.easebar.com'
        'event.sc.gearupportal.com'
        'mumu.nie.netease.com'
        'api.mumu.nie.netease.com'
    )
    HostsMarkers   = @(
        '# MuMu adblock (managed by MuMu-AdBlock.ps1)'   # current marker (ASCII only)
        (([char]0x9065) + [char]0x6D4B)                  # legacy marker: contains U+9065 (yao) as fragment
    )
    StorePackage   = 'com.mumu.store'
    StrictPackages = @('com.netease.nie.yosemite')
    UpdaterName    = 'MuMuNxUpdater.exe'
    ServiceSkip    = @('MuMuNxSup')          # kernel helper: must keep running
    BackupRoot     = Join-Path $env:LOCALAPPDATA 'MuMu-AdBlock'
}

$Script:Log = [System.Collections.Generic.List[string]]::new()
$Script:Record = [ordered]@{}

# ---------------------------------------------------------------------------
# Logging / console
# ---------------------------------------------------------------------------
function Set-ConsoleUtf8 {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $null = & chcp.com 65001 2>$null
    } catch { }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','STEP')][string]$Level = 'INFO')
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line  = "[$stamp][$Level] $Message"
    $Script:Log.Add($line)
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    if ($Level -eq 'STEP') { Write-Host '' ; Write-Host "== $Message" -ForegroundColor $color }
    else { Write-Host $line -ForegroundColor $color }
}

function Save-LogFile {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        $Script:Log | Set-Content -Path $Path -Encoding UTF8
        Write-Log "Log written: $Path" 'OK'
    } catch { }
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-SelfElevate {
    param([string[]]$Arguments)

    $exe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $exe -or $exe -notmatch 'powershell|pwsh') {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    # Argument ARRAY (not one joined string): this is what -Verb RunAs needs to
    # keep each switch intact. A joined string silently produced an empty shell.
    $argArray = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $Arguments

    $p = Start-Process -FilePath $exe -ArgumentList $argArray -Verb RunAs -Wait -PassThru -ErrorAction Stop
    return $p.ExitCode
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
function Get-InstallCandidates {
    $cands = [System.Collections.Generic.List[string]]::new()

    $add = {
        param($p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $p = $p.Trim().TrimEnd('\').Trim('"')
        if ($p -and (Test-Path -LiteralPath $p)) { $cands.Add($p) }
    }

    # 1) Uninstall registry entries (32/64-bit + per-user)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rp in $regPaths) {
        try {
            Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'MuMu' } |
                ForEach-Object {
                    & $add $_.InstallLocation
                    if (-not $_.InstallLocation -and $_.DisplayIcon) {
                        & $add (Split-Path -Parent ($_.DisplayIcon.Trim('"')))
                    }
                    if (-not $_.InstallLocation -and $_.UninstallString) {
                        & $add (Split-Path -Parent (($_.UninstallString -split '"')[1]))
                    }
                }
        } catch { }
    }

    # 2) Registry layout hints
    foreach ($k in @('HKLM:\SOFTWARE\MuMuPlayer','HKLM:\SOFTWARE\Netease\MuMuPlayer','HKCU:\SOFTWARE\MuMuPlayer')) {
        try { if (Test-Path $k) { & $add (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallPath } } catch { }
    }

    # 3) Known relative locations on every local fixed drive
    $rel = @(
        'Program Files\MuMuPlayer-12.0'
        'Program Files\MuMuPlayerGlobal-12.0'
        'Program Files (x86)\MuMuPlayer-12.0'
        'Program Files (x86)\MuMuPlayerGlobal-12.0'
        'Program Files (x86)\MuMu'
        'MuMuPlayer'
        'MuMu\MuMuPlayer'
        'Games\MuMuPlayer'
        'Program Files\Netease\MuMuPlayer-12.0'
    )
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
        foreach ($d in $drives) {
            foreach ($r in $rel) { & $add (Join-Path $d.Root $r) }
        }
    } catch { }

    # 4) Depth-1 sweep for MuMu* folders under likely roots (cheap, not recursive)
    $sweepRoots = [System.Collections.Generic.List[string]]::new()
    try {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
            ForEach-Object {
                $sweepRoots.Add($_.Root)
                foreach ($sub in 'Program Files','Program Files (x86)','Games','Apps','Tools','Software') {
                    $sweepRoots.Add((Join-Path $_.Root $sub))
                }
            }
    } catch { }
    foreach ($d in @($env:USERPROFILE, $env:PUBLIC)) {
        if ($d) {
            $sweepRoots.Add($d)
            foreach ($sub in 'Desktop','Downloads','Documents','App','Apps','Game','Games') {
                $sweepRoots.Add((Join-Path $d $sub))
            }
        }
    }
    foreach ($root in ($sweepRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
        try {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'MuMu' } |
                ForEach-Object { & $add $_.FullName }
        } catch { }
    }

    return ($cands | Select-Object -Unique)
}

function Test-MuMuRoot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $need = @('nx_main','nx_device','vms')
    $hits = 0
    foreach ($n in $need) { if (Test-Path -LiteralPath (Join-Path $Path $n)) { $hits++ } }
    return ($hits -ge 2)
}

function Get-MuMuInstall {
    foreach ($c in Get-InstallCandidates) {
        if (Test-MuMuRoot $c) {
            $obj = [pscustomobject]@{
                Root      = $c
                Cli       = Join-Path $c 'nx_main\mumu-cli.exe'
                Adb       = Join-Path $c 'nx_main\adb.exe'
                Updater   = Join-Path (Join-Path $c 'nx_main') $Script:Config.UpdaterName
                MainCfg   = Join-Path $c 'configs\main'
                VmsDir    = Join-Path $c 'vms'
            }
            if (-not (Test-Path $obj.Cli)) { $obj.Cli = $null }
            if (-not (Test-Path $obj.Adb)) { $obj.Adb = $null }
            return $obj
        }
    }
    return $null
}

function Get-PlayerIndex {
    param($Install)
    if (-not $Install.Cli) { return 0 }
    try {
        $out = & $Install.Cli info 2>&1 | Out-String
        $json = $out | ConvertFrom-Json -ErrorAction SilentlyContinue
        $arr = @($json.players)
        if ($arr.Count -gt 0 -and $null -ne $arr[0].index) { return [int]$arr[0].index }
    } catch { }
    return 0
}

function Get-AdbPort {
    param($Install, [int]$Index = 0)
    $ports = [System.Collections.Generic.List[int]]::new()

    # per-instance config (authoritative)
    try {
        $dirs = Get-ChildItem -LiteralPath $Install.VmsDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'MuMuPlayer' }
        foreach ($d in $dirs) {
            $f = Join-Path $d.FullName 'configs\vm_config.json'
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                $p = $j.vm.nat.port_forward.adb.host_port
                if ($p) { $ports.Add([int]$p) }
            } catch { }
        }
    } catch { }

    # live listeners as a sanity fallback
    if ($ports.Count -eq 0) {
        try {
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::','::1') -and $_.LocalPort -ge 1024 -and $_.LocalPort -le 65535 } |
                ForEach-Object {
                    $owner = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
                    if ($owner -match 'MuMu|Nemu') { $ports.Add([int]$_.LocalPort) }
                }
        } catch { }
    }

    if ($ports.Count -gt 0) {
        $sorted = $ports | Select-Object -Unique | Sort-Object
        return [int]$sorted[0]
    }
    return $null
}

function Get-MuMuServices {
    $found = @()
    try {
        $found = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -match 'MuMu' -or $_.DisplayName -match 'MuMu' -or $_.PathName -match 'MuMu') -and
                ($_.Name -notin $Script:Config.ServiceSkip)
            } |
            Select-Object Name, DisplayName, StartMode, State, PathName
    } catch { }
    return @($found | Where-Object { $null -ne $_ })
}

function Get-MuMuAutostart {
    $found = @()
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $keys) {
        try {
            $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            foreach ($n in $item.Property) {
                $v = (Get-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue).$n
                if ($v -match 'MuMu') {
                    $found += [pscustomobject]@{ Hive = $k; Name = $n; Value = $v }
                }
            }
        } catch { }
    }
    return @($found | Where-Object { $null -ne $_ })
}

# ---------------------------------------------------------------------------
# ADB / guest control
# ---------------------------------------------------------------------------
function Test-AnyPlayerRunning {
    # Detect a live player by NAME, not by path: an elevated MuMu engine process
    # hides its ExecutablePath from a non-elevated caller, so path matching lies.
    $engineNames = '(?i)^(MuMuNxDevice|MuMuNxHeadless|NemuHeadless|MuMuPlayer(-12\.0)?|MuMuVMMHeadless)$'
    try {
        $byName = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match $engineNames }
        if (@($byName).Count -gt 0) { return $true }
    } catch { }

    # Fallback: something is really listening on the player's ADB port.
    try {
        $port = $Script:Record.AdbPort
        if ($port -and (Get-NetTCPConnection -LocalPort ([int]$port) -State Listen -ErrorAction SilentlyContinue)) {
            return $true
        }
    } catch { }
    return $false
}

function Get-AdbSerial {
    param($Install, [int]$Port)
    if (-not $Install.Adb) { return $null }
    # Prefer the known NAT port; otherwise reuse whatever adb already sees.
    if ($Port) { return "127.0.0.1:$Port" }
    try {
        $out = & $Install.Adb devices 2>&1 | Out-String
        $m = [regex]::Matches($out, '(?m)^\s*([\w\.\-:]+)\s+device\s*$')
        if ($m.Count -gt 0) { return $m[0].Groups[1].Value }
    } catch { }
    return $null
}

function Invoke-Adb {
    param($Install, [int]$Index, [string]$Cmd, [int]$TimeoutSec = 60, [string]$Serial)
    $res = [pscustomobject]@{ Ok = $false; Output = ''; Error = '' }
    if (-not $Cmd) { return $res }
    if (-not $Serial) { $Serial = $Script:Record.AdbSerial }

    # 1) plain adb.exe -- fast, returns promptly, easy to time out
    if ($Install.Adb -and $Serial) {
        try {
            $seen = & $Install.Adb devices 2>&1 | Out-String
            if ($seen -notmatch [regex]::Escape($Serial) + '\s+device') {
                $null = & $Install.Adb connect $Serial 2>&1
            }
            $out = & $Install.Adb -s $Serial shell $Cmd 2>&1 | Out-String
            $res.Output = $out.Trim()
            $bad = $res.Output -match 'device offline|device not found|no devices|error:'
            $res.Ok = -not $bad
            if ($bad) { $res.Error = $res.Output.Trim() }
            if ($res.Ok -and $res.Output.Length -gt 0) { return $res }
            if ($res.Ok -and $res.Output.Length -eq 0) { return $res }
        } catch { $res.Error = "adb: $($_.Exception.Message)" }
    }

    # 2) mumu-cli sh as a last resort. NOTE: it retries forever when the
    #    manager plane is not ready, so it is wrapped in a killable job.
    if ($Install.Cli) {
        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($cli, $vm, $c)
                & $cli sh --vmindex $vm --cmd $c 2>&1 | Out-String
            } -ArgumentList $Install.Cli, $Index, $Cmd

            if (Wait-Job $job -Timeout $TimeoutSec) {
                $out = (Receive-Job $job | Out-String).Trim()
                $res.Output = $out
                $res.Ok = ($out -notmatch 'Could not connect|not found|error') -and ($out.Length -gt 0)
                if (-not $res.Ok) { $res.Error = $out }
            } else {
                $res.Error = 'mumu-cli timeout'
            }
        } catch {
            $res.Error = "mumu-cli: $($_.Exception.Message)"
        } finally {
            if ($job) {
                Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $res
}

function Wait-GuestBootCompleted {
    param($Install, [int]$Index, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $i++
        $r = Invoke-Adb -Install $Install -Index $Index -Cmd 'getprop sys.boot_completed' -TimeoutSec 20
        if ($r.Ok -and $r.Output -match '1') { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Start-GuestIfNeeded {
    param($Install, [int]$Index)
    if (Test-AnyPlayerRunning) { return $true }
    if ($NoLaunch) {
        Write-Log 'Emulator is not running and -NoLaunch was given: skipping in-guest step.' 'WARN'
        return $false
    }
    if (-not $Install.Cli) {
        Write-Log 'mumu-cli.exe not found and emulator not running: skipping in-guest step.' 'WARN'
        return $false
    }
    Write-Log "Starting emulator (vm index $Index) ..." 'INFO'
    try { & $Install.Cli control --vmindex $Index launch 2>&1 | Out-Null } catch {
        Write-Log "Launch command failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
    Write-Log "Waiting for guest boot (timeout ${BootTimeoutSec}s) ..." 'INFO'
    if (Wait-GuestBootCompleted -Install $Install -Index $Index -TimeoutSec $BootTimeoutSec) {
        Write-Log 'Guest boot completed.' 'OK'
        return $true
    }
    Write-Log 'Guest boot timed out: skipping in-guest step.' 'WARN'
    return $false
}

function Get-DisabledPackages {
    param($Install, [int]$Index)
    $r = Invoke-Adb -Install $Install -Index $Index -Cmd 'pm list packages -d' -TimeoutSec 40
    if (-not $r.Ok) { return $null }
    return @($r.Output -split "`r?`n" |
        Where-Object { $_ -match '^\s*package:(.+?)\s*$' } |
        ForEach-Object { $Matches[1] })
}

function Get-PackageState {
    param($Install, [int]$Index, [string]$Package, [string[]]$DisabledList)
    $state = [pscustomobject]@{ Known = $false; Disabled = $false; Present = $null }

    if ($null -ne $DisabledList) {
        $state.Known = $true
        $state.Disabled = ($DisabledList -contains $Package)
    } else {
        $state.Disabled = $false
    }

    # Presence check is only needed when the package is not already known-disabled.
    if (-not $state.Disabled) {
        $r = Invoke-Adb -Install $Install -Index $Index -Cmd 'pm list packages' -TimeoutSec 40
        if ($r.Ok) {
            $state.Known = $true
            $state.Present = (@($r.Output -split "`r?`n" |
                Where-Object { $_ -match '^\s*package:(.+?)\s*$' } |
                ForEach-Object { $Matches[1] }) -contains $Package)
        } else {
            $state.Present = $null   # cannot tell -> caller decides
        }
    } else {
        $state.Present = $true
    }
    return $state
}

# ---------------------------------------------------------------------------
# Hosts file
# ---------------------------------------------------------------------------
function Get-HostsPath {
    $p = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $p)) { throw "hosts file not found: $p" }
    return $p
}

function Read-HostsFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    $text = $enc.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom; Encoding = $enc }
}

function Write-HostsFile {
    param([string]$Path, [string]$Text, $Encoding)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hosts.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($tmp, $Text, $Encoding)
    try {
        # Preserve the original DACL on an existing hosts file.
        $acl = Get-Acl -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($acl) { Set-Acl -LiteralPath $tmp -AclObject $acl -ErrorAction SilentlyContinue }
    } catch { }
    try { [System.IO.File]::Replace($tmp, $Path, $null) }
    catch {
        Copy-Item -LiteralPath $tmp -Destination $Path -Force
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Find-HostsMarkerLine {
    param([string[]]$Lines)
    foreach ($l in $Lines) {
        foreach ($m in $Script:Config.HostsMarkers) {
            if ($l.Trim().Contains($m)) { return $true }
        }
    }
    return $false
}

function Get-ManagedHostsDomains {
    param([string[]]$Lines)
    $found = @()
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if ($t -match '^0\.0\.0\.0\s+(\S+)') {
            $d = $Matches[1].ToLowerInvariant()
            if ($Script:Config.HostsDomains -contains $d) { $found += $d }
        }
    }
    return ($found | Select-Object -Unique)
}

function Test-HostsBlock {
    $p = Get-HostsPath
    try {
        $h = Read-HostsFile -Path $p
        $lines = $h.Text -split "`r?`n"
        if (Find-HostsMarkerLine -Lines $lines) { return $true }
        # tolerate a block whose marker was lost: all domains blocked is good enough
        return ((Get-ManagedHostsDomains -Lines $lines).Count -ge $Script:Config.HostsDomains.Count)
    } catch { return $false }
}

function Add-HostsBlock {
    $p = Get-HostsPath
    try { $h = Read-HostsFile -Path $p } catch { throw "cannot read hosts: $($_.Exception.Message)" }
    $lines = $h.Text -split "`r?`n"

    if ((Find-HostsMarkerLine -Lines $lines) -or
        ((Get-ManagedHostsDomains -Lines $lines).Count -ge $Script:Config.HostsDomains.Count)) {
        Write-Log 'hosts: ad domains already blocked, skipped.' 'INFO'
        return
    }

    $block = "`r`n$($Script:Config.HostsMarkers[0])`r`n"
    foreach ($d in $Script:Config.HostsDomains) { $block += "0.0.0.0 $d`r`n" }

    if ($DryRun) {
        Write-Log "hosts: would append $($Script:Config.HostsDomains.Count) domains to $p" 'WARN'
        return
    }

    $orig = Join-Path $Script:Record.BackupDir 'hosts.original'
    try { Copy-Item -LiteralPath $p -Destination $orig -Force } catch { }

    $new = $h.Text.TrimEnd() + $block
    Write-HostsFile -Path $p -Text $new -Encoding $h.Encoding
    Write-Log "hosts: appended $($Script:Config.HostsDomains.Count) domains" 'OK'
}

function Remove-HostsBlock {
    $p = Get-HostsPath
    try { $h = Read-HostsFile -Path $p } catch { throw "cannot read hosts: $($_.Exception.Message)" }
    $lines = $h.Text -split "`r?`n"

    $hasMarker = Find-HostsMarkerLine -Lines $lines
    $managed  = Get-ManagedHostsDomains -Lines $lines
    if (-not $hasMarker -and $managed.Count -eq 0) {
        Write-Log 'hosts: no managed entries found, skipped.' 'INFO'
        return
    }
    if ($DryRun) {
        Write-Log "hosts: would remove $($managed.Count) managed domain line(s)" 'WARN'
        return
    }

    $out = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($l in $lines) {
        $t = $l.Trim()

        if (Find-HostsMarkerLine -Lines @($l)) { $inBlock = $true; continue }

        $isManagedDomain = $false
        if ($t -match '^0\.0\.0\.0\s+(\S+)' -and ($Script:Config.HostsDomains -contains $Matches[1].ToLowerInvariant())) {
            $isManagedDomain = $true
        }
        if ($isManagedDomain) { continue }

        # drop comment/blank separator lines that sit directly above a managed block
        if ($inBlock) {
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $inBlock = $false
        }
        $out.Add($l)
    }

    Write-HostsFile -Path $p -Text ($out -join "`r`n") -Encoding $h.Encoding
    Write-Log "hosts: removed $($managed.Count) managed domain line(s)" 'OK'
}

# ---------------------------------------------------------------------------
# Updater
# ---------------------------------------------------------------------------
function Set-UpdaterSuppressed {
    param($Install)
    $cfgFile = Join-Path $Install.MainCfg 'nx_updater_config.json'
    if (-not (Test-Path -LiteralPath $cfgFile)) {
        Write-Log "updater: $cfgFile not found, skipped." 'WARN'
        return
    }
    $raw = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8
    $cfg = $null
    try { $cfg = $raw | ConvertFrom-Json } catch { }

    # Which version is installed? (registry is the most reliable source)
    $installed = $null
    try {
        $installed = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'MuMu' } | Select-Object -First 1).DisplayVersion
    } catch { }
    if (-not $installed) {
        try {
            $installed = (& $Install.Cli version 2>&1 | Out-String).Trim()
        } catch { }
    }
    if (-not $installed -and $cfg -and $cfg.nxupdater.version.reminder) { $installed = $cfg.nxupdater.version.reminder }
    if (-not $installed) { $installed = '0.0.0.0' }

    $null = Set-RecordValue -Name 'UpdaterCfg' -Value $cfgFile
    $null = Set-RecordValue -Name 'UpdaterVersion' -Value $installed

    if ($cfg) {
        $cur = [string]$cfg.nxupdater.version.skip
        if ($cur -split ';' -contains $installed) {
            Write-Log "updater: $installed already in skip list." 'INFO'
            return
        }
        if ($DryRun) { Write-Log "updater: would add $installed to skip list" 'WARN'; return }

        # Two independent restore anchors: the run's backup folder AND a sidecar
        # next to the config, so a lost/late record folder cannot cost the user
        # their original skip list.
        Copy-Item -LiteralPath $cfgFile -Destination (Join-Path $Script:Record.BackupDir 'nx_updater_config.json.orig') -Force
        Copy-Item -LiteralPath $cfgFile -Destination "$cfgFile.mumu-adblock.orig" -Force
        Write-Log "updater: sidecar saved -> $cfgFile.mumu-adblock.orig" 'INFO'

        $cfg.nxupdater.version.skip = if ([string]::IsNullOrWhiteSpace($cur)) { $installed } else { "$cur;$installed" }
        ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $cfgFile -Encoding UTF8
        Write-Log "updater: added $installed to skip list (was: '$cur')" 'OK'
        return
    }

    # Not valid JSON: leave the file alone, only record that we could not handle it.
    Write-Log 'updater: config is not valid JSON, left untouched.' 'WARN'
}

function Restore-Updater {
    param($Record)
    $cfg = $Record.UpdaterCfg
    $orig = Join-Path $Record.BackupDir 'nx_updater_config.json.orig'

    # Anchor 1: this run's backup folder
    if ($cfg -and (Test-Path -LiteralPath $orig)) {
        if ($DryRun) { Write-Log "updater: would restore $cfg from backup" 'WARN'; return }
        Copy-Item -LiteralPath $orig -Destination $cfg -Force
        Remove-Item -LiteralPath "$cfg.mumu-adblock.orig" -Force -ErrorAction SilentlyContinue
        Write-Log 'updater: original config restored (from run backup)' 'OK'
        return
    }

    # Anchor 2: sidecar written next to the config by Set-UpdaterSuppressed
    if ($cfg -and (Test-Path -LiteralPath "$cfg.mumu-adblock.orig")) {
        if ($DryRun) { Write-Log "updater: would restore $cfg from sidecar" 'WARN'; return }
        Copy-Item -LiteralPath "$cfg.mumu-adblock.orig" -Destination $cfg -Force
        Remove-Item -LiteralPath "$cfg.mumu-adblock.orig" -Force -ErrorAction SilentlyContinue
        Write-Log 'updater: original config restored (from sidecar)' 'OK'
        return
    }

    # No anchor: do NOT guess. Dropping an unknown version from the skip list
    # could silently re-enable an update the user had suppressed themselves.
    if ($cfg -and $Record.UpdaterVersion) {
        Write-Log ("updater: no original copy found - skip list left as-is. " +
                   "If you did not suppress $($Record.UpdaterVersion) yourself, " +
                   "remove it from nx_updater_config.json manually.") 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Services / autostart
# ---------------------------------------------------------------------------
function Set-RecordValue {
    param([string]$Name, $Value)
    if ($null -eq $Script:Record) { $Script:Record = [ordered]@{} }
    if ($Script:Record -is [System.Collections.IDictionary]) {
        $Script:Record[$Name] = $Value
    } else {
        # PSCustomObject (e.g. rebuilt from record.json) has no fixed shape.
        $Script:Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    return $Value
}

function Stop-MuMuServices {
    param($Services)
    $saved = @()
    foreach ($s in $Services) {
        $saved += [pscustomobject]@{ Name = $s.Name; StartMode = $s.StartMode; State = $s.State }
        if ($DryRun) { Write-Log "service: would stop + set Manual: $($s.Name)" 'WARN'; continue }
        try {
            if ($s.State -eq 'Running') { Stop-Service -Name $s.Name -Force -ErrorAction Stop }
            Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop
            Write-Log "service: $($s.Name) stopped, startup=Manual" 'OK'
        } catch {
            Write-Log "service: $($s.Name) failed: $($_.Exception.Message)" 'WARN'
        }
    }
    return $saved
}

function Restore-MuMuServices {
    param($Saved)
    foreach ($s in $Saved) {
        $type = if ($s.StartMode -eq 'Auto') { 'Automatic' } else { $s.StartMode }
        if ($DryRun) { Write-Log "service: would set $($s.Name) to $type" 'WARN'; continue }
        try {
            Set-Service -Name $s.Name -StartupType $type -ErrorAction Stop
            if ($s.State -eq 'Running') { Start-Service -Name $s.Name -ErrorAction Stop }
            Write-Log "service: $($s.Name) -> $type" 'OK'
        } catch { Write-Log "service: $($s.Name) restore failed: $($_.Exception.Message)" 'WARN' }
    }
}

function Remove-MuMuAutostart {
    param($Entries)
    $saved = @()
    foreach ($e in $Entries) {
        $saved += [pscustomobject]@{ Hive = $e.Hive; Name = $e.Name; Value = $e.Value }
        if ($DryRun) { Write-Log "autostart: would remove $($e.Hive) [$($e.Name)]" 'WARN'; continue }
        try {
            Remove-ItemProperty -LiteralPath $e.Hive -Name $e.Name -ErrorAction Stop
            Write-Log "autostart: removed [$($e.Name)] from $($e.Hive)" 'OK'
        } catch { Write-Log "autostart: [$($e.Name)] failed: $($_.Exception.Message)" 'WARN' }
    }
    return $saved
}

function Restore-MuMuAutostart {
    param($Saved)
    foreach ($e in $Saved) {
        if ($DryRun) { Write-Log "autostart: would restore [$($e.Name)]" 'WARN'; continue }
        try {
            if (-not (Test-Path -LiteralPath $e.Hive)) { New-Item -Path $e.Hive -Force | Out-Null }
            New-ItemProperty -LiteralPath $e.Hive -Name $e.Name -Value $e.Value -PropertyType String -Force | Out-Null
            Write-Log "autostart: restored [$($e.Name)]" 'OK'
        } catch { Write-Log "autostart: [$($e.Name)] restore failed: $($_.Exception.Message)" 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# Backup record
# ---------------------------------------------------------------------------
function New-BackupDir {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $Script:Config.BackupRoot ("{0}-{1}" -f $env:COMPUTERNAME, $stamp)
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Find-LatestBackup {
    if (-not (Test-Path -LiteralPath $Script:Config.BackupRoot)) { return $null }
    $dir = Get-ChildItem -LiteralPath $Script:Config.BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$env:COMPUTERNAME-*" -and (Test-Path (Join-Path $_.FullName 'record.json')) } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $dir) {
        $dir = Get-ChildItem -LiteralPath $Script:Config.BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'record.json') } |
            Sort-Object Name -Descending | Select-Object -First 1
    }
    if (-not $dir) { return $null }
    return $dir.FullName
}

function Save-Record {
    $path = Join-Path $Script:Record.BackupDir 'record.json'
    ($Script:Record | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Log "Record saved: $path" 'OK'
}

function Read-Record {
    param([string]$Dir)
    $path = Join-Path $Dir 'record.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "No record.json in $Dir" }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
function Invoke-Detect {
    Write-Log 'Detecting MuMu Player installation ...' 'STEP'
    $install = Get-MuMuInstall
    if (-not $install) {
        Write-Log 'MuMu Player not detected. Searched: uninstall registry, common folders, drive roots.' 'ERR'
        return $null
    }
    $idx  = Get-PlayerIndex -Install $install
    $port   = Get-AdbPort   -Install $install -Index $idx
    $serial = Get-AdbSerial -Install $install -Port $port
    # Hand the detected endpoint to the module-scoped record so every later adb
    # call (and the running-player check) has it without explicit plumbing.
    if (-not $Script:Record) { $Script:Record = [ordered]@{} }
    $null = Set-RecordValue -Name 'AdbPort'   -Value $port
    $null = Set-RecordValue -Name 'AdbSerial' -Value $serial
    $svc  = Get-MuMuServices
    $auto = Get-MuMuAutostart

    Write-Log "Install root : $($install.Root)" 'OK'
    Write-Log "mumu-cli     : $(if($install.Cli){$install.Cli}else{'<missing>'})" 'INFO'
    Write-Log "adb.exe      : $(if($install.Adb){$install.Adb}else{'<missing>'})" 'INFO'
    Write-Log "Updater      : $(if(Test-Path $install.Updater){$install.Updater}else{'<not present>'})" 'INFO'
    Write-Log "Player index : $idx" 'INFO'
    Write-Log "ADB port     : $(if($port){$port}else{'<unknown / not running>'})" 'INFO'
    Write-Log "ADB serial   : $(if($serial){$serial}else{'<none>'})" 'INFO'
    Write-Log "Services     : $(if(@($svc).Count){(@($svc) | ForEach-Object { "$($_.Name){$($_.StartMode),$($_.State)}" }) -join ', '}else{'none'})" 'INFO'
    Write-Log "Autostart    : $(if(@($auto).Count){(@($auto) | ForEach-Object { "$($_.Hive)[$($_.Name)]" }) -join ', '}else{'none'})" 'INFO'
    Write-Log "hosts blocked: $(Test-HostsBlock)" 'INFO'
    Write-Log "Player alive : $(Test-AnyPlayerRunning)" 'INFO'

    return [pscustomobject]@{ Install = $install; Index = $idx; Port = $port; Serial = $serial; Services = $svc; Autostart = $auto }
}

function Invoke-Apply {
    Write-Log 'MuMu ad removal: APPLY' 'STEP'
    $det = Invoke-Detect
    if (-not $det) { return 1 }
    $install = $det.Install

    if (-not $DryRun) {
        $Script:Record = [ordered]@{
            Tool          = 'MuMu-AdBlock.ps1'
            Version       = 2
            AppliedAt     = (Get-Date).ToString('o')
            ComputerName  = $env:COMPUTERNAME
            InstallRoot   = $install.Root
            PlayerIndex   = $det.Index
            AdbPort       = $det.Port
            AdbSerial     = $det.Serial
            BackupDir     = ''
            HostsAdded    = $false
            Services      = @()
            Autostart     = @()
            Packages      = @()
            UpdaterCfg    = $null
            UpdaterVersion= $null
            DryRun        = $false
        }
        $null = Set-RecordValue -Name 'BackupDir' -Value (New-BackupDir)
        Write-Log "Backup folder: $($Script:Record.BackupDir)" 'INFO'
        # adb calls resolve the serial from the record when not passed explicitly
        $null = Set-RecordValue -Name 'AdbSerial' -Value $det.Serial
    } else {
        Write-Log 'DRY RUN: nothing will be written.' 'WARN'
        $null = Set-RecordValue -Name 'BackupDir' -Value (Join-Path $env:TEMP ('mumu-adblock-dryrun-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
        New-Item -ItemType Directory -Force -Path $Script:Record.BackupDir | Out-Null
    }

    # -- 1. hosts -----------------------------------------------------------
    Write-Log 'hosts: blocking ad + telemetry domains' 'STEP'
    try {
        Add-HostsBlock
        if (-not $DryRun) { $null = Set-RecordValue -Name 'HostsAdded' -Value $true }
        if (-not $DryRun) { & ipconfig /flushdns 2>&1 | Out-Null; Write-Log 'DNS cache flushed.' 'OK' }
    } catch { Write-Log "hosts: FAILED ($($_.Exception.Message))" 'ERR' }

    # -- 2. updater ---------------------------------------------------------
    Write-Log 'updater: suppressing auto-update' 'STEP'
    try { Set-UpdaterSuppressed -Install $install } catch { Write-Log "updater: FAILED ($($_.Exception.Message))" 'ERR' }

    # -- 3. services + autostart -------------------------------------------
    Write-Log 'services / autostart: stopping background components' 'STEP'
    $savedSvc  = Stop-MuMuServices   -Services $det.Services
    $savedAuto = Remove-MuMuAutostart -Entries $det.Autostart
    if (-not $DryRun) {
        $null = Set-RecordValue -Name 'Services'  -Value $savedSvc
        $null = Set-RecordValue -Name 'Autostart' -Value $savedAuto
    }

    # -- 4. in-guest game center -------------------------------------------
    Write-Log 'guest: disabling game center via ADB' 'STEP'
    $pkgs = @($Script:Config.StorePackage)
    if ($Strict) { $pkgs += $Script:Config.StrictPackages }

    if (Start-GuestIfNeeded -Install $install -Index $det.Index) {
        $disabled = Get-DisabledPackages -Install $install -Index $det.Index
        foreach ($pkg in $pkgs) {
            $st = Get-PackageState -Install $install -Index $det.Index -Package $pkg -DisabledList $disabled
            $alreadOk = $st.Disabled
            if ($st.Present -eq $false) {
                Write-Log "guest: $pkg not installed, skipped." 'INFO'
                continue
            }
            if ($alreadOk) {
                Write-Log "guest: $pkg already disabled." 'INFO'
                if (-not $DryRun) { $Script:Record.Packages += [pscustomobject]@{ Package = $pkg; WasDisabled = $true } }
                continue
            }
            if ($DryRun) { Write-Log "guest: would disable $pkg" 'WARN'; continue }
            $r = Invoke-Adb -Install $install -Index $det.Index -Cmd "pm disable-user --user 0 $pkg"
            if ($r.Output -match 'disabled') {
                $null = Invoke-Adb -Install $install -Index $det.Index -Cmd "am force-stop $pkg" -TimeoutSec 20
                Write-Log "guest: $pkg disabled" 'OK'
                $Script:Record.Packages += [pscustomobject]@{ Package = $pkg; WasDisabled = $false }
            } else {
                Write-Log "guest: $pkg could not be disabled ($($r.Output)$($r.Error))" 'WARN'
            }
        }
    }

    if (-not $DryRun) {
        Save-Record
        $logPath = Join-Path $Script:Record.BackupDir 'apply.log'
        Save-LogFile -Path $logPath
        Write-Log ''  'INFO'
        Write-Log "UNDO:  .\MuMu-AdBlock.ps1 -Action Restore" 'OK'
        Write-Log "UNDO (if this folder is gone): use record.json in $($Script:Record.BackupDir)" 'INFO'
    }
    Write-Log 'APPLY finished.' 'STEP'
    return 0
}

function Get-DefaultAutostartEntries {
    param($Install)
    # Rebuild the login autostart MuMu normally registers (used when no record exists).
    $entries = @()
    if (-not $Install) { return $entries }
    $exe = Join-Path $Install.Root 'nx_main\MuMuNxService.exe'
    if (Test-Path -LiteralPath $exe) {
        $entries += [pscustomobject]@{
            Hive  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Name  = 'MuMuPlayerService'
            Value = $exe
        }
    }
    return $entries
}

function Invoke-RestoreBestEffort {
    param($Install)
    Write-Log 'No record.json: running BEST-EFFORT restore (detected state only).' 'WARN'

    Write-Log 'hosts: removing managed entries' 'STEP'
    try { Remove-HostsBlock } catch { Write-Log "hosts: FAILED ($($_.Exception.Message))" 'ERR' }

    Write-Log 'updater: undoing skip-list entry' 'STEP'
    try {
        $cfgFile = $null
        if ($Install) { $cfgFile = Join-Path $Install.Root 'configs\main\nx_updater_config.json' }
        $sidecar = if ($cfgFile) { "$cfgFile.mumu-adblock.orig" } else { $null }

        if ($sidecar -and (Test-Path -LiteralPath $sidecar)) {
            if ($DryRun) {
                Write-Log "updater: would restore $cfgFile from sidecar" 'WARN'
            } else {
                Copy-Item -LiteralPath $sidecar -Destination $cfgFile -Force
                Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
                Write-Log 'updater: original config restored (from sidecar)' 'OK'
            }
        } elseif ($cfgFile -and (Test-Path -LiteralPath $cfgFile)) {
            Write-Log 'updater: no sidecar and no record - skip list left untouched (will not guess).' 'WARN'
        }
    } catch { Write-Log "updater: FAILED ($($_.Exception.Message))" 'WARN' }

    Write-Log 'services: restoring MuMu services to automatic' 'STEP'
    $svc = @()
    try {
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -match 'MuMu' -or $_.DisplayName -match 'MuMu' -or $_.PathName -match 'MuMu') }
    } catch { }
    foreach ($s in $svc) {
        if ($s.Name -in $Script:Config.ServiceSkip) {
            Write-Log "service: $($s.Name) left alone (kernel helper)" 'INFO'
            continue
        }
        if ($DryRun) { Write-Log "service: would set $($s.Name) -> Automatic" 'WARN'; continue }
        try {
            Set-Service -Name $s.Name -StartupType Automatic -ErrorAction Stop
            if ($s.State -ne 'Running') { Start-Service -Name $s.Name -ErrorAction Stop }
            Write-Log "service: $($s.Name) -> Automatic (running)" 'OK'
        } catch { Write-Log "service: $($s.Name) failed: $($_.Exception.Message)" 'WARN' }
    }

    Write-Log 'autostart: re-registering MuMu login entry' 'STEP'
    $current = Get-MuMuAutostart
    $curAuto = @($current | Where-Object { $null -ne $_ })
    if ($curAuto.Count -gt 0) {
        Write-Log 'autostart: entry already present, skipped.' 'INFO'
    } else {
        foreach ($e in (Get-DefaultAutostartEntries -Install $Install)) {
            if ($DryRun) { Write-Log "autostart: would add [$($e.Name)]" 'WARN'; continue }
            try {
                if (-not (Test-Path -LiteralPath $e.Hive)) { New-Item -Path $e.Hive -Force | Out-Null }
                New-ItemProperty -LiteralPath $e.Hive -Name $e.Name -Value $e.Value -PropertyType String -Force | Out-Null
                Write-Log "autostart: restored [$($e.Name)]" 'OK'
            } catch { Write-Log "autostart: [$($e.Name)] failed: $($_.Exception.Message)" 'WARN' }
        }
    }

    Write-Log 'guest: re-enabling packages' 'STEP'
    if ($Install) {
        $port = Get-AdbPort -Install $Install -Index 0
        $null = Set-RecordValue -Name 'AdbSerial' -Value (Get-AdbSerial -Install $Install -Port $port)
        $null = Set-RecordValue -Name 'AdbPort' -Value $port
    }
    if ($Install -and (Start-GuestIfNeeded -Install $Install -Index 0)) {
        $disabled = Get-DisabledPackages -Install $Install -Index 0
        $candidates = @($Script:Config.StorePackage) + @($Script:Config.StrictPackages)
        $targets = @()
        if ($null -ne $disabled) {
            $targets = @($candidates | Where-Object { $disabled -contains $_ })
        } else {
            $targets = @($Script:Config.StorePackage)   # cannot read state: try the main one
        }
        if (@($targets).Count -eq 0) {
            Write-Log 'guest: nothing disabled in guest, skipped.' 'INFO'
        }
        foreach ($pkg in $targets) {
            if ($DryRun) { Write-Log "guest: would enable $pkg" 'WARN'; continue }
            $r = Invoke-Adb -Install $Install -Index 0 -Cmd "pm enable $pkg"
            if ($r.Ok) { Write-Log "guest: $pkg enabled" 'OK' }
            else { Write-Log "guest: $pkg enable failed ($($r.Output)$($r.Error))" 'WARN' }
        }
    } else {
        Write-Log 'guest: emulator not reachable, packages left disabled (re-enable later with pm enable).' 'WARN'
    }
    return 0
}

function Invoke-Restore {
    Write-Log 'MuMu ad removal: RESTORE' 'STEP'
    $dir = Find-LatestBackup

    if (-not $dir) {
        $install = Get-MuMuInstall
        if (-not $install) {
            Write-Log 'MuMu not detected and no backup found - nothing to restore.' 'ERR'
            return 1
        }
        return (Invoke-RestoreBestEffort -Install $install)
    }

    Write-Log "Using backup: $dir" 'INFO'
    $rec = Read-Record -Dir $dir
    $Script:Record = $rec
    if (-not $Script:Record.AdbSerial) {
        $p = if ($rec.AdbPort) { [int]$rec.AdbPort } else { $null }
        $null = Set-RecordValue -Name 'AdbSerial' -Value (Get-AdbSerial -Install (Get-MuMuInstall) -Port $p)
    }

    $install = $null
    if ($rec.InstallRoot -and (Test-MuMuRoot $rec.InstallRoot)) {
        $install = [pscustomobject]@{
            Root    = $rec.InstallRoot
            Cli     = Join-Path $rec.InstallRoot 'nx_main\mumu-cli.exe'
            Adb     = Join-Path $rec.InstallRoot 'nx_main\adb.exe'
        }
        if (-not (Test-Path $install.Cli)) { $install.Cli = $null }
        if (-not (Test-Path $install.Adb)) { $install.Adb = $null }
    }

    # -- 1. hosts -----------------------------------------------------------
    Write-Log 'hosts: removing managed block' 'STEP'
    try { Remove-HostsBlock; if (-not $DryRun) { & ipconfig /flushdns 2>&1 | Out-Null } }
    catch { Write-Log "hosts: FAILED ($($_.Exception.Message))" 'ERR' }

    # -- 2. updater ---------------------------------------------------------
    Write-Log 'updater: restoring config' 'STEP'
    if ($rec -is [System.Collections.IDictionary]) { $rec['BackupDir'] = $dir } else { $rec | Add-Member -NotePropertyName BackupDir -NotePropertyValue $dir -Force }
    try { Restore-Updater -Record $rec } catch { Write-Log "updater: FAILED ($($_.Exception.Message))" 'ERR' }

    # -- 3. services + autostart -------------------------------------------
    Write-Log 'services / autostart: restoring' 'STEP'
    try {
        if ($rec.Services) { Restore-MuMuServices -Saved @($rec.Services) }
        if ($rec.Autostart) { Restore-MuMuAutostart -Saved @($rec.Autostart) }
    } catch { Write-Log "services/autostart: FAILED ($($_.Exception.Message))" 'ERR' }

    # -- 4. guest packages --------------------------------------------------
    Write-Log 'guest: re-enabling packages' 'STEP'
    $targets = @()
    if ($rec.Packages) { $targets = @($rec.Packages | Where-Object { -not $_.WasDisabled } | ForEach-Object { $_.Package }) }
    if ($targets.Count -eq 0) { $targets = @($Script:Config.StorePackage) }

    if ($install -and (Start-GuestIfNeeded -Install $install -Index $rec.PlayerIndex)) {
        foreach ($pkg in $targets) {
            if ($DryRun) { Write-Log "guest: would enable $pkg" 'WARN'; continue }
            $r = Invoke-Adb -Install $install -Index $rec.PlayerIndex -Cmd "pm enable $pkg"
            if ($r.Output -match 'new state: enabled' -or $r.Ok) {
                Write-Log "guest: $pkg enabled" 'OK'
            } else {
                Write-Log "guest: $pkg enable failed ($($r.Output)$($r.Error))" 'WARN'
            }
        }
    }

    if (-not $DryRun) {
        $doneDir = Join-Path $dir 'restored'
        try { New-Item -ItemType File -Path $doneDir -Force | Out-Null } catch { }
        Write-Log "RESTORE finished. Marker: $doneDir" 'STEP'
    }
    return 0
}

function Invoke-Verify {
    Write-Log 'MuMu ad removal: VERIFY (read-only)' 'STEP'
    $det = Invoke-Detect
    if (-not $det) { return 1 }
    $null = Set-RecordValue -Name 'AdbSerial' -Value $det.Serial
    if (-not $Script:Record.AdbPort) { $null = Set-RecordValue -Name 'AdbPort' -Value $det.Port }

    $ok = $true
    if (Test-HostsBlock) { Write-Log 'CHECK hosts block        : PRESENT' 'OK' }
    else { Write-Log 'CHECK hosts block        : MISSING' 'WARN'; $ok = $false }

    $svcBad = @($det.Services | Where-Object { $null -ne $_ -and ($_.StartMode -eq 'Auto' -or $_.State -eq 'Running') })
    if ($svcBad.Count -eq 0) { Write-Log 'CHECK services           : stopped/manual' 'OK' }
    else { Write-Log "CHECK services           : still active -> $($svcBad.Name -join ', ')" 'WARN'; $ok = $false }

    $autoList = @($det.Autostart | Where-Object { $null -ne $_ })
    if ($autoList.Count -eq 0) { Write-Log 'CHECK autostart          : clean' 'OK' }
    else { Write-Log 'CHECK autostart          : entries remain' 'WARN'; $ok = $false }

    if ($det.Install.Cli -and (Test-Path $det.Install.Cli)) {
        if (Start-GuestIfNeeded -Install $det.Install -Index $det.Index) {
            $disabled = Get-DisabledPackages -Install $det.Install -Index $det.Index
            $st = Get-PackageState -Install $det.Install -Index $det.Index -Package $Script:Config.StorePackage -DisabledList $disabled
            if ($st.Disabled) { Write-Log 'CHECK game center        : DISABLED' 'OK' }
            else { Write-Log 'CHECK game center        : STILL ENABLED' 'WARN'; $ok = $false }
        }
    }

    $upd = Get-AdbPort -Install $det.Install -Index $det.Index
    Write-Log "ADB port                 : $(if($upd){$upd}else{'<not running>'})" 'INFO'
    Write-Log "VERIFY result            : $(if($ok){'PASS'}else{'ATTENTION NEEDED'})" $(if($ok){'OK'}else{'WARN'})
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
# The guard allows dot-sourcing the file for tests/automation without running it.
$Script:IsDotSourced = $false
try {
    if ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.InvocationName -eq '&') { $Script:IsDotSourced = $true }
} catch { }

function Invoke-Main {
    Set-ConsoleUtf8

    $needsAdmin = $Action -in @('Apply','Restore')
    if ($needsAdmin -and -not (Test-Admin) -and -not $DryRun -and -not $Elevated) {
        Write-Log 'Administrator rights required - re-launching elevated (UAC) ...' 'WARN'
        $childArgs = @('-Action', $Action, '-BootTimeoutSec', "$BootTimeoutSec", '-Elevated')
        if ($NoLaunch) { $childArgs += '-NoLaunch' }
        if ($Strict)   { $childArgs += '-Strict' }
        # The elevated console is transient; always leave a log behind so a
        # silent early exit is diagnosable.
        if (-not $Transcript) {
            $Transcript = Join-Path $env:LOCALAPPDATA ('MuMu-AdBlock\logs\' +
                ('{0}-{1:yyyyMMdd-HHmmss}.log' -f $Action.ToLower(), (Get-Date)))
        }
        $childArgs += @('-Transcript', $Transcript)
        Write-Log "Elevated run log: $Transcript" 'INFO'
        try {
            $rc = Invoke-SelfElevate -Arguments $childArgs
            return [int]$rc
        } catch {
            Write-Log "Elevation failed: $($_.Exception.Message)" 'ERR'
            Write-Log 'Right-click PowerShell -> Run as administrator, then re-run.' 'ERR'
            return 1
        }
    }

    if ($needsAdmin -and -not (Test-Admin)) {
        Write-Log 'Not elevated: continuing, but system-level changes will fail.' 'WARN'
    }

    Write-Log ("MuMu-AdBlock.ps1 | action={0} | dryRun={1} | admin={2} | PS={3}" -f `
        $Action, [bool]$DryRun, (Test-Admin), $PSVersionTable.PSVersion) 'INFO'

    switch ($Action) {
        'Apply'   { return (Invoke-Apply) }
        'Restore' { return (Invoke-Restore) }
        'Verify'  { return (Invoke-Verify) }
        'Detect'  { if (Invoke-Detect) { return 0 } else { return 1 } }
    }
    return 0
}

if (-not $Script:IsDotSourced) {
    if ($Transcript) {
        try {
            $tp = [System.IO.Path]::GetFullPath($Transcript)
            $dir = Split-Path -Parent $tp
            if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Start-Transcript -Path ($tp.Trim('"')) -Force | Out-Null
        } catch { }
    }
    $code = Invoke-Main
    if ($Transcript) { try { Stop-Transcript | Out-Null } catch { } }
    exit $code
}
