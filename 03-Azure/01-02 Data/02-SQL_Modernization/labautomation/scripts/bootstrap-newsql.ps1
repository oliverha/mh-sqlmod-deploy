param(
    [string]$BackupUri,
    [string]$SysAdminUsername,
    [string]$SysAdminPassword    
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Sample Database..."

& .\Restore-SampleDatabases.ps1 -BackupUri $BackupUri -sqlusername $SysAdminUsername -sqlpassword $SysAdminPassword

Write-Host "Bootstrap completed."