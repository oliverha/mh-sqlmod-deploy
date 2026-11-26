param(
    [string]$BackupUri,
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$sqlMiAdminUsername,
    [string]$sqlMiAdminPassword
)

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\bootstrap-newsql.log'
Start-Transcript -Path $logPath -Append

$stepTimings = [System.Collections.Generic.List[object]]::new()
$bootstrapStart = Get-Date

function Format-Duration([timespan]$Duration) {
    '{0}:{1:00}:{2:00}' -f [int][math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
}

# Runs one step and records how long it took
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)

    Write-Host "$Name..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
    }
    finally {
        $stopwatch.Stop()
        $stepTimings.Add([pscustomobject]@{ Step = $Name; Duration = $stopwatch.Elapsed })
        Write-Host ("[Timing] {0} took {1}" -f $Name, (Format-Duration $stopwatch.Elapsed))
    }
}

function Write-Timings {
    $lines = @('Step timings (h:mm:ss):')
    $lines += @($stepTimings | ForEach-Object { '  {0}  {1}' -f (Format-Duration $_.Duration), $_.Step })
    $lines += '  {0}  Total' -f (Format-Duration ((Get-Date) - $bootstrapStart))
    $lines | ForEach-Object { Write-Host "[Timing] $_" }
    $lines | Out-File -FilePath 'C:\Windows\Temp\bootstrap-newsql-timings.txt' -Encoding utf8 -Force
}

try {
    Invoke-Step "Configure SQL Firewall" { & .\Set-FW-ForAllInstances.ps1 }

    Invoke-Step "Restore Sample Database" { & .\Restore-SampleDatabases.ps1 -BackupUri $BackupUri -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword }

    Write-Host "Bootstrap completed."
}
finally {
    Write-Timings
    Stop-Transcript
}