<#
.SYNOPSIS
    Resets the remembered monitor/display topology on a remote Windows device and
    restarts it so Windows relearns the monitor connections on next boot.

.DESCRIPTION
    After monitors have been physically re-cabled into the correct ports, Windows may
    still show them in the old positions because it caches the display topology under:

        HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration
        HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity

    This script connects to the target device over PowerShell Remoting (WinRM),
    deletes those cached keys, and restarts the machine. On the next boot Windows
    re-enumerates the displays from scratch and places them according to the new
    physical connections.

    Requirements:
      - WinRM / PowerShell Remoting must be enabled on the TARGET device
        (run "Enable-PSRemoting -Force" on the target, or push it via GPO).
      - The supplied credentials must have local administrator rights on the target.
      - If the target is not domain-joined / not on the same trusted network, you may
        need the target's IP listed in this machine's TrustedHosts. See -AddTrustedHost.

.PARAMETER IPAddress
    IP address (or hostname) of the target device.

.PARAMETER Credential
    A PSCredential for an account with local admin rights on the target.
    If omitted, you will be prompted.

.PARAMETER AddTrustedHost
    Adds the target IP to this machine's WinRM TrustedHosts list before connecting.
    Useful when connecting by IP to a non-domain machine. Requires admin on THIS machine.

.PARAMETER NoRestart
    Deletes the registry keys but does NOT restart the target. The change will not take
    effect until the device is rebooted.

.PARAMETER Force
    Skips the confirmation prompt before deleting keys and restarting.

.EXAMPLE
    .\Reset-RemoteMonitorConfig.ps1 -IPAddress 192.168.1.50

.EXAMPLE
    $cred = Get-Credential
    .\Reset-RemoteMonitorConfig.ps1 -IPAddress 192.168.1.50 -Credential $cred -AddTrustedHost -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$IPAddress,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [switch]$AddTrustedHost,

    [switch]$NoRestart,

    [switch]$Force
)

# ---------------------------------------------------------------------------
# Registry keys that cache the display topology.
# ---------------------------------------------------------------------------
$RegKeysToDelete = @(
    'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration',
    'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity'
)

# ---------------------------------------------------------------------------
# Prompt for credentials if none supplied.
# ---------------------------------------------------------------------------
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter local admin credentials for $IPAddress"
    if (-not $Credential) {
        Write-Error "No credentials supplied. Aborting."
        return
    }
}

# ---------------------------------------------------------------------------
# Optionally add the target to TrustedHosts (needed for IP-based, non-domain).
# ---------------------------------------------------------------------------
if ($AddTrustedHost) {
    try {
        $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        if ([string]::IsNullOrWhiteSpace($current)) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $IPAddress -Force
        }
        elseif ($current.Split(',').Trim() -notcontains $IPAddress) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$current,$IPAddress" -Force
        }
        Write-Host "Added $IPAddress to TrustedHosts." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Could not update TrustedHosts (are you running elevated?): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Test connectivity before doing anything.
# ---------------------------------------------------------------------------
Write-Host "Testing connectivity to $IPAddress ..." -ForegroundColor Cyan
if (-not (Test-Connection -ComputerName $IPAddress -Count 2 -Quiet)) {
    Write-Warning "Ping to $IPAddress failed. The host may block ICMP; will still attempt WinRM."
}

try {
    Test-WSMan -ComputerName $IPAddress -ErrorAction Stop | Out-Null
    Write-Host "WinRM is reachable on $IPAddress." -ForegroundColor Green
}
catch {
    Write-Error @"
Could not reach WinRM on $IPAddress.
Make sure PowerShell Remoting is enabled on the target:
    Enable-PSRemoting -Force
and that the target's firewall allows WinRM (TCP 5985/5986).
Underlying error: $($_.Exception.Message)
"@
    return
}

# ---------------------------------------------------------------------------
# Confirmation.
# ---------------------------------------------------------------------------
$action = if ($NoRestart) { "delete the monitor-config registry keys (no restart)" }
          else            { "delete the monitor-config registry keys AND RESTART the device" }

if (-not $Force) {
    $answer = Read-Host "About to $action on $IPAddress. Continue? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Cancelled by user." -ForegroundColor Yellow
        return
    }
}

# ---------------------------------------------------------------------------
# Establish a session, delete keys, optionally restart.
# ---------------------------------------------------------------------------
$session = $null
try {
    Write-Host "Connecting to $IPAddress ..." -ForegroundColor Cyan
    $session = New-PSSession -ComputerName $IPAddress -Credential $Credential -ErrorAction Stop

    $result = Invoke-Command -Session $session -ScriptBlock {
        param($keys)

        $report = [System.Collections.Generic.List[object]]::new()

        foreach ($key in $keys) {
            if (Test-Path -Path $key) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Key = $key; Status = 'Deleted' })
                }
                catch {
                    $report.Add([pscustomobject]@{ Key = $key; Status = "ERROR: $($_.Exception.Message)" })
                }
            }
            else {
                $report.Add([pscustomobject]@{ Key = $key; Status = 'Not present (skipped)' })
            }
        }

        return $report
    } -ArgumentList (, $RegKeysToDelete)

    Write-Host "`nRegistry key results on $IPAddress :" -ForegroundColor Cyan
    $result | ForEach-Object {
        $color = switch -Wildcard ($_.Status) {
            'Deleted'          { 'Green' }
            'Not present*'     { 'DarkGray' }
            'ERROR*'           { 'Red' }
            default            { 'White' }
        }
        Write-Host ("  [{0}] {1}" -f $_.Status, $_.Key) -ForegroundColor $color
    }

    $hadError = $result | Where-Object { $_.Status -like 'ERROR*' }
    if ($hadError) {
        Write-Warning "One or more keys could not be deleted. Restart will be skipped."
        return
    }

    # -----------------------------------------------------------------------
    # Restart.
    # -----------------------------------------------------------------------
    if ($NoRestart) {
        Write-Host "`nKeys removed. Restart skipped (-NoRestart). Reboot manually for the change to take effect." -ForegroundColor Yellow
    }
    else {
        Write-Host "`nRestarting $IPAddress ..." -ForegroundColor Cyan
        # Trigger the restart INSIDE the WinRM session so it runs locally on the target.
        # Do NOT use "Restart-Computer -ComputerName", because that goes over WMI/DCOM (RPC,
        # port 135 + dynamic ports) which is often blocked even when WinRM (5985) works —
        # that is the "RPC server is unavailable" error.
        try {
            Invoke-Command -Session $session -ScriptBlock {
                Restart-Computer -Force
            } -ErrorAction Stop
            Write-Host "Restart command sent over WinRM. The device will relearn its monitors on next boot." -ForegroundColor Green
        }
        catch {
            # Restarting drops the WinRM session, which can surface as a terminating error
            # even though the reboot was actually issued. Treat a broken session as success.
            if ($_.Exception.Message -match 'session|broken|connection|closed|not available') {
                Write-Host "Restart issued (WinRM session closed as the device began rebooting, which is expected)." -ForegroundColor Green
            }
            else {
                # Fallback: schedule an immediate reboot via shutdown.exe inside the session.
                Write-Warning "Restart-Computer reported: $($_.Exception.Message). Falling back to shutdown.exe ..."
                try {
                    Invoke-Command -Session $session -ScriptBlock {
                        & shutdown.exe /r /t 0 /f
                    } -ErrorAction Stop
                    Write-Host "Fallback restart command sent." -ForegroundColor Green
                }
                catch {
                    if ($_.Exception.Message -match 'session|broken|connection|closed|not available') {
                        Write-Host "Restart issued (session closed as the device began rebooting)." -ForegroundColor Green
                    }
                    else {
                        Write-Error "Could not restart the device: $($_.Exception.Message)"
                    }
                }
            }
        }
    }
}
catch {
    Write-Error "Operation failed: $($_.Exception.Message)"
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}