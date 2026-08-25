#requires -Version 5.1

# ================= HOMELAB-TUI =================

$Global:ContentWidth = 62
$Global:ThemeNames   = @("Dark","Matrix","Synthwave","Light")
$Global:ThemeIndex   = 0
$Global:FontSize     = 24
$Global:StatusCache  = @{}

# MenuCols/MenuMinRows are the minimum the art needs - used to cap the font.
$Global:MenuCols   = $Global:ContentWidth + 4
$Global:AppMinCols = 80
$Global:AppMinRows = 25
$Global:MenuMinRows = 27   # rows the banner + a panel + the hint bar need

if ($PSScriptRoot) {
    $Global:ConfigPath = Join-Path $PSScriptRoot "homelab-tui.config.json"
} else {
    $Global:ConfigPath = $null
}

$Global:Themes = @{
    "Dark"      = @{ BG="Black"; Border="Cyan";        Title="White"; Shadow="DarkCyan";    Accent="Magenta";     Text="Gray";      Success="Green";     Warn="Yellow";     Danger="Red";     HiBG="Cyan";     HiFG="Black" }
    "Matrix"    = @{ BG="Black"; Border="Green";       Title="Green"; Shadow="DarkGreen";   Accent="Green";       Text="DarkGreen"; Success="Green";     Warn="Yellow";     Danger="Red";     HiBG="Green";    HiFG="Black" }
    "Synthwave" = @{ BG="Black"; Border="Magenta";     Title="Cyan";  Shadow="DarkMagenta"; Accent="Magenta";     Text="DarkCyan";  Success="Cyan";      Warn="Yellow";     Danger="Red";     HiBG="Magenta";  HiFG="Black" }
    "Light"     = @{ BG="White"; Border="DarkCyan";    Title="Black"; Shadow="Gray";        Accent="DarkMagenta"; Text="DarkGray";  Success="DarkGreen"; Warn="DarkYellow"; Danger="DarkRed"; HiBG="DarkCyan"; HiFG="White" }
}

# Servers live in the config file, not here - add them with [ + ] in the UI.
$Global:Servers = @()

# ==================== FORKING THIS? START HERE ====================
# Every assumption about a particular server lives in this one table. The rest
# of the file is UI and knows nothing about what the commands actually are.
# To point it at your own setup, edit these strings and nothing else.
$Global:Cmd = @{
    Btop      = "btop"                     # whatever your live-stats tool is
    SitesDir  = "/var/www/sites"           # one directory holding site checkouts
    Deploy    = "cd {0} && git pull"       # {0} = SitesDir/<the site you picked>
    Shutdown  = "sudo shutdown now"
    PiholeTui = "~/.local/bin/pihole-tui"  # installed by pihole-tui/install.sh
    Pihole    = "pihole"                   # docker container name
}
# To add a whole new action: add one entry to $Global:ToolCatalog, then one
# case to the switch in Show-ServerScreen. Those are the only two places.
# ===================================================================

function Get-Theme { return $Global:Themes[$Global:ThemeNames[$Global:ThemeIndex]] }

# ---------------- Config (theme, font size, server list) ----------------
function Import-HlConfig {
    if (-not $Global:ConfigPath) { return }
    if (-not (Test-Path $Global:ConfigPath)) { return }
    try {
        $cfg = Get-Content -Raw -Path $Global:ConfigPath | ConvertFrom-Json
        if ($cfg.Theme) {
            $i = [Array]::IndexOf($Global:ThemeNames, [string]$cfg.Theme)
            if ($i -ge 0) { $Global:ThemeIndex = $i }
        }
        if ($cfg.FontSize) { $Global:FontSize = [int]$cfg.FontSize }
        # property-presence test, not truthiness - an empty list is falsy in PS
        if ($cfg.PSObject.Properties.Name -contains "Servers") {
            $list = @()
            foreach ($s in @($cfg.Servers)) {
                if (-not $s.IP) { continue }
                $name = $s.Name; if (-not $name) { $name = [string]$s.IP }
                $user = $s.User; if (-not $user) { $user = "root" }
                $entry = @{ Name = [string]$name; IP = [string]$s.IP; User = [string]$user }
                # optional per-server overrides, carried through untouched so
                # editing a server in the UI cannot silently drop them
                if ($s.PiholeContainer) { $entry.PiholeContainer = [string]$s.PiholeContainer }
                if ($s.PiholePort)      { $entry.PiholePort      = [int]$s.PiholePort }
                if ($s.PSObject.Properties.Name -contains "Tools") { $entry.Tools = @($s.Tools) }
                $list += $entry
            }
            $Global:Servers = $list
        }
    } catch { }
}

function Export-HlConfig {
    if (-not $Global:ConfigPath) { return }
    try {
        $list = @()
        foreach ($s in @($Global:Servers)) {
            $o = [ordered]@{ Name = $s.Name; IP = $s.IP; User = $s.User }
            if ($s.PiholeContainer) { $o.PiholeContainer = $s.PiholeContainer }
            if ($s.PiholePort)      { $o.PiholePort      = $s.PiholePort }
            if ($null -ne $s.Tools)  { $o.Tools           = @($s.Tools) }
            $list += [PSCustomObject]$o
        }
        $obj = [PSCustomObject]@{
            Theme    = $Global:ThemeNames[$Global:ThemeIndex]
            FontSize = $Global:FontSize
            Servers  = @($list)
        }
        $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:ConfigPath -Encoding UTF8
    } catch { }
}

# ---------------- Console font / window sizing ----------------
$Global:ConsoleApiOk = $false
try {
    Add-Type -Namespace HL -Name Con -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)]
public struct COORD { public short X; public short Y; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CONSOLE_FONT_INFO_EX {
    public uint  cbSize;
    public uint  nFont;
    public COORD dwFontSize;
    public int   FontFamily;
    public int   FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFO_EX lpConsoleCurrentFontEx);
"@ -ErrorAction Stop
    $Global:ConsoleApiOk = $true
} catch {
    $Global:ConsoleApiOk = $false
}

function Set-ConsoleFontSize([int]$size) {
    if (-not $Global:ConsoleApiOk) { return }
    try {
        $handle = [HL.Con]::GetStdHandle(-11)
        $info = New-Object -TypeName "HL.Con+CONSOLE_FONT_INFO_EX"
        $info.cbSize     = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"HL.Con+CONSOLE_FONT_INFO_EX")
        $info.FontFamily = 54          # FF_MODERN | TMPF_VECTOR | TMPF_TRUETYPE
        $info.FontWeight = 400
        $info.FaceName   = "Consolas"
        $coord = New-Object -TypeName "HL.Con+COORD"
        $coord.X = 0                   # 0 = let Windows pick the matching width
        $coord.Y = [int16]$size
        $info.dwFontSize = $coord
        [void][HL.Con]::SetCurrentConsoleFontEx($handle, $false, [ref]$info)
    } catch { }
}

function Set-ConsoleSize([int]$w, [int]$h) {
    try {
        $ui = $Host.UI.RawUI
        $phys = $ui.MaxPhysicalWindowSize
        if ($w -gt $phys.Width)  { $w = $phys.Width }
        if ($h -gt $phys.Height) { $h = $phys.Height }

        # shrink the window first so the buffer is free to change
        $cur = $ui.WindowSize
        $tmp = $ui.WindowSize
        $tmp.Width  = [Math]::Min($cur.Width,  $w)
        $tmp.Height = [Math]::Min($cur.Height, $h)
        $ui.WindowSize = $tmp

        $buf = $ui.BufferSize
        $buf.Width  = $w
        $buf.Height = 3000
        $ui.BufferSize = $buf

        $win = $ui.WindowSize
        $win.Width  = $w
        $win.Height = $h
        $ui.WindowSize = $win
    } catch { }
}

# Fill the screen. Panels stay 62 wide and sit at the left.
function Set-WindowFit {
    $phys = $Host.UI.RawUI.MaxPhysicalWindowSize
    Set-ConsoleSize $phys.Width $phys.Height
}

# btop won't draw under 80x24 and the menu window is narrower than that.
# Widen for the remote app, dropping the font only if 80x25 won't fit.
function Enter-AppConsole {
    $size = $Global:FontSize
    while ($true) {
        Set-ConsoleFontSize $size
        $phys = $Host.UI.RawUI.MaxPhysicalWindowSize
        if ($phys.Width -ge $Global:AppMinCols -and $phys.Height -ge $Global:AppMinRows) { break }
        if ($size -le 10) { break }
        $size = $size - 2
    }
    Set-WindowFit
    [Console]::CursorVisible = $true
}

function Exit-AppConsole {
    Set-ConsoleFontSize $Global:FontSize
    Set-WindowFit
    [Console]::CursorVisible = $false
}

function Test-MenuFits {
    $phys = $Host.UI.RawUI.MaxPhysicalWindowSize
    return ($phys.Height -ge $Global:MenuMinRows -and $phys.Width -ge $Global:MenuCols)
}

function Set-FontSize([int]$size) {
    $size = [Math]::Max(10, [Math]::Min(48, $size))
    $prev = $Global:FontSize
    Set-ConsoleFontSize $size
    # growing past what the screen can show would clip the banner - stay put
    if ($size -gt $prev -and -not (Test-MenuFits)) {
        Set-ConsoleFontSize $prev
        Set-WindowFit
        return
    }
    $Global:FontSize = $size
    Set-WindowFit
    Export-HlConfig
}

# Saved size may come from a bigger monitor - step down until the menu fits.
function Initialize-Font {
    $size = $Global:FontSize
    while ($true) {
        Set-ConsoleFontSize $size
        if ((Test-MenuFits) -or $size -le 10) { break }
        $size = $size - 2
    }
    $Global:FontSize = $size
    Set-WindowFit
}

function Set-ThemeConsole {
    $t = Get-Theme
    [Console]::BackgroundColor = $t.BG
    [Console]::ForegroundColor = $t.Text
    Clear-Host
}

# ---------------- Text helpers ----------------
function Seg($text, $color) { return @{ Text = [string]$text; Color = $color } }

function Fit($text, $n) {
    $s = [string]$text
    if ($s.Length -gt $n) { return $s.Substring(0, $n) }
    return $s.PadRight($n)
}

function Center-Text($text) {
    if ($text.Length -ge $Global:ContentWidth) { return $text.Substring(0, $Global:ContentWidth) }
    $total = $Global:ContentWidth - $text.Length
    $left  = [int][Math]::Floor($total / 2)
    return (" " * $left) + $text + (" " * ($total - $left))
}

# ---------------- Box drawing ----------------
function Write-TitleTop($t)    { Write-Host ("╔" + ("═" * $Global:ContentWidth) + "╗") -ForegroundColor $t.Border }
function Write-TitleBottom($t) { Write-Host ("╚" + ("═" * $Global:ContentWidth) + "╝") -ForegroundColor $t.Border }
function Write-PanelTop($t)    { Write-Host ("┌" + ("─" * $Global:ContentWidth) + "┐") -ForegroundColor $t.Border }
function Write-PanelMid($t)    { Write-Host ("├" + ("─" * $Global:ContentWidth) + "┤") -ForegroundColor $t.Border }
function Write-PanelBottom($t) { Write-Host ("└" + ("─" * $Global:ContentWidth) + "┘") -ForegroundColor $t.Border }

# -Selected discards the per-segment colors and inverts the whole row.
function Write-Row {
    param(
        $Segments,
        $t,
        [switch]$Selected,
        [string]$Left  = "│",
        [string]$Right = "│"
    )
    Write-Host $Left -ForegroundColor $t.Border -NoNewline
    if ($Selected) {
        $line = ""
        foreach ($s in $Segments) { $line += $s.Text }
        if ($line.Length -gt $Global:ContentWidth) { $line = $line.Substring(0, $Global:ContentWidth) }
        Write-Host $line.PadRight($Global:ContentWidth) -ForegroundColor $t.HiFG -BackgroundColor $t.HiBG -NoNewline
    } else {
        $used = 0
        foreach ($s in $Segments) {
            if ($used -ge $Global:ContentWidth) { break }
            $txt = $s.Text
            if ($used + $txt.Length -gt $Global:ContentWidth) { $txt = $txt.Substring(0, $Global:ContentWidth - $used) }
            if ($txt.Length -gt 0) { Write-Host $txt -ForegroundColor $s.Color -NoNewline }
            $used += $txt.Length
        }
        if ($used -lt $Global:ContentWidth) { Write-Host (" " * ($Global:ContentWidth - $used)) -NoNewline }
    }
    Write-Host $Right -ForegroundColor $t.Border
}

function Write-TextRow($text, $t, $color) {
    Write-Row @( (Seg $text $color) ) $t
}

function Write-TabRow($tabs, $active, $t) {
    Write-Host "│" -ForegroundColor $t.Border -NoNewline
    Write-Host " " -NoNewline
    $used = 1
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $label = " " + $tabs[$i] + " "
        if ($i -eq $active) {
            Write-Host $label -ForegroundColor $t.HiFG -BackgroundColor $t.HiBG -NoNewline
        } else {
            Write-Host $label -ForegroundColor $t.Text -NoNewline
        }
        $used += $label.Length
        if ($i -lt $tabs.Count - 1) {
            Write-Host "│" -ForegroundColor $t.Border -NoNewline
            $used++
        }
    }
    if ($used -lt $Global:ContentWidth) { Write-Host (" " * ($Global:ContentWidth - $used)) -NoNewline }
    Write-Host "│" -ForegroundColor $t.Border
}

# ---------------- Block-letter banner ----------------
$Global:Glyphs = @{
    "H" = @("██   ██","██   ██","███████","██   ██","██   ██")
    "O" = @(" █████ ","██   ██","██   ██","██   ██"," █████ ")
    "M" = @("██   ██","███ ███","██ █ ██","██   ██","██   ██")
    "E" = @("███████","██     ","█████  ","██     ","███████")
    "L" = @("██     ","██     ","██     ","██     ","███████")
    "A" = @(" █████ ","██   ██","███████","██   ██","██   ██")
    "B" = @("██████ ","██   ██","██████ ","██   ██","██████ ")
}

function Get-BannerRows($word) {
    $rows = @("","","","","")
    $chars = $word.ToCharArray()
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $glyph = $Global:Glyphs["$($chars[$i])"]
        for ($r = 0; $r -lt 5; $r++) {
            if ($i -gt 0) { $rows[$r] = $rows[$r] + " " }
            $rows[$r] = $rows[$r] + $glyph[$r]
        }
    }
    return $rows
}

# Batches runs of one color into a single Write-Host. Per-character writes
# here are slow enough to see the banner draw.
function Write-BannerLine($main, $shadow, $t) {
    Write-Host "║" -ForegroundColor $t.Border -NoNewline
    $buf = ""
    $curColor = $t.Text
    for ($i = 0; $i -lt $Global:ContentWidth; $i++) {
        if ($main[$i] -eq "█") {
            $ch = "█"; $col = $t.Title
        } elseif ($shadow[$i] -eq "█") {
            $ch = "▒"; $col = $t.Shadow
        } else {
            $ch = " "; $col = $t.Text
        }
        if ($col -ne $curColor) {
            if ($buf.Length -gt 0) { Write-Host $buf -ForegroundColor $curColor -NoNewline }
            $buf = ""
            $curColor = $col
        }
        $buf = $buf + $ch
    }
    if ($buf.Length -gt 0) { Write-Host $buf -ForegroundColor $curColor -NoNewline }
    Write-Host "║" -ForegroundColor $t.Border
}

function Show-Title($t) {
    $rows  = Get-BannerRows "HOMELAB"
    $span  = $rows[0].Length + 1                      # +1 for the shadow offset
    $left  = [int][Math]::Max(0, [Math]::Floor(($Global:ContentWidth - $span) / 2))
    $pad   = " " * $left
    $blank = " " * $Global:ContentWidth

    Write-TitleTop $t
    for ($r = 0; $r -le 5; $r++) {
        if ($r -lt 5) { $main = ($pad + $rows[$r]).PadRight($Global:ContentWidth) } else { $main = $blank }
        if ($r -gt 0) { $shad = ($pad + " " + $rows[$r - 1]).PadRight($Global:ContentWidth) } else { $shad = $blank }
        Write-BannerLine $main $shad $t
    }
    Write-Row @( (Seg (Center-Text "░▒▓█ T U I █▓▒░") $t.Accent) ) $t -Left "║" -Right "║"
    Write-TitleBottom $t
    Write-Host ""
}

# ---------------- Status check (cached; [R] refreshes) ----------------
function Get-Status($ip, [switch]$Force) {
    if (-not $Force -and $Global:StatusCache.ContainsKey($ip)) { return $Global:StatusCache[$ip] }
    $ok = $false
    try {
        $ping  = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($ip, 800)
        $ok    = ($reply.Status -eq "Success")
    } catch {
        $ok = $false
    }
    $Global:StatusCache[$ip] = $ok
    return $ok
}

function Get-StatusSegment($ip, $t) {
    if (Get-Status $ip) { return (Seg "█ ONLINE"  $t.Success) }
    return (Seg "░ OFFLINE" $t.Danger)
}

function Reset-StatusCache { $Global:StatusCache = @{} }

# ---------------- Server discovery ----------------
# Three sources, cheapest first: known_hosts, the ARP cache, then a port-22
# sweep. Keep the sweep on async BeginConnect - Test-NetConnection turns
# ~1 second into several minutes.

# Gateway interface only, so the sweep skips VirtualBox/Hyper-V/WSL adapters.
function Get-LanPrefix {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
                 Sort-Object RouteMetric | Select-Object -First 1
        if (-not $route) { return $null }
        $addr = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if (-not $addr) { return $null }
        $o = $addr.IPAddress -split '\.'
        return @{ Prefix = ($o[0] + "." + $o[1] + "." + $o[2]); Self = $addr.IPAddress }
    } catch { return $null }
}

function Get-KnownHostEntries {
    $path = Join-Path $env:USERPROFILE ".ssh\known_hosts"
    if (-not (Test-Path $path)) { return @() }
    $out = @()
    foreach ($line in (Get-Content $path -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        if ($line.StartsWith("#")) { continue }
        $first = ($line -split '\s+')[0]
        if ($first.StartsWith("|")) { continue }        # HashKnownHosts entry - not readable
        foreach ($entry in ($first -split ',')) {
            if ($entry -match '^\[(.+)\]:\d+$') { $entry = $matches[1] }   # [host]:port form
            if ($entry -and ($out -notcontains $entry)) { $out += $entry }
        }
    }
    return $out
}

function Get-ArpHosts($prefix) {
    try {
        return @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -like "$prefix.*" -and
                $_.State -ne "Unreachable" -and
                $_.State -ne "Permanent" -and
                $_.LinkLayerAddress -and
                $_.LinkLayerAddress -ne "FF-FF-FF-FF-FF-FF"
            } | Select-Object -ExpandProperty IPAddress)
    } catch { return @() }
}

# Fires every connect at once, waits once, then collects. ~800ms for a /24.
function Get-OpenSshHosts($ips, $waitMs) {
    $probes = @()
    foreach ($ip in $ips) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $probes += [PSCustomObject]@{ IP = $ip; Client = $c; Async = $c.BeginConnect($ip, 22, $null, $null) }
        } catch { }
    }
    [System.Threading.Thread]::Sleep($waitMs)
    $open = @()
    foreach ($p in $probes) {
        try { if ($p.Async.AsyncWaitHandle.WaitOne(0) -and $p.Client.Connected) { $open += $p.IP } } catch { }
        try { $p.Client.Close() } catch { }
    }
    return $open
}

# Used to tell an actual server apart from something else with 22 open.
function Get-SshBanner($ip) {
    try {
        $c  = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($ip, 22, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(800)) { $c.Close(); return "" }
        $c.EndConnect($ar)
        $s = $c.GetStream()
        $s.ReadTimeout = 1200
        $buf = New-Object byte[] 128
        $n = $s.Read($buf, 0, 128)
        $c.Close()
        return ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)).Trim()
    } catch { return "" }
}

function Test-ServerKnown($ip) {
    foreach ($s in @($Global:Servers)) { if ($s.IP -eq $ip) { return $true } }
    return $false
}

function Find-ServerCandidates {
    $sources = @{}
    foreach ($h in (Get-KnownHostEntries)) { if (-not $sources.ContainsKey($h)) { $sources[$h] = "known_hosts" } }

    $lan = Get-LanPrefix
    if ($lan) {
        foreach ($ip in (Get-ArpHosts $lan.Prefix)) {
            if ($ip -ne $lan.Self -and -not $sources.ContainsKey($ip)) { $sources[$ip] = "arp" }
        }
        $sweep = @()
        foreach ($i in 1..254) {
            $ip = $lan.Prefix + "." + $i
            if ($ip -ne $lan.Self) { $sweep += $ip }
        }
        foreach ($ip in (Get-OpenSshHosts $sweep 900)) {
            if (-not $sources.ContainsKey($ip)) { $sources[$ip] = "scan" }
        }
    }

    # one batched re-probe so known_hosts/arp entries get an accurate open flag
    $all  = @($sources.Keys)
    $open = @(Get-OpenSshHosts $all 900)

    $results = @()
    foreach ($ip in $all) {
        $isOpen = ($open -contains $ip)
        $banner = ""
        if ($isOpen) { $banner = Get-SshBanner $ip }
        $results += [PSCustomObject]@{
            IP      = $ip
            Source  = $sources[$ip]
            Open    = $isOpen
            Banner  = $banner
            Added   = (Test-ServerKnown $ip)
        }
    }
    return @($results | Sort-Object @{Expression={-not $_.Open}}, @{Expression={$_.Added}}, IP)
}

# ---------------- Key reading ----------------
# Single choke point for keyboard input - everything below goes through it.
function Get-RawKey { return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }

function Read-NavKey {
    $key = Get-RawKey
    if ($key.VirtualKeyCode -eq 38) { return "Up" }
    if ($key.VirtualKeyCode -eq 40) { return "Down" }
    if ($key.VirtualKeyCode -eq 37) { return "Left" }
    if ($key.VirtualKeyCode -eq 39) { return "Right" }
    if ($key.VirtualKeyCode -eq 13) { return "Enter" }
    if ($key.VirtualKeyCode -eq 9)  { return "Tab" }
    if ($key.VirtualKeyCode -eq 27) { return "Escape" }
    if ($key.VirtualKeyCode -eq 33) { return "PageUp" }
    if ($key.VirtualKeyCode -eq 34) { return "PageDown" }
    if ($key.VirtualKeyCode -eq 46) { return "Delete" }
    if ($key.Character) { return $key.Character.ToString().ToUpper() }
    return ""
}

function Pause-Screen($t) {
    Write-Host ""
    Write-Host "  ░▒▓ Press any key to continue ▓▒░" -ForegroundColor $t.Text
    $null = Get-RawKey
}

# ---------------- Theme tab ----------------
function Write-ThemePanel($t) {
    for ($i = 0; $i -lt $Global:ThemeNames.Count; $i++) {
        $name = $Global:ThemeNames[$i]
        $th   = $Global:Themes[$name]
        $sel  = ($i -eq $Global:ThemeIndex)
        if ($sel) { $marker = "██ " } else { $marker = "   " }
        $segs = @(
            (Seg $marker $t.Accent),
            (Seg $name.PadRight(12) $t.Text),
            (Seg "████" $th.Border),
            (Seg "████" $th.Accent),
            (Seg "████" $th.Success),
            (Seg "████" $th.Danger),
            (Seg "  ░▒▓█" $th.Title)
        )
        Write-Row $segs $t -Selected:$sel
    }
}

# Moving the selection applies the theme immediately - there is no confirm step.
function Invoke-ThemeKey($key) {
    if ($key -eq "Up") {
        if ($Global:ThemeIndex -gt 0) { $Global:ThemeIndex-- } else { $Global:ThemeIndex = $Global:ThemeNames.Count - 1 }
        Export-HlConfig
        return $true
    }
    if ($key -eq "Down") {
        $Global:ThemeIndex = ($Global:ThemeIndex + 1) % $Global:ThemeNames.Count
        Export-HlConfig
        return $true
    }
    return $false
}

# ---------------- Add / edit / delete servers ----------------
# Hand-rolled because Read-Host swallows Escape - there is no way to abandon
# one of its prompts. Returns $null when the user backs out.
# Enter on an empty buffer takes $default; with no default it keeps waiting.
function Read-Field($label, $default, $t) {
    Write-Host ""
    if ($default) {
        Write-Host ("  ▓ " + $label + " [" + $default + "] > ") -ForegroundColor $t.Accent -NoNewline
    } else {
        Write-Host ("  ▓ " + $label + " > ") -ForegroundColor $t.Accent -NoNewline
    }
    [Console]::CursorVisible = $true
    $buf = ""
    while ($true) {
        $k = Get-RawKey
        if ($k.VirtualKeyCode -eq 27) {                       # Escape
            [Console]::CursorVisible = $false
            Write-Host ""
            return $null
        }
        if ($k.VirtualKeyCode -eq 13) {                       # Enter
            $val = $buf.Trim()
            if (-not $val) { $val = $default }
            if (-not $val) { continue }
            [Console]::CursorVisible = $false
            Write-Host ""
            return $val
        }
        if ($k.VirtualKeyCode -eq 8) {                        # Backspace
            if ($buf.Length -gt 0) {
                $buf = $buf.Substring(0, $buf.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
            continue
        }
        $ch = $k.Character
        if ($ch -and [int]$ch -ge 32 -and [int]$ch -ne 127) {
            $buf = $buf + $ch
            Write-Host $ch -NoNewline -ForegroundColor $t.Text
        }
    }
}

# y / n / Escape. Escape and n both mean no.
function Read-Confirm($question, $t) {
    Write-Host ""
    Write-Host ("  ░▒▓ " + $question + " ") -ForegroundColor $t.Danger -NoNewline
    Write-Host "[y/n] " -ForegroundColor $t.Accent -NoNewline
    while ($true) {
        $k = Get-RawKey
        if ($k.VirtualKeyCode -eq 27) { Write-Host ""; return $false }
        $ch = "$($k.Character)".ToUpper()
        if ($ch -eq "Y") { Write-Host "y" -ForegroundColor $t.Success; return $true }
        if ($ch -eq "N") { Write-Host "n" -ForegroundColor $t.Text;    return $false }
    }
}

function Show-EntryHeader($title, $t) {
    Set-ThemeConsole
    Write-Host ""
    Show-Title $t
    Write-PanelTop $t
    Write-TabRow @($title) 0 $t
    Write-PanelMid $t
}

# $false means the user backed out and nothing was written.
function Add-ServerEntry($ip, $t) {
    $lastUser = "root"
    if (@($Global:Servers).Count -gt 0) { $lastUser = $Global:Servers[-1].User }

    Show-EntryHeader "NEW SERVER" $t
    Write-TextRow ("   ▓ Address : " + $ip) $t $t.Text
    Write-TextRow "   ░ [Esc] backs out at any prompt" $t $t.Shadow
    Write-PanelBottom $t

    $name = Read-Field "Name" $ip $t
    if ($null -eq $name) { return $false }
    $user = Read-Field "SSH user" $lastUser $t
    if ($null -eq $user) { return $false }
    if (-not (Read-Confirm ("Add " + $name + " (" + $user + "@" + $ip + ")?") $t)) { return $false }

    $Global:Servers = @($Global:Servers) + @(@{ Name = $name; IP = $ip; User = $user })
    Export-HlConfig
    Reset-StatusCache

    Write-Host ""
    Write-Host ("  █ Added " + $name + " (" + $user + "@" + $ip + ")") -ForegroundColor $t.Success
    Pause-Screen $t
    return $true
}

function Edit-ServerEntry($index, $t) {
    $s = $Global:Servers[$index]

    Show-EntryHeader "EDIT SERVER" $t
    Write-TextRow ("   ▓ Editing : " + $s.Name) $t $t.Text
    Write-TextRow "   ░ [Enter] keeps the current value, [Esc] backs out" $t $t.Shadow
    Write-PanelBottom $t

    $name = Read-Field "Name" $s.Name $t
    if ($null -eq $name) { return $false }
    $ip = Read-Field "Address" $s.IP $t
    if ($null -eq $ip) { return $false }
    $user = Read-Field "SSH user" $s.User $t
    if ($null -eq $user) { return $false }

    if ($name -eq $s.Name -and $ip -eq $s.IP -and $user -eq $s.User) { return $false }
    if (-not (Read-Confirm ("Save " + $name + " (" + $user + "@" + $ip + ")?") $t)) { return $false }

    $Global:Servers[$index] = @{ Name = $name; IP = $ip; User = $user }
    Export-HlConfig
    Reset-StatusCache

    Write-Host ""
    Write-Host ("  █ Saved " + $name + " (" + $user + "@" + $ip + ")") -ForegroundColor $t.Success
    Pause-Screen $t
    return $true
}

function Show-EditServerScreen($t) {
    if (@($Global:Servers).Count -eq 0) { return }
    $sel = 0

    while ($true) {
        $t = Get-Theme
        Show-EntryHeader "EDIT SERVER" $t
        for ($i = 0; $i -lt $Global:Servers.Count; $i++) {
            $s = $Global:Servers[$i]
            if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
            $segs = @(
                (Seg $marker $t.Accent),
                (Seg ((Fit $s.Name 20) + (Fit $s.IP 17) + (Fit $s.User 12)) $t.Text)
            )
            Write-Row $segs $t -Selected:($i -eq $sel)
        }
        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        Write-TextRow " ▓ [Up/Dn] Move    [Enter] Edit    [B] Back" $t $t.Text
        Write-PanelBottom $t

        $key = Read-NavKey
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "Up")   { if ($sel -gt 0) { $sel-- } }
        if ($key -eq "Down") { if ($sel -lt $Global:Servers.Count - 1) { $sel++ } }
        if ($key -eq "Enter") { [void](Edit-ServerEntry $sel $t) }
    }
}

function Show-AddServerScreen($t) {
    Show-EntryHeader "ADD SERVER" $t
    Write-TextRow "   ░▒▓ Scanning known hosts, ARP and port 22 ..." $t $t.Warn
    Write-PanelBottom $t
    $cands = Find-ServerCandidates
    $sel = 0
    $top = 0
    # a busy LAN can turn up 30+ ARP entries, so the list scrolls
    $pageSize = [Math]::Max(3, [Math]::Min(12, $Host.UI.RawUI.WindowSize.Height - 22))

    while ($true) {
        $t = Get-Theme
        Show-EntryHeader "ADD SERVER" $t

        if ($cands.Count -eq 0) {
            Write-TextRow "   ░ Nothing found - press [M] to enter one by hand." $t $t.Warn
        } else {
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $pageSize) { $top = $sel - $pageSize + 1 }
            $last = [Math]::Min($cands.Count - 1, $top + $pageSize - 1)
            for ($i = $top; $i -le $last; $i++) {
                $c = $cands[$i]
                if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
                if ($c.Added)     { $tag = "already added"; $tagColor = $t.Warn }
                elseif ($c.Open)  { $tag = $c.Banner;       $tagColor = $t.Success }
                else              { $tag = "no ssh";        $tagColor = $t.Shadow }
                $segs = @(
                    (Seg $marker $t.Accent),
                    (Seg (Fit $c.IP 16) $t.Text),
                    (Seg (Fit $c.Source 12) $t.Shadow),
                    (Seg (Fit $tag 22) $tagColor)
                )
                Write-Row $segs $t -Selected:($i -eq $sel)
            }
            if ($cands.Count -gt $pageSize) {
                Write-TextRow ("   ░ showing {0}-{1} of {2}" -f ($top + 1), ($last + 1), $cands.Count) $t $t.Shadow
            }
        }
        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        Write-TextRow " ▓ [Up/Dn] Move    [Enter] Add    [M] Enter by hand" $t $t.Text
        Write-TextRow " ▓ [R] Rescan      [B] Back" $t $t.Text
        Write-PanelBottom $t

        $key = Read-NavKey
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "R") {
            Show-EntryHeader "ADD SERVER" $t
            Write-TextRow "   ░▒▓ Rescanning ..." $t $t.Warn
            Write-PanelBottom $t
            $cands = Find-ServerCandidates
            $sel = 0
            $top = 0
            continue
        }
        if ($key -eq "M") {
            Show-EntryHeader "ADD SERVER" $t
            Write-TextRow "   ▓ Hostname or IP - anything ssh can reach." $t $t.Text
            Write-TextRow "   ░ [Esc] backs out at any prompt" $t $t.Shadow
            Write-PanelBottom $t
            $ip = Read-Field "Address" "" $t
            if ($null -ne $ip -and (Add-ServerEntry $ip $t)) { return }
            continue
        }
        if ($cands.Count -eq 0) { continue }
        if ($key -eq "Up")   { if ($sel -gt 0) { $sel-- } }
        if ($key -eq "Down") { if ($sel -lt $cands.Count - 1) { $sel++ } }
        if ($key -eq "Enter") {
            $c = $cands[$sel]
            if ($c.Added) { continue }
            if (Add-ServerEntry $c.IP $t) { return }   # backed out - stay on the list
        }
    }
}

function Show-DeleteServerScreen($t) {
    if (@($Global:Servers).Count -eq 0) { return }
    $sel = 0

    while ($true) {
        $t = Get-Theme
        Show-EntryHeader "DELETE SERVER" $t
        for ($i = 0; $i -lt $Global:Servers.Count; $i++) {
            $s = $Global:Servers[$i]
            if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
            $segs = @(
                (Seg $marker $t.Danger),
                (Seg ((Fit $s.Name 20) + (Fit $s.IP 17) + (Fit $s.User 12)) $t.Text)
            )
            Write-Row $segs $t -Selected:($i -eq $sel)
        }
        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        Write-TextRow " ▓ [Up/Dn] Move    [Enter] Remove from list    [B] Back" $t $t.Text
        Write-TextRow " ▓ This only forgets the entry - the server is untouched." $t $t.Shadow
        Write-PanelBottom $t

        $key = Read-NavKey
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "Up")   { if ($sel -gt 0) { $sel-- } }
        if ($key -eq "Down") { if ($sel -lt $Global:Servers.Count - 1) { $sel++ } }
        if ($key -eq "Enter") {
            $victim = $Global:Servers[$sel]
            Show-EntryHeader "DELETE SERVER" $t
            Write-TextRow ("   ▓ " + $victim.Name + "  (" + $victim.User + "@" + $victim.IP + ")") $t $t.Text
            Write-TextRow "   ░ [Esc] or [n] backs out" $t $t.Shadow
            Write-PanelBottom $t
            if (Read-Confirm "Remove this entry from the list?" $t) {
                $keep = @()
                for ($j = 0; $j -lt $Global:Servers.Count; $j++) {
                    if ($j -ne $sel) { $keep += $Global:Servers[$j] }
                }
                $Global:Servers = $keep
                Export-HlConfig
                Reset-StatusCache
                if (@($Global:Servers).Count -eq 0) { return }
                if ($sel -ge $Global:Servers.Count) { $sel = $Global:Servers.Count - 1 }
            }
        }
    }
}

# ---------------- Main menu (server list) ----------------
$Global:MainTabs = @("SERVERS","THEMES")

$Global:RowActions = @(" [ + ] Add ", " [ e ] Edit ", " [ - ] Delete ")

# $col is which button is active - Left/Right moves it instead of changing tab.
function Write-ActionRow($col, $selected, $t) {
    $colors = @($t.Success, $t.Accent, $t.Danger)
    $lead   = "  "
    $width  = 0
    foreach ($l in $Global:RowActions) { $width += $l.Length }
    $slack  = $Global:ContentWidth - $lead.Length - $width
    $gap    = [int][Math]::Floor($slack / 2)

    Write-Host "│" -ForegroundColor $t.Border -NoNewline
    Write-Host $lead -NoNewline
    $used = $lead.Length
    for ($i = 0; $i -lt $Global:RowActions.Count; $i++) {
        $label = $Global:RowActions[$i]
        if ($selected -and $col -eq $i) {
            Write-Host $label -ForegroundColor $t.HiFG -BackgroundColor $t.HiBG -NoNewline
        } else {
            Write-Host $label -ForegroundColor $colors[$i] -NoNewline
        }
        $used += $label.Length
        if ($i -lt $Global:RowActions.Count - 1 -and $gap -gt 0) {
            Write-Host (" " * $gap) -NoNewline
            $used += $gap
        }
    }
    if ($used -lt $Global:ContentWidth) { Write-Host (" " * ($Global:ContentWidth - $used)) -NoNewline }
    Write-Host "│" -ForegroundColor $t.Border
}

function Show-MainMenu($selected, $tab, $actionCol) {
    $t = Get-Theme
    Set-ThemeConsole
    Write-Host ""
    Show-Title $t

    Write-PanelTop $t
    Write-TabRow $Global:MainTabs $tab $t
    Write-PanelMid $t

    if ($tab -eq 0) {
        $count = @($Global:Servers).Count
        if ($count -eq 0) {
            Write-TextRow "   ░ No servers yet - select [ + ] below to add one." $t $t.Warn
        }
        for ($i = 0; $i -lt $count; $i++) {
            $s = $Global:Servers[$i]
            if ($i -eq $selected) { $marker = "██ " } else { $marker = "   " }
            $segs = @(
                (Seg $marker $t.Accent),
                (Seg ("[{0}] " -f ($i + 1)) $t.Text),
                (Seg ((Fit $s.Name 20) + (Fit $s.IP 17)) $t.Text),
                (Get-StatusSegment $s.IP $t)
            )
            Write-Row $segs $t -Selected:($i -eq $selected)
        }
        Write-PanelMid $t
        Write-ActionRow $actionCol ($selected -eq $count) $t
    } else {
        Write-ThemePanel $t
    }

    Write-PanelBottom $t
    Write-Host ""
    Write-PanelTop $t
    Write-TextRow " ▓ [Up/Dn] Move    [Tab] Tabs    [Enter] Select" $t $t.Text
    Write-TextRow " ▓ [+] Add    [E] Edit    [-] Delete" $t $t.Text
    Write-TextRow " ▓ [R] Refresh    [PgUp/PgDn] Font    [Q] Quit" $t $t.Text
    Write-PanelBottom $t
}

# ---------------- Server detail (tabs: Actions / Info / Themes) ----------------
# ---------------- Per-server tool list ----------------
# Which actions a server offers. No Tools key in the config means all of them,
# so entries written before this existed keep working untouched.
$Global:ToolCatalog = @(
    @{ Key = "ssh";      Label = "Connect (SSH)" },
    @{ Key = "deploy";   Label = "Deploy site" },
    @{ Key = "btop";     Label = "Live stats (btop)" },
    @{ Key = "pihole";   Label = "Pi-hole" },
    @{ Key = "shutdown"; Label = "Shutdown" }
)

function Get-ServerTools($server) {
    if ($null -eq $server.Tools) {
        $all = @()
        foreach ($tool in $Global:ToolCatalog) { $all += $tool.Key }
        return $all
    }
    return @($server.Tools)
}

function Test-ServerTool($server, $key) {
    return ((Get-ServerTools $server) -contains $key)
}

function Get-ServerToolList($server) {
    $list = @()
    foreach ($tool in $Global:ToolCatalog) {
        if (Test-ServerTool $server $tool.Key) { $list += $tool }
    }
    return $list
}

function Get-ServerActions($server) {
    $labels = @()
    foreach ($tool in (Get-ServerToolList $server)) { $labels += $tool.Label }
    $labels += "Back"
    return $labels
}

function Set-ServerTool($server, $key, $on) {
    $keys = @(Get-ServerTools $server)
    if ($on) {
        if ($keys -notcontains $key) { $keys += $key }
    } else {
        $keys = @($keys | Where-Object { $_ -ne $key })
    }
    # rebuild in catalog order so the config file stays readable
    $ordered = @()
    foreach ($tool in $Global:ToolCatalog) {
        if ($keys -contains $tool.Key) { $ordered += $tool.Key }
    }
    $server.Tools = $ordered
    Export-HlConfig
}

function Write-ToolsPanel($server, $sel, $t) {
    for ($i = 0; $i -lt $Global:ToolCatalog.Count; $i++) {
        $tool = $Global:ToolCatalog[$i]
        if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
        if (Test-ServerTool $server $tool.Key) {
            $box = "[█] "
            $boxColor = $t.Success
        } else {
            $box = "[ ] "
            $boxColor = $t.Shadow
        }
        $segs = @(
            (Seg $marker $t.Accent),
            (Seg $box $boxColor),
            (Seg (Fit $tool.Label 22) $t.Text),
            (Seg $tool.Key $t.Shadow)
        )
        Write-Row $segs $t -Selected:($i -eq $sel)
    }
}

$Global:ServerTabs = @("ACTIONS","INFO","TOOLS","THEMES")

function Show-ServerScreen($server) {
    $tab = 0
    $actionSel = 0
    $toolSel   = 0

    while ($true) {
        $t = Get-Theme
        # rebuilt each frame - toggling a tool changes this list immediately
        $actions = Get-ServerActions $server
        if ($actionSel -ge $actions.Count) { $actionSel = $actions.Count - 1 }
        if ($actionSel -lt 0) { $actionSel = 0 }
        Set-ThemeConsole
        Write-Host ""
        Show-Title $t

        Write-PanelTop $t
        Write-TabRow $Global:ServerTabs $tab $t
        Write-PanelMid $t

        if ($tab -eq 0) {
            for ($i = 0; $i -lt $actions.Count; $i++) {
                if ($i -eq $actionSel) { $marker = "██ " } else { $marker = "   " }
                $segs = @(
                    (Seg $marker $t.Accent),
                    (Seg ("[{0}] {1}" -f ($i + 1), $actions[$i]) $t.Text)
                )
                Write-Row $segs $t -Selected:($i -eq $actionSel)
            }
        } elseif ($tab -eq 1) {
            Write-TextRow ("   ▓ Name   : " + $server.Name) $t $t.Text
            Write-TextRow ("   ▓ IP     : " + $server.IP)   $t $t.Text
            Write-TextRow ("   ▓ User   : " + $server.User) $t $t.Text
            Write-Row @(
                (Seg "   ▓ Status : " $t.Text),
                (Get-StatusSegment $server.IP $t)
            ) $t
        } elseif ($tab -eq 2) {
            Write-ToolsPanel $server $toolSel $t
        } else {
            Write-ThemePanel $t
        }

        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        if ($tab -eq 2) {
            Write-TextRow " ▓ [Up/Dn] Move    [Enter/Space] Toggle    [Tab] Switch tab" $t $t.Text
        } else {
            Write-TextRow " ▓ [Up/Dn] Move    [Tab] Switch tab    [Enter] Run" $t $t.Text
        }
        Write-TextRow " ▓ [R] Refresh     [PgUp/PgDn] Font     [B] Back" $t $t.Text
        Write-PanelBottom $t

        $key = Read-NavKey

        if ($key -eq "Q") { Export-HlConfig; [Console]::CursorVisible = $true; Clear-Host; exit }
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "R") { Reset-StatusCache; continue }
        if ($key -eq "PageUp"   -or $key -eq "]") { Set-FontSize ($Global:FontSize + 2); continue }
        if ($key -eq "PageDown" -or $key -eq "[") { Set-FontSize ($Global:FontSize - 2); continue }
        if ($key -eq "T") {
            $Global:ThemeIndex = ($Global:ThemeIndex + 1) % $Global:ThemeNames.Count
            Export-HlConfig
            continue
        }
        if ($key -eq "Tab" -or $key -eq "Right") { $tab = ($tab + 1) % $Global:ServerTabs.Count; continue }
        if ($key -eq "Left") { if ($tab -gt 0) { $tab-- } else { $tab = $Global:ServerTabs.Count - 1 }; continue }

        if ($tab -eq 2) {
            if ($key -eq "Up")   { if ($toolSel -gt 0) { $toolSel-- } }
            if ($key -eq "Down") { if ($toolSel -lt $Global:ToolCatalog.Count - 1) { $toolSel++ } }
            if ($key -eq "Enter" -or $key -eq " ") {
                $tool = $Global:ToolCatalog[$toolSel]
                Set-ServerTool $server $tool.Key (-not (Test-ServerTool $server $tool.Key))
            }
            continue
        }

        if ($tab -eq 3) {
            [void](Invoke-ThemeKey $key)
            if ($key -eq "Enter") { $tab = 0 }
            continue
        }

        if ($tab -eq 0) {
            if ($key -eq "Up")   { if ($actionSel -gt 0) { $actionSel-- } }
            if ($key -eq "Down") { if ($actionSel -lt $actions.Count - 1) { $actionSel++ } }
            if ($key -eq "Enter") {
                $tools  = Get-ServerToolList $server
                $target = $server.User + "@" + $server.IP
                # anything past the last tool is the trailing "Back" row
                if ($actionSel -ge $tools.Count) { return }
                # switch on the stable Key, never on the display label - a
                # label-matched dispatch breaks silently when you rename one
                switch ($tools[$actionSel].Key) {
                "ssh" {
                    Enter-AppConsole
                    ssh -t $target
                    Exit-AppConsole
                }
                "btop" {
                    Enter-AppConsole
                    ssh -t $target $Global:Cmd.Btop
                    Exit-AppConsole
                }
                "deploy" {
                    [Console]::CursorVisible = $true
                    Invoke-DeployMenu $server $t
                }
                "pihole" {
                    Show-PiholeMenu $server $t
                }
                "shutdown" {
                    [Console]::CursorVisible = $true
                    Set-ThemeConsole
                    Write-Host ""
                    Write-Host ("  ░▒▓ Shut down " + $server.Name + "? (y/n)") -ForegroundColor $t.Danger -NoNewline
                    Write-Host " > " -ForegroundColor $t.Accent -NoNewline
                    $confirm = Read-Host
                    if ($confirm -eq "y") {
                        ssh $target $Global:Cmd.Shutdown
                        Write-Host ""
                        Write-Host "  █ Shutdown sent." -ForegroundColor $t.Success
                        Reset-StatusCache
                    }
                    Pause-Screen $t
                }
                }
                [Console]::CursorVisible = $false
            }
        }
    }
}

# ---------------- Pi-hole ----------------
# Reads through the Pi-hole CLI's own API client inside the container
# (`pihole api`), so there is no app password to store or rotate anywhere.
$Global:PiholePortCache = @{}

# Both overridable per server in the config; these are the stock Pi-hole values.
function Get-PiholeContainer($server) {
    if ($server.PiholeContainer) { return [string]$server.PiholeContainer }
    return $Global:Cmd.Pihole
}

# Asks docker which host port maps to the container's port 80, so nobody has
# to hardcode 8080 (or 80, or whatever they picked) to match one setup.
function Get-PiholePort($server) {
    if ($server.PiholePort) { return [int]$server.PiholePort }
    if ($Global:PiholePortCache.ContainsKey($server.IP)) {
        return $Global:PiholePortCache[$server.IP]
    }
    $target = $server.User + "@" + $server.IP
    $cmd = "docker port " + (Get-PiholeContainer $server) + " 80/tcp 2>/dev/null | head -1"
    $raw = ssh -o BatchMode=yes -o ConnectTimeout=6 $target $cmd 2>$null
    $port = 80
    if ($raw) {
        $m = [regex]::Match(($raw -join ""), ':(\d+)\s*$')
        if ($m.Success) { $port = [int]$m.Groups[1].Value }
    }
    $Global:PiholePortCache[$server.IP] = $port
    return $port
}

function Get-PiholeUrl($server) {
    $port = Get-PiholePort $server
    if ($port -eq 80) { return "http://" + $server.IP + "/admin" }
    return "http://" + $server.IP + ":" + $port + "/admin"
}

# Both endpoints in one SSH call - the handshake costs about a second, so two
# separate calls double the wait for no reason.
function Get-PiholeSnapshot($target, $c) {
    $cmd = "docker exec " + $c + " pihole api stats/summary 2>/dev/null" +
           "; echo '<<SPLIT>>'; " +
           "docker exec " + $c + " pihole api dns/blocking 2>/dev/null"
    # -o options: fail fast instead of hanging the menu on a dead host, and
    # 2>$null keeps ssh's own errors from painting over the panel
    $raw = ssh -o BatchMode=yes -o ConnectTimeout=6 $target $cmd 2>$null
    if (-not $raw) { return $null }
    $parts = (($raw -join "`n") -split "<<SPLIT>>")
    $out = @{ Summary = $null; Blocking = $null }
    if ($parts.Count -ge 1) { try { $out.Summary  = $parts[0] | ConvertFrom-Json } catch { } }
    if ($parts.Count -ge 2) { try { $out.Blocking = $parts[1] | ConvertFrom-Json } catch { } }
    return $out
}

function Show-PiholeStatus($server, $t) {
    $target = $server.User + "@" + $server.IP

    Show-EntryHeader "PI-HOLE STATUS" $t
    Write-TextRow "   ░▒▓ Querying the container ..." $t $t.Warn
    Write-PanelBottom $t

    $snap = Get-PiholeSnapshot $target (Get-PiholeContainer $server)
    if ($null -eq $snap) {
        $sum = $null
        $blk = $null
    } else {
        $sum = $snap.Summary
        $blk = $snap.Blocking
    }

    Show-EntryHeader "PI-HOLE STATUS" $t
    if ($null -eq $sum) {
        Write-TextRow "   ░ No answer from the Pi-hole container." $t $t.Danger
        Write-TextRow ("   ░ Check: docker exec " + (Get-PiholeContainer $server) + " pihole status") $t $t.Shadow
        Write-PanelBottom $t
        Pause-Screen $t
        return
    }

    $q = $sum.queries
    $pct = [Math]::Round($q.percent_blocked, 1)

    if ($null -eq $blk) {
        $state = "unknown"
        $stateColor = $t.Shadow
    } elseif ($blk.blocking -eq "enabled") {
        $state = "enabled"
        $stateColor = $t.Success
    } else {
        $state = [string]$blk.blocking
        $stateColor = $t.Danger
    }

    Write-Row @( (Seg "   ▓ Blocking     : " $t.Text), (Seg ("█ " + $state) $stateColor) ) $t
    Write-TextRow ("   ▓ Queries      : " + ("{0:N0}" -f $q.total)) $t $t.Text
    Write-Row @(
        (Seg "   ▓ Blocked      : " $t.Text),
        (Seg ("{0:N0}" -f $q.blocked) $t.Danger),
        (Seg ("   " + $pct + "%") $t.Accent)
    ) $t
    Write-TextRow ("   ▓ Cached       : " + ("{0:N0}" -f $q.cached)) $t $t.Text
    Write-TextRow ("   ▓ Forwarded    : " + ("{0:N0}" -f $q.forwarded)) $t $t.Text
    Write-TextRow ("   ▓ Clients      : " + ("{0:N0}" -f $sum.clients.active) + " active") $t $t.Text
    Write-TextRow ("   ▓ Blocklist    : " + ("{0:N0}" -f $sum.gravity.domains_being_blocked) + " domains") $t $t.Text
    Write-TextRow ("   ▓ Web UI       : " + (Get-PiholeUrl $server)) $t $t.Shadow
    Write-PanelBottom $t
    Pause-Screen $t
}

function Show-PiholeMenu($server, $t) {
    $target  = $server.User + "@" + $server.IP
    $items   = @("Status", "Live dashboard", "Open web UI in browser", "Back")
    $sel     = 0

    while ($true) {
        $t = Get-Theme
        Show-EntryHeader "PI-HOLE" $t
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
            $segs = @(
                (Seg $marker $t.Accent),
                (Seg ("[{0}] {1}" -f ($i + 1), $items[$i]) $t.Text)
            )
            Write-Row $segs $t -Selected:($i -eq $sel)
        }
        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        Write-TextRow " ▓ [Up/Dn] Move    [Enter] Run    [B] Back" $t $t.Text
        Write-TextRow ("   " + (Get-PiholeUrl $server)) $t $t.Shadow
        Write-PanelBottom $t

        $key = Read-NavKey
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "Up")   { if ($sel -gt 0) { $sel-- } }
        if ($key -eq "Down") { if ($sel -lt $items.Count - 1) { $sel++ } }
        if ($key -eq "Enter") {
            $choice = $items[$sel]
            if ($choice -eq "Back") { return }
            if ($choice -eq "Status") {
                Show-PiholeStatus $server $t
            }
            if ($choice -eq "Live dashboard") {
                Enter-AppConsole
                ssh -t $target $Global:Cmd.PiholeTui
                Exit-AppConsole
            }
            if ($choice -eq "Open web UI in browser") {
                # this runs on the Windows box, not over SSH, so it really can
                # open a browser - the remote TUI only prints the URL
                Start-Process (Get-PiholeUrl $server)
            }
        }
    }
}

function Invoke-DeployMenu($server, $t) {
    $target = $server.User + "@" + $server.IP
    $sitesRaw = ssh $target ("ls " + $Global:Cmd.SitesDir)
    $sites = @($sitesRaw -split "`n" | Where-Object { $_ -ne "" })

    if ($sites.Count -eq 0) {
        Write-Host ""
        Write-Host "  ░ No sites found." -ForegroundColor $t.Warn
        Pause-Screen $t
        return
    }

    $sel = 0
    while ($true) {
        $t = Get-Theme
        Set-ThemeConsole
        Write-Host ""
        Show-Title $t
        Write-PanelTop $t
        Write-TabRow @("SELECT SITE TO DEPLOY") 0 $t
        Write-PanelMid $t
        for ($i = 0; $i -lt $sites.Count; $i++) {
            if ($i -eq $sel) { $marker = "██ " } else { $marker = "   " }
            $segs = @(
                (Seg $marker $t.Accent),
                (Seg ("[{0}] {1}" -f ($i + 1), $sites[$i]) $t.Text)
            )
            Write-Row $segs $t -Selected:($i -eq $sel)
        }
        Write-PanelBottom $t
        Write-Host ""
        Write-PanelTop $t
        Write-TextRow " ▓ [Up/Dn] Move    [Enter] Deploy    [B] Back" $t $t.Text
        Write-PanelBottom $t

        $key = Read-NavKey
        if ($key -eq "B" -or $key -eq "Escape") { return }
        if ($key -eq "Up")   { if ($sel -gt 0) { $sel-- } }
        if ($key -eq "Down") { if ($sel -lt $sites.Count - 1) { $sel++ } }
        if ($key -eq "Enter") {
            $site = $sites[$sel]
            Write-Host ""
            Write-Host ("  ▓ Deploying " + $site + " ...") -ForegroundColor $t.Success
            $remoteCmd = $Global:Cmd.Deploy -f ($Global:Cmd.SitesDir + "/" + $site)
            ssh $target $remoteCmd
            Pause-Screen $t
            return
        }
    }
}

# ================= MAIN LOOP =================

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Import-HlConfig
Initialize-Font

[Console]::CursorVisible = $false
$mainSel   = 0
$mainTab   = 0
$actionCol = 0     # 0 = [ + ], 1 = [ - ] on the action row

while ($true) {
    $count = @($Global:Servers).Count
    if ($mainSel -gt $count) { $mainSel = $count }
    if ($mainSel -lt 0) { $mainSel = 0 }
    $onActionRow = ($mainSel -eq $count)

    Show-MainMenu $mainSel $mainTab $actionCol
    $key = Read-NavKey

    if ($key -eq "Q" -or $key -eq "Escape") { Export-HlConfig; [Console]::CursorVisible = $true; Clear-Host; break }
    if ($key -eq "R") { Reset-StatusCache; continue }
    if ($key -eq "PageUp"   -or $key -eq "]") { Set-FontSize ($Global:FontSize + 2); continue }
    if ($key -eq "PageDown" -or $key -eq "[") { Set-FontSize ($Global:FontSize - 2); continue }
    if ($key -eq "T") {
        $Global:ThemeIndex = ($Global:ThemeIndex + 1) % $Global:ThemeNames.Count
        Export-HlConfig
        continue
    }
    if ($key -eq "Tab") { $mainTab = ($mainTab + 1) % $Global:MainTabs.Count; continue }

    if ($mainTab -eq 1) {
        if ($key -eq "Left" -or $key -eq "Right") { $mainTab = 0; continue }
        [void](Invoke-ThemeKey $key)
        if ($key -eq "Enter") { $mainTab = 0 }
        continue
    }

    # --- SERVERS tab ---
    if ($key -eq "+" -or $key -eq "=") { Show-AddServerScreen (Get-Theme); continue }
    if ($key -eq "E") { Show-EditServerScreen (Get-Theme); continue }
    if ($key -eq "-" -or $key -eq "_" -or $key -eq "Delete") { Show-DeleteServerScreen (Get-Theme); continue }

    if ($key -eq "Left" -or $key -eq "Right") {
        # on the action row the arrows walk the buttons; elsewhere they change tab
        if ($onActionRow) {
            if ($key -eq "Left") {
                if ($actionCol -gt 0) { $actionCol-- }
            } else {
                if ($actionCol -lt $Global:RowActions.Count - 1) { $actionCol++ }
            }
        } else {
            $mainTab = ($mainTab + 1) % $Global:MainTabs.Count
        }
        continue
    }

    if ($key -eq "Up")   { if ($mainSel -gt 0) { $mainSel-- } }
    if ($key -eq "Down") { if ($mainSel -lt $count) { $mainSel++ } }
    if ($key -eq "Enter") {
        [Console]::CursorVisible = $false
        if ($onActionRow) {
            switch ($actionCol) {
                0 { Show-AddServerScreen    (Get-Theme) }
                1 { Show-EditServerScreen   (Get-Theme) }
                2 { Show-DeleteServerScreen (Get-Theme) }
            }
        } else {
            Show-ServerScreen $Global:Servers[$mainSel]
        }
    }
}
