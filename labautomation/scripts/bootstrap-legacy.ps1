param(
    [int]$LabCount=0,
    [string]$BackupBaseUri,
    [string]$StorageAccountName,
    [string]$ManagedInstanceServer,    
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$sqlMiAdminUsername,
    [string]$sqlMiAdminPassword
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Team Databases..."

& .\Restore-TeamDatabases.ps1 -LabCount $LabCount -BackupBaseUri $BackupBaseUri -sqlusername $adminUsername -sqlpassword $adminPassword

& .\Configure-legacySQL.ps1 -sqlusername $adminUsername -sqlpassword $adminPassword

& .\Install-AzureCLI.ps1

& .\Restore-TeamDatabasesMI.ps1 -BackupBaseUri $BackupBaseUri -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword -StorageAccountName $StorageAccountName -ManagedInstanceServer $ManagedInstanceServer

& .\Configure-SQLMI.ps1 -ManagedInstanceServer $ManagedInstanceServer -sqlusername $sqlMiAdminUsername -sqlpassword $sqlMiAdminPassword

Write-Host "Bootstrap completed."