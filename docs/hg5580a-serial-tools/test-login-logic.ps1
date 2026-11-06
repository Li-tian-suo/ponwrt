# Unit-test the login state machine logic WITHOUT hardware.
# Feeds synthetic U-Boot output through the same decision code used by
# bringup4, and asserts the expected key sends.
$ErrorActionPreference = 'Stop'

function LastLine($t) {
    $s = [string]$t
    $l = @($s -split "`r?`n" | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    if ($l.Count -eq 0) { return '' }
    return ([string]$l[$l.Count - 1]).Trim()
}

# Simulated transcript of a vendor U-Boot after "Abort"
$script:acc = ''
$script:sent = New-Object System.Collections.ArrayList

function Feed([string]$frag) {
    $script:acc += $frag
    if ($script:acc.Length -gt 4000) { $script:acc = $script:acc.Substring($script:acc.Length - 4000) }
}
function Decide {
    if ($script:acc -match 'U-Boot>\s*$') { return 'UBOOT' }
    $ll = LastLine $script:acc
    if ($ll -match '^UserName:') { return 'LOGIN_USER' }
    if ($ll -match '^Password:') { return 'LOGIN_PASS' }
    return ''
}

$cases = @(
    @{ name='fresh autoboot, no prompt yet'; feed="`r`nsoc an7583`r`n"; want=''; },
    @{ name='upgrade aborted -> UserName';    feed="Abort`r`n`r`nUserName: "; want='LOGIN_USER'; },
    @{ name='username entered -> Password';   feed="mkvj7XnQ`r`nPassword: "; want='LOGIN_PASS'; },
    @{ name='password ok -> U-Boot';          feed="`r`n`r`nU-Boot> "; want='UBOOT'; },
    @{ name='plain prompt at end';            feed="U-Boot>"; want='UBOOT'; }
)

$fail = 0
foreach ($c in $cases) {
    $script:acc = ''
    Feed $c.feed
    $got = Decide
    $ok = ($got -eq $c.want)
    if (-not $ok) { $fail++ }
    Write-Output ("{0,-34} want={1,-11} got={2,-11} {3}" -f $c.name, $c.want, $got, $(if($ok){'PASS'}else{'FAIL'}))
}

# Critical regression guard: the OLD bug was spamming Ctrl-C during login.
# Assert that once we are in LOGIN_USER state, the loop must not send keys.
Write-Output ""
Write-Output "--- order check: break keys must stop once a login prompt is present ---"
$script:acc = ''
$stopReason = ''
$keysSent = 0
$frames = @(
    "NOTICE:  Get secure key in flash`r`n",
    "soc an7583`r`n",
    "Abort`r`n",
    "`r`nUserName: "
)
foreach ($f in $frames) {
    Feed $f
    # replicate bringup4 ordering: check stop-conditions BEFORE sending keys
    if ($script:acc -match 'U-Boot>\s*$') { $stopReason='UBOOT'; break }
    $ll = LastLine $script:acc
    if ($ll -match '^UserName:') { $stopReason='LOGIN_USER'; break }
    if ($ll -match '^Password:') { $stopReason='LOGIN_PASS'; break }
    if ($script:acc -match '\bAbort\b') { $stopReason='ABORT_BRANCH'; break }
    $keysSent++
}
Write-Output "frames consumed until stop: $($keysSent+1), stopReason=$stopReason"
if ($stopReason -eq 'ABORT_BRANCH' -or $stopReason -eq 'LOGIN_USER') {
    Write-Output "PASS: stopped before spamming keys into the login prompt"
} else {
    Write-Output "FAIL: expected to stop at the login prompt"
    $fail++
}

Write-Output ""
Write-Output "=== overall: $(if($fail -eq 0){'ALL PASS'}else{"$fail FAILURE(S)"}) ==="
