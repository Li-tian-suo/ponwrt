# Flash both B-slot partitions for HG5580A and verify every write.
#
# Writes only KernelB and RootfsB; the bootloader, factory, identity and
# bosacal partitions are never touched, and slot A stays intact so the vendor
# firmware remains recoverable with:
#     setenv bootcmd "ldkernel;bargsenv;bootm" ; saveenv
#     fhbootflag set 0 0 0 0 ; reset
#
# Images and their expected CRC32 (computed on the PC side):
#     barefitB.bin   5,926,912 B   0xec6fcf53    -> KernelB at 0x0
#     rootfsB.bin    7,090,176 B   0x46020fe0    -> RootfsB at 0x0
#
# mtd write needs FOUR arguments: <part> <addr> <offset> <size>.  With three,
# the size is parsed as the offset and the write fails at the partition end.
param(
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [string]$TftpDir = 'H:\Deepseek\hg5580a-port\backup\fw\built',
    [switch]$SkipKernel,
    [switch]$SkipRootfs
)
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'HHmmss'
$logPath = "H:\Deepseek\hg5580a-port\logs\flash-luci-$stamp.log"
$global:LOG = New-Object System.Text.StringBuilder

function Say($m) { Write-Output $m; [void]$global:LOG.AppendLine([string]$m) }

$KERNEL = @{ File = 'barefitB.bin'; Size = 0x5a7000; Crc = 0xec6fcf53; Part = 'KernelB' }
$ROOTFS = @{ File = 'rootfsB.bin';  Size = 0x6c3000; Crc = 0x46020fe0; Part = 'RootfsB' }

# sanity check the files before touching flash
foreach ($img in @($KERNEL, $ROOTFS)) {
    if ($SkipKernel -and $img.Part -eq 'KernelB') { continue }
    if ($SkipRootfs -and $img.Part -eq 'RootfsB') { continue }
    $p = Join-Path $TftpDir $img.File
    if (-not (Test-Path $p)) { Say "MISSING: $p"; exit 1 }
    $len = (Get-Item $p).Length
    Say ("image {0,-14} {1,10} B  expected {2,10} B  {3}" -f $img.File, $len, $img.Size,
         $(if ($len -eq $img.Size) { 'OK' } else { 'SIZE MISMATCH' }))
    if ($len -ne $img.Size) { exit 1 }
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.WriteTimeout = 3000
$sp.DtrEnable = $false
$sp.RtsEnable = $false

function Drain($ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c.Length) { [void]$sb.Append($c) } } catch { }
        Start-Sleep -Milliseconds 40
    }
    return $sb.ToString()
}

function WaitPrompt($timeoutMs) {
    $end = (Get-Date).AddMilliseconds($timeoutMs)
    $acc = ''
    while ((Get-Date) -lt $end) {
        $acc += Drain 250
        if ($acc.Length -gt 6000) { $acc = $acc.Substring($acc.Length - 6000) }
        if ($acc -match 'U-Boot>\s*$') { return $true }
    }
    return $false
}

function Cmd($text, $waitMs) {
    Say "`n>>> $text"
    $sp.Write($text + "`r")
    $out = Drain $waitMs
    Say $out.TrimEnd()
    return $out
}

try {
    $sp.Open()
    Start-Sleep -Milliseconds 400
    [void](Drain 800)

    Say "=== confirm U-Boot prompt ==="
    $sp.Write("`r")
    $probe = Drain 1500
    Say $probe.TrimEnd()
    if ($probe -notmatch 'U-Boot>') {
        Say "no U-Boot> after CR; sending another CR and waiting"
        $sp.Write("`r")
        if (-not (WaitPrompt 4000)) { Say "FAILED: not at a U-Boot prompt"; exit 1 }
    }

    # show current state so the log records what we started from
    [void](Cmd 'bootflag read' 1500)
    [void](Cmd 'printenv bootcmd' 1500)

    if (-not $SkipKernel) {
        Say "`n========== KernelB =========="
        [void](Cmd 'tftpboot 0x88000000 barefitB.bin' 1500)
        if (-not (WaitPrompt 40000)) { Say "FAILED: tftpboot did not return"; exit 1 }
        $c = Cmd ('crc32 0x88000000 0x{0:x}' -f $KERNEL.Size) 4000
        if ($c -notmatch ('{0:x8}' -f $KERNEL.Crc)) {
            Say ("FAILED: CRC mismatch; expected 0x{0:x8}" -f $KERNEL.Crc); exit 1
        }
        Say "CRC OK"
        [void](Cmd 'mtd erase KernelB' 20000)
        if (-not (WaitPrompt 25000)) { Say "FAILED: erase did not finish"; exit 1 }
        [void](Cmd ('mtd write KernelB 0x88000000 0x0 0x{0:x}' -f $KERNEL.Size) 30000)
        if (-not (WaitPrompt 35000)) { Say "FAILED: write did not finish"; exit 1 }
        [void](Cmd ('mtd read KernelB 0x90000000 0x0 0x{0:x}' -f $KERNEL.Size) 25000)
        if (-not (WaitPrompt 30000)) { Say "FAILED: readback did not finish"; exit 1 }
        $v = Cmd ('crc32 0x90000000 0x{0:x}' -f $KERNEL.Size) 4000
        if ($v -notmatch ('{0:x8}' -f $KERNEL.Crc)) {
            Say "FAILED: KernelB readback CRC mismatch"; exit 1
        }
        Say "KernelB verified"
    }

    if (-not $SkipRootfs) {
        Say "`n========== RootfsB =========="
        [void](Cmd 'tftpboot 0x88000000 rootfsB.bin' 1500)
        if (-not (WaitPrompt 60000)) { Say "FAILED: tftpboot did not return"; exit 1 }
        $c = Cmd ('crc32 0x88000000 0x{0:x}' -f $ROOTFS.Size) 5000
        if ($c -notmatch ('{0:x8}' -f $ROOTFS.Crc)) {
            Say ("FAILED: CRC mismatch; expected 0x{0:x8}" -f $ROOTFS.Crc); exit 1
        }
        Say "CRC OK"
        [void](Cmd 'mtd erase RootfsB' 50000)
        if (-not (WaitPrompt 60000)) { Say "FAILED: erase did not finish"; exit 1 }
        [void](Cmd ('mtd write RootfsB 0x88000000 0x0 0x{0:x}' -f $ROOTFS.Size) 50000)
        if (-not (WaitPrompt 60000)) { Say "FAILED: write did not finish"; exit 1 }
        [void](Cmd ('mtd read RootfsB 0x90000000 0x0 0x{0:x}' -f $ROOTFS.Size) 45000)
        if (-not (WaitPrompt 50000)) { Say "FAILED: readback did not finish"; exit 1 }
        $v = Cmd ('crc32 0x90000000 0x{0:x}' -f $ROOTFS.Size) 5000
        if ($v -notmatch ('{0:x8}' -f $ROOTFS.Crc)) {
            Say "FAILED: RootfsB readback CRC mismatch"; exit 1
        }
        Say "RootfsB verified"
    }

    Say "`n=== final state ==="
    [void](Cmd 'printenv bootcmd' 1500)
    [void](Cmd 'printenv bootargs' 1500)
    Say "`nDONE. Run 'reset' to boot."
} catch {
    Say "ERROR: $($_.Exception.Message)"
} finally {
    if ($sp) {
        try { if ($sp.IsOpen) { $sp.Close() } } catch { }
        try { $sp.Dispose() } catch { }
        Say "port released"
    }
    try { [System.IO.File]::WriteAllText($logPath, $global:LOG.ToString()) } catch { }
    Say "log: $logPath"
}
