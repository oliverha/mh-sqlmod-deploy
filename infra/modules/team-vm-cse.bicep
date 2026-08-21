param location string
param reproBaseURL string
param managedInstanceServer string
param storageAccountName string
param vmName string

//var ConfigureTeamVMCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "bootstrap-teamvm.ps1" -SamplesBaseUri "${reproBaseURL}/TSQL_Scripts" -WallpaperUri "${reproBaseURL}/assets/BaseWallpaper.jpg" -TeamNumber ##teamNumber##'
var ConfigureTeamVMCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "bootstrap-teamvm.ps1" -SamplesBaseUri "${reproBaseURL}/TSQL_Scripts" -LabsBaseUri "${reproBaseURL}/LABS" -ManagedInstanceServer "${managedInstanceServer}" -StorageAccountName "${storageAccountName}"'
resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: vmName
}

resource installTeamTools 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: virtualMachine
  name: 'install-team-tools'
  location: location

  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true

    settings: {
      fileUris: [
        '${reproBaseURL}/scripts/install-team-tools.ps1'
        '${reproBaseURL}/scripts/Download-Samples.ps1'
        '${reproBaseURL}/scripts/bootstrap-teamvm.ps1'
        '${reproBaseURL}/scripts/Configure-Teams-Shortcuts.ps1'
        '${reproBaseURL}/scripts/Download-Labs.ps1'
        //'${reproBaseURL}/scripts/Configure-TeamWallpaper.ps1'
      ]
    }

    protectedSettings: {
      //commandToExecute: replace(ConfigureTeamVMCommand, '##teamNumber##', string(index + 1))
      commandToExecute: ConfigureTeamVMCommand
    }
  }
}
