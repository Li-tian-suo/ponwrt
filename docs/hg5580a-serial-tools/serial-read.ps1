# Read from a serial port and print what arrives, for N seconds.
# Usage: serial-read.ps1 -Port COM4 -Seconds 15
param(
    [string]$Port = 'COM4',
    [int]$Seconds = 15,
    [int]$Baud = 115200
)
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 500
$sp.NewLine = "`r`n"
try {
    $sp.Open()
    Write-Output "--- opened $Port @ $Baud ---"
    $deadline = (Get-Date).AddSeconds($Seconds)
    $buf = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $deadline) {
        try {
            $ch = $sp.ReadExisting()
            if ($ch.Length -gt 0) { [void]$buf.Append($ch) }
        } catch { }
        Start-Sleep -Milliseconds 80
    }
    Write-Output $buf.ToString()
    Write-Output ""
    Write-Output "--- captured $($buf.Length) chars ---"
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
