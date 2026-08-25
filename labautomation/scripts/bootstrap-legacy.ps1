param(
    [int]$LabCount=0,
    [string]$BackupBaseUri,
    [string]$StorageAccountName,
    [string]$ManagedInstanceServer,    
    [string]$AdminUsername,
    [string]$AdminPassword,
    [string]$SqlMiAdminUsername,
    [string]$SqlMiAdminPassword
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Team Databases..."

& .\Restore-TeamDatabases.ps1 -LabCount $LabCount -BackupBaseUri $BackupBaseUri -sqlusername $AdminUsername -sqlpassword $AdminPassword

& .\Configure-legacySQL.ps1 -sqlusername $AdminUsername -sqlpassword $AdminPassword

& .\Install-AzureCLI.ps1

& .\Restore-TeamDatabasesMI.ps1 -BackupBaseUri $BackupBaseUri -sqlusername $SqlMiAdminUsername -sqlpassword $SqlMiAdminPassword -StorageAccountName $StorageAccountName -ManagedInstanceServer $ManagedInstanceServer

& .\Configure-SQLMI.ps1 -ManagedInstanceServer $ManagedInstanceServer -sqlusername $SqlMiAdminUsername -sqlpassword $SqlMiAdminPassword

Write-Host "Bootstrap completed."