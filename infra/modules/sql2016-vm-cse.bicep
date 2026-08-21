param location string
param vmName string
param labCount int
param storageAccountName string
param managedInstanceServer string
param adminUsername string
param reproBaseURL string

@secure()
param adminPassword string

var ConfigureSQLMachineCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "bootstrap-legacy.ps1" -LabCount ${labCount} -BackupBaseUri "${reproBaseURL}/Databases" -SysAdminUsername ${adminUsername} -SysAdminPassword ${adminPassword} -StorageAccountName ${storageAccountName} -ManagedInstanceServer ${managedInstanceServer}'

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: vmName
}

resource sqlVirtualMachine 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' existing = {
  name: vmName
}

resource ConfigureSQLMachine 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: virtualMachine
  name: 'ConfigureSQLMachine'
  location: location

  dependsOn: [
    sqlVirtualMachine
  ]  

  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true

    settings: {
      fileUris: [
        '${reproBaseURL}/scripts/Set-FW-ForAllInstances.ps1'
        '${reproBaseURL}/scripts/Restore-TeamDatabases.ps1'
        '${reproBaseURL}/scripts/bootstrap-legacy.ps1'
        '${reproBaseURL}/scripts/Restore-TeamDatabasesMI.ps1'
        '${reproBaseURL}/scripts/Install-AzureCLI.ps1'
        '${reproBaseURL}/scripts/Configure-SQLMI.ps1'
        '${reproBaseURL}/scripts/Configure-legacySQL.ps1'
      ]
    }

    protectedSettings: {
      commandToExecute: ConfigureSQLMachineCommand
    }
  }
}
