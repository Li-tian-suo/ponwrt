# Wait for a COM port to appear, up to N seconds. Exit 0 when found.
param(
    [string]$Port = 'COM4',
    [int]$TimeoutSec = 180
)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames()
    if ($ports -contains $Port) {
        Write-Output "FOUND $Port (ports: $($ports -join ','))"
        exit 0
    }
    Start-Sleep -Seconds 3
}
Write-Output "TIMEOUT waiting for $Port (ports: $(([System.IO.Ports.SerialPort]::GetPortNames()) -join ','))"
exit 1
