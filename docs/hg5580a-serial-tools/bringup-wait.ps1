# Wait until the CH340 serial adapter is present AND openable, then run the
# full bring-up.  Needed because power-cycling the router also drops the USB
# serial adapter momentarily, so the port disappears and reappears.
param(
    [string]$Port = 'COM4',
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$Pass,
    [string]$Kernel = 'initramfs.itb',
    [string]$LoadAddr = '0x88000000',
    [int]$WaitPortSec = 180,
    [int]$BreakSeconds = 420,
    [int]$BootCaptureMs = 180000
)
$ErrorActionPreference = 'Continue'

function Say($m) { Write-Output $m }

Say "waiting up to $WaitPortSec s for $Port to appear and open ..."
$deadline = (Get-Date).AddSeconds($WaitPortSec)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $names = [System.IO.Ports.SerialPort]::GetPortNames()
    if ($names -contains $Port) {
        try {
            $t = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
            $t.Open(); $t.Close(); $t.Dispose()
            Say "  $Port is present and openable  (ports: $($names -join ','))"
            $ready = $true
            break
        } catch {
            Say "  $Port present but busy: $($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 1500
}
if (-not $ready) {
    Say "TIMEOUT: $Port never became usable"
    exit 1
}

# hand over to the tested bring-up script
$bringup = Join-Path $PSScriptRoot 'bringup4.ps1'
if (-not (Test-Path $bringup)) { $bringup = 'H:\Deepseek\hg5580a-port\tools\bringup4.ps1' }
Say "running $bringup"
$sb = [scriptblock]::Create((Get-Content $bringup -Raw))
& $sb -Port $Port -User $User -Pass $Pass -Kernel $Kernel -LoadAddr $LoadAddr `
     -BreakSeconds $BreakSeconds -BootCaptureMs $BootCaptureMs
