# HG5580A bring-up v4.
#
# ROOT CAUSE of every failed login so far:
#   the autoboot-break loop wrote Ctrl-C (0x03) / CR at the top of EVERY
#   iteration, including while typing the login.  Ctrl-C clears the current
#   input line in this vendor U-Boot, so:
#       "UserName: " + 8 chars -> only 1 '*' echoed, prompt redrawn
#   and the password ended up typed into the UserName field:
#       "UserName: s!3aGx$9"
#
# v4 therefore sends break keys ONLY until a prompt marker appears
# ('UserName:', 'Password:', 'Abort', 'U-Boot>'), then goes completely silent
# for the whole login.
#
# Memory: FIT must be loaded at 0x88000000, NOT 0x82000000.
#   decompressed Image = 35,586,056 B (33.94 MiB) from base 0x80200000
#   -> ends at 0x823f0008, already past 0x82000000
#   -> otherwise "ERROR: new format image overwritten - must RESET the board"
param(
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$Pass,
    [string]$Kernel = 'initramfs.itb',
    [string]$LoadAddr = '0x88000000',
    [int]$BreakSeconds = 300,
    [int]$BootCaptureMs = 180000,
    [string]$LogDir = 'H:\Deepseek\hg5580a-port\logs'
)
$stamp = Get-Date -Format 'HHmmss'
$logPath = Join-Path $LogDir "bringup4-$stamp.log"
$global:B4 = New-Object System.Collections.ArrayList

$sp = $null
function Open-Port {
    $s = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
    $s.ReadTimeout = 200
    $s.WriteTimeout = 3000
    $s.DtrEnable = $false
    $s.RtsEnable = $false
    $s.Open()
    return $s
}
function Drain($ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c.Length) { [void]$sb.Append($c) } } catch { }
        Start-Sleep -Milliseconds 30
    }
    return $sb.ToString()
}
function Rec($t) {
    if ($null -eq $t) { return '' }
    $s = [string]$t
    if ($s.Length -gt 0) { [void]$global:B4.Add($s) }
    return $s
}
function Flat($t) {
    $s = [string]$t
    return (($s -split "`r?`n" | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join ' | ')
}
function LastLine($t) {
    $s = [string]$t
    $l = @($s -split "`r?`n" | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    if ($l.Count -eq 0) { return '' }
    return ([string]$l[$l.Count - 1]).Trim()
}
function Say($m) { Write-Output $m }

# Safe write: a USB re-enumeration closes the port mid-flow (observed as
# "Write: 端口被关闭").  Reopen and retry instead of aborting the whole run.
function W($s) {
    for ($try = 1; $try -le 4; $try++) {
        try {
            if (-not $sp.IsOpen) {
                Say "  [port closed, reopening]"
                Start-Sleep -Milliseconds 800
                $script:sp = Open-Port
            }
            $sp.Write($s)
            return $true
        } catch {
            Say ("  [write failed: " + $_.Exception.Message + "]")
            try { if ($sp -and $sp.IsOpen) { $sp.Close() } } catch { }
            Start-Sleep -Milliseconds 1200
            try { $script:sp = Open-Port } catch { Start-Sleep -Milliseconds 1500 }
        }
    }
    Say "  [write permanently failed]"
    return $false
}

try {
    $sp = Open-Port
    Say "opened $Port @ $Baud"

    # ============ phase A: break autoboot, stop at the first prompt ============
    $deadline = (Get-Date).AddSeconds($BreakSeconds)
    $i = 0
    $seen = ''          # 'LOGIN_USER' | 'LOGIN_PASS' | 'UBOOT' | ''
    $acc = ''
    while ((Get-Date) -lt $deadline) {
        $acc += Rec (Drain 120)
        if ($acc.Length -gt 4000) { $acc = $acc.Substring($acc.Length - 4000) }

        # stop-condition checks FIRST, so we never key-spam a prompt
        if ($acc -match 'U-Boot>\s*$') { $seen = 'UBOOT'; break }
        $ll = LastLine $acc
        if ($ll -match '^UserName:') { $seen = 'LOGIN_USER'; break }
        if ($ll -match '^Password:') { $seen = 'LOGIN_PASS'; break }
        if ($acc -match '\bAbort\b') {
            # upgrade service aborted; the login prompt follows immediately
            $acc += Rec (Drain 1500)
            $ll = LastLine $acc
            if ($ll -match '^Password:') { $seen = 'LOGIN_PASS' }
            else { $seen = 'LOGIN_USER' }
            break
        }

        if ($i % 2 -eq 0) { W([string][char]3) } else { W([string][char]13) }
        $i++
    }

    Say "break phase: seen=$seen after $([int]((Get-Date) - $deadline.AddSeconds($BreakSeconds)).TotalSeconds)s"
    Say ("  tail: " + (Flat ($acc.Substring([Math]::Max(0,$acc.Length-300)))))

    # ============ phase B: log in WITHOUT any key spam ============
    $shell = $false
    if ($seen -eq 'UBOOT') { $shell = $true }
    if ($seen -eq 'LOGIN_USER' -or $seen -eq 'LOGIN_PASS') {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Say "login attempt $attempt"
            $ll = LastLine $acc
            if ($ll -notmatch '^Password:') {
                # need the username first
                W($User + "`r")
                Say "  sent username"
                $r = Rec (Drain 1200)
                Say ("  reply: " + (Flat $r))
                $acc += $r
            }
            W($Pass + "`r")
            Say "  sent password"
            $r2 = Rec (Drain 2000)
            Say ("  reply: " + (Flat $r2))
            $acc += $r2
            if ($acc -match 'U-Boot>') { $shell = $true; break }
            if ($acc -match 'denied|invalid|incorrect|Wrong|wrong|failed') {
                Say "  >>> device rejected the credentials <<<"
                break
            }
            $ll = LastLine $r2
            if ($ll -match '^UserName:') { continue }
        }
    }

    if (-not $shell) {
        Say "=== FAILED to reach U-Boot prompt ==="
        [System.IO.File]::WriteAllText($logPath, ($global:B4 -join ''))
        Say "log: $logPath"
        exit 1
    }
    Say "=== U-Boot prompt reached ==="

    # ============ phase C: ping + tftp + boot ============
    W("ping 192.168.1.126`r")
    Say ("ping: " + (Flat (Rec (Drain 9000))))

    Say "=== tftpboot $LoadAddr $Kernel ==="
    W("tftpboot $LoadAddr $Kernel`r")
    $t = Rec (Drain 90000)
    Say (Flat $t)

    W("setenv bootargs console=ttyS0,115200 earlycon swiotlb=noforce`r")
    [void](Rec (Drain 2500))

    Say "=== bootm $LoadAddr ==="
    W("bootm $LoadAddr`r")
    $b = Rec (Drain $BootCaptureMs)
    Say (Flat $b)

    [System.IO.File]::WriteAllText($logPath, ($global:B4 -join ''))
    Say "=== log: $logPath ($((Get-Item $logPath).Length) B) ==="
} catch {
    Say "ERROR: $($_.Exception.Message)"
    try { [System.IO.File]::WriteAllText($logPath, ($global:B4 -join '')) } catch { }
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sp) { $sp.Dispose() }
}
