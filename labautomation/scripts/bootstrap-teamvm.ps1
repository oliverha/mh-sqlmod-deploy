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

Write-Host "Configuring TEAM VM..."

Write-Host "Configure Team VM (Privacy Experience / OOBE Privacy Consent Page) ..."
& .\Configure-TeamVM.ps1

##Not working with Bastion, so we will not set wallpaper for now.  If you want to set wallpaper, you can run the following command after you RDP into the VM.
Write-Host "Configure Team Wallpaper..."
& .\Configure-TeamWallpaper.ps1 -WallpaperUri $WallpaperUri -TeamName $TeamName

Write-Host "Installing SQL Server 2017 Developer Edition..."
& .\Install-SqlServer2017.ps1 -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Downloading Team Databases..."
& .\Download-TeamDatabases.ps1 -BackupBaseUri $BackupBaseUri

Write-Host "Configuring local SQL Server..."
& .\Configure-LocalSQL.ps1 -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword

Write-Host "Creating the 32-bit and 64-bit SQL alias legacySQL2017 -> localhost..."
& .\Set-SqlAlias.ps1

Write-Host "Restoring Team Databases..."
& .\Restore-TeamDatabases.ps1 -TeamName $TeamName -BackupBaseUri $BackupBaseUri -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword

Write-Host "Configuring Team Databases..."
& .\Configure-LocalSQL-DB.ps1 -TeamName $TeamName -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword

Write-Host "Configuring SQL MI Sysadmins..."
& .\Configure-SQLMI-Sysadmins.ps1 -ManagedInstanceServer $ManagedInstanceServer -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword -sqlMiSysadminUser $SqlMiSysadminUser

Write-Host "Starting the installation of the team tools (SSMS, Storage Explorer) in the background..."
& .\install-team-tools.ps1

Write-Host "Downloading Sample Files..."
& .\Download-Samples.ps1 -SamplesBaseUri $SamplesBaseUri -ForceDownload

Write-Host "Downloading LAB Files..."
& .\Download-Labs.ps1 -LabsBaseUri $LabsBaseUri -ForceDownload

Write-Host "Configuring Teams Shortcuts..."
& .\Configure-Teams-Shortcuts.ps1 -ManagedInstanceServer $ManagedInstanceServer -StorageAccountName $StorageAccountName

Write-Host "Bootstrap completed."

Stop-Transcript