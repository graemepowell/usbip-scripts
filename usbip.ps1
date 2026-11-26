<#
.SYNOPSIS
    Connects to or disconnects from a remote USB/IP server (e.g., Raspberry Pi).
.DESCRIPTION
    Reads connection settings from environment variables or a local .env file
    in the script directory:
      - USBIP_HOST    (required) Hostname or IP address of the USB/IP server
      - USBIP_USER    (required) SSH username on the USB/IP server
      - USBIP_SSH_KEY (required) Path to the SSH private key for passwordless auth
      - USBIP_EXE     (optional) Path to usbip.exe (default: C:\Program Files\USBip\usbip.exe)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('attach', 'detach')]
    [string]$Action
)

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        $sepIndex = $line.IndexOf('=')
        if ($sepIndex -lt 1) { continue }

        $name = $line.Substring(0, $sepIndex).Trim()
        $value = $line.Substring($sepIndex + 1).Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$Default = $null
    )
    $val = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($val)) {
        $val = $Default
    }
    if (-not [string]::IsNullOrWhiteSpace($val)) {
        $val = [Environment]::ExpandEnvironmentVariables($val.Trim())
    }
    return $val
}

function Wait-ExitPrompt {
    param([int]$Seconds = 5)
    Write-Host ''
    Write-Host ("Closing in {0} seconds (or press any key)..." -f $Seconds) -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
            break
        }
        Start-Sleep -Milliseconds 100
    }
}

function Get-AttachedPorts {
    param([string]$UsbipExe)
    $ports = @()
    (& $UsbipExe port 2>$null) | ForEach-Object {
        if ($_ -match '^Port\s+(\d+)') {
            $ports += [int]$Matches[1]
        }
    }
    return $ports
}

function Invoke-DetachAllPorts {
    param(
        [string]$UsbipExe,
        [switch]$VerboseOutput
    )
    $ports = @(Get-AttachedPorts -UsbipExe $UsbipExe)
    if ($ports.Count -eq 0) {
        if ($VerboseOutput) { Write-Host '  - No active ports attached.' }
        return $false
    }
    foreach ($p in $ports) {
        if ($VerboseOutput) { Write-Host ('  - Detaching port {0:D2}...' -f $p) }
        & $UsbipExe detach -p $p | Out-Null
    }
    return $true
}

Import-DotEnv -Path (Join-Path $PSScriptRoot '.env')

$piHost = Get-ConfigValue -Name 'USBIP_HOST'
$piUser = Get-ConfigValue -Name 'USBIP_USER'
$sshKey = Get-ConfigValue -Name 'USBIP_SSH_KEY'
$usbipExe = Get-ConfigValue -Name 'USBIP_EXE' -Default 'C:\Program Files\USBip\usbip.exe'

$missing = @()
if ([string]::IsNullOrWhiteSpace($piHost)) { $missing += 'USBIP_HOST' }
if ([string]::IsNullOrWhiteSpace($piUser)) { $missing += 'USBIP_USER' }
if ([string]::IsNullOrWhiteSpace($sshKey)) { $missing += 'USBIP_SSH_KEY' }

if ($missing.Count -gt 0) {
    Write-Host ('[ERROR] Missing required environment variable(s): {0}' -f ($missing -join ', ')) -ForegroundColor Red
    Write-Host 'Set them as Windows environment variables or copy .env.example to .env and fill them in.' -ForegroundColor Yellow
    Wait-ExitPrompt -Seconds 8
    exit 1
}

if (-not (Test-Path -LiteralPath $sshKey)) {
    Write-Host ('[ERROR] SSH private key not found: {0}' -f $sshKey) -ForegroundColor Red
    Wait-ExitPrompt -Seconds 8
    exit 1
}

if (-not (Test-Path -LiteralPath $usbipExe)) {
    Write-Host ('[ERROR] usbip.exe not found: {0}' -f $usbipExe) -ForegroundColor Red
    Wait-ExitPrompt -Seconds 8
    exit 1
}

$sshTarget = "$piUser@$piHost"
$sshArgs = @('-i', $sshKey, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=5', $sshTarget)

if ($Action -eq 'attach') {
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host '  USB/IP Enable Driver, Restart & Attach All' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor Cyan

    Write-Host '[1/4] Enabling USBip 3.X Emulated Host Controller (usbip2_ude)...'
    $vhci = Get-PnpDevice | Where-Object { $_.Service -eq 'usbip2_ude' }
    if ($vhci) {
        $vhci | Enable-PnpDevice -Confirm:$false -EA 0
        Start-Sleep -Seconds 1
        Write-Host '  - Emulated host controller enabled.' -ForegroundColor Green
    } else {
        Write-Host '  [WARN] usbip2_ude device not found in Device Manager.' -ForegroundColor Yellow
    }

    Write-Host '[2/4] Detaching any stale ports & restarting remote usbipd...'
    $null = Invoke-DetachAllPorts -UsbipExe $usbipExe
    & ssh @sshArgs 'sudo /bin/systemctl restart usbipd && sleep 1'
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [ERROR] SSH command failed.' -ForegroundColor Red
    } else {
        Write-Host '  - Remote usbipd restarted.' -ForegroundColor Green

        Write-Host ("[3/4] Discovering & attaching all devices on {0}..." -f $piHost)
        $list = & $usbipExe list -r $piHost 2>$null
        $devices = @($list | ForEach-Object {
            if ($_ -match '^\s*(\d+-[\d\.]+)\s*:\s*(.+)$') {
                [PSCustomObject]@{
                    BusId = $Matches[1]
                    Name  = $Matches[2].Trim()
                }
            }
        })

        if ($devices.Count -eq 0) {
            Write-Host '  [WARN] No exported USB devices found.' -ForegroundColor Yellow
        } else {
            foreach ($d in $devices) {
                Write-Host ('  -> Attaching [{0}] {1}...' -f $d.BusId, $d.Name)
                & $usbipExe attach -r $piHost -b $d.BusId | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ('     [OK] Attached {0}' -f $d.BusId) -ForegroundColor Green
                } else {
                    Write-Host ('     [FAIL] Could not attach {0}' -f $d.BusId) -ForegroundColor Red
                }
                Start-Sleep -Milliseconds 600
            }
        }

        Write-Host '[4/4] Active ports & Windows COM devices:'
        & $usbipExe port
        Get-PnpDevice -Class Ports -Status OK -EA 0 | ForEach-Object {
            Write-Host ('  - {0}' -f $_.FriendlyName) -ForegroundColor White
        }
    }
}
elseif ($Action -eq 'detach') {
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host '  USB/IP Clean Detach & Unload Driver' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor Cyan

    Write-Host '[1/3] Detaching all local USB/IP ports...'
    if (Invoke-DetachAllPorts -UsbipExe $usbipExe -VerboseOutput) {
        Start-Sleep -Milliseconds 500
    }

    Write-Host ("[2/3] Stopping remote usbipd daemon on {0}..." -f $piHost)
    & ssh @sshArgs 'sudo /bin/systemctl stop usbipd'
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  - Remote usbipd stopped (devices released back to Pi).' -ForegroundColor Green
    } else {
        Write-Host '  [WARN] Could not reach Pi to stop usbipd (continuing local cleanup).' -ForegroundColor Yellow
    }

    Write-Host '[3/3] Disabling USBip 3.X Emulated Host Controller (usbip2_ude)...'
    $vhci = Get-PnpDevice | Where-Object { $_.Service -eq 'usbip2_ude' }
    if ($vhci) {
        $vhci | Disable-PnpDevice -Confirm:$false -EA 0
        Start-Sleep -Milliseconds 500
        $state = ($vhci | Get-PnpDevice).Status
        Write-Host ('  - Emulated host controller disabled (Status: {0}).' -f ($state -join ', ')) -ForegroundColor Green
    } else {
        Write-Host '  [WARN] usbip2_ude device not found.' -ForegroundColor Yellow
    }
}

Wait-ExitPrompt -Seconds 5
