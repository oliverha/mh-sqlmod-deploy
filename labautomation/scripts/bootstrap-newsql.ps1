param(
    [string]$BackupUri,
    [string]$adminUsername,
    [string]$adminPassword    
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Sample Database..."

& .\Restore-SampleDatabases.ps1 -BackupUri $BackupUri -sqlusername $adminUsername -sqlpassword $adminPassword

Write-Host "Bootstrap completed."