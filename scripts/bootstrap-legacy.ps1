param(
    [int]$LabCount=0,
    [string]$BackupBaseUri,
    [string]$StorageAccountName,
    [string]$ManagedInstanceServer,    
    [string]$SysAdminUsername,
    [string]$SysAdminPassword
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring SQL Firewall..."
& .\Set-FW-ForAllInstances.ps1

Write-Host "Restoring Team Databases..."

& .\Restore-TeamDatabases.ps1 -LabCount $LabCount -BackupBaseUri $BackupBaseUri -sqlusername $SysAdminUsername -sqlpassword $SysAdminPassword

& .\Configure-legacySQL.ps1 -sqlusername $SysAdminUsername -sqlpassword $SysAdminPassword

& .\Install-AzureCLI.ps1

& .\Restore-TeamDatabasesMI.ps1 -BackupBaseUri $BackupBaseUri -sqlusername $SysAdminUsername -sqlpassword $SysAdminPassword -StorageAccountName $StorageAccountName -ManagedInstanceServer $ManagedInstanceServer

& .\Configure-SQLMI.ps1 -ManagedInstanceServer $ManagedInstanceServer -sqlusername $SysAdminUsername -sqlpassword $SysAdminPassword

Write-Host "Bootstrap completed."