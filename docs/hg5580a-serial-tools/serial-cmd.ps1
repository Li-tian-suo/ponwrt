# Send a command to the serial port and capture the response.
param(
    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [string]$Command = '',
    [int]$ReadMs = 3000,
    [switch]$NoNewline
)
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 300
$sp.WriteTimeout = 3000
$sp.DtrEnable = $false
$sp.RtsEnable = $false
try {
    $sp.Open()
    Start-Sleep -Milliseconds 150
    $sp.DiscardInBuffer()
    if ($Command -ne '' -or -not $NoNewline) {
        if ($NoNewline) { $sp.Write($Command) } else { $sp.Write($Command + "`r") }
    }
    $deadline = (Get-Date).AddMilliseconds($ReadMs)
    $sb = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $deadline) {
        try {
            $ch = $sp.ReadExisting()
            if ($ch.Length -gt 0) { [void]$sb.Append($ch) }
        } catch { }
        Start-Sleep -Milliseconds 60
    }
    Write-Output "--- sent: [$Command] ---"
    Write-Output $sb.ToString()
    Write-Output "--- $($sb.Length) chars ---"
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
