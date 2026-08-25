param(
    [string]$BackupUri,
    [string]$AdminUsername,
    [string]$AdminPassword    
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Sample Database..."

& .\Restore-SampleDatabases.ps1 -BackupUri $BackupUri -sqlusername $AdminUsername -sqlpassword $AdminPassword

Write-Host "Bootstrap completed."