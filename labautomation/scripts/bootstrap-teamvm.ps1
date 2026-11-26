param(
    [string]$SamplesBaseUri,
    [string]$LabsBaseUri,
    [string]$BackupBaseUri,
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$sqlMiAdminUsername,
    [string]$sqlMiAdminPassword,
    [string]$WallpaperUri,  
    [string]$TeamName,
    [string]$ManagedInstanceServer,
    [string]$StorageAccountName,
    [string]$SqlMiSysadminUser
)

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\bootstrap-teamvm.log'
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
    $lines | Out-File -FilePath 'C:\Windows\Temp\bootstrap-teamvm-timings.txt' -Encoding utf8 -Force
}

try {
    Write-Host "Configuring TEAM VM..."

    Invoke-Step "Configure Team VM (Privacy Experience / OOBE Privacy Consent Page)" { & .\Configure-TeamVM.ps1 }

    ##Not working with Bastion, so we will not set wallpaper for now.  If you want to set wallpaper, you can run the following command after you RDP into the VM.
    Invoke-Step "Configure Team Wallpaper" { & .\Configure-TeamWallpaper.ps1 -WallpaperUri $WallpaperUri -TeamName $TeamName }

    Invoke-Step "Install SQL Server 2017 Developer Edition" { & .\Install-SqlServer2017.ps1 -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword }

    Invoke-Step "Configure SQL Firewall" { & .\Set-FW-ForAllInstances.ps1 }

    Invoke-Step "Download Team Databases" { & .\Download-TeamDatabases.ps1 -BackupBaseUri $BackupBaseUri }

    Invoke-Step "Configure local SQL Server" { & .\Configure-LocalSQL.ps1 -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword }

    Invoke-Step "Create the 32-bit and 64-bit SQL alias legacySQL2017 -> localhost" { & .\Set-SqlAlias.ps1 }

    Invoke-Step "Restore Team Databases" { & .\Restore-TeamDatabases.ps1 -TeamName $TeamName -BackupBaseUri $BackupBaseUri -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword }

    Invoke-Step "Configure Team Databases" { & .\Configure-LocalSQL-DB.ps1 -TeamName $TeamName -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword }

    Invoke-Step "Configure SQL MI Sysadmins" { & .\Configure-SQLMI-Sysadmins.ps1 -ManagedInstanceServer $ManagedInstanceServer -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword -sqlMiSysadminUser $SqlMiSysadminUser }

    Invoke-Step "Start the installation of the team tools (SSMS, Storage Explorer) in the background" { & .\install-team-tools.ps1 }

    Invoke-Step "Download Sample Files" { & .\Download-Samples.ps1 -SamplesBaseUri $SamplesBaseUri -ForceDownload }

    Invoke-Step "Download LAB Files" { & .\Download-Labs.ps1 -LabsBaseUri $LabsBaseUri -ForceDownload }

    Invoke-Step "Configure Teams Shortcuts" { & .\Configure-Teams-Shortcuts.ps1 -ManagedInstanceServer $ManagedInstanceServer -StorageAccountName $StorageAccountName }

    Write-Host "Bootstrap completed."
}
finally {
    Write-Timings
    Stop-Transcript
}