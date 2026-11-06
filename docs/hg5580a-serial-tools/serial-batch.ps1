# Run a batch of shell commands over serial and return the combined output.
# Serial only echoes when it feels like it, so each command is followed by a
# unique sentinel echo so we can tell where output ends.
param(
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [string[]]$Commands = @(),
    [int]$SettleMs = 1200,
    [string]$OutFile = ''
)
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

$all = New-Object System.Text.StringBuilder
try {
    $sp.Open()
    [void]$sp.Drain
    [void](Drain 800)
    foreach ($cmd in $Commands) {
        [void]$all.AppendLine("`r`n===== CMD: $cmd =====")
        $sp.Write($cmd + "`r")
        $r = Drain $SettleMs
        [void]$all.Append($r)
        Write-Output "----- $cmd -----"
        Write-Output $r
    }
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $all.ToString())
    Write-Output "saved: $OutFile"
}
