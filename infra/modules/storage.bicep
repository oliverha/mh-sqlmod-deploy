param location string
param storageAccountName string
param tags object
param privateEndpointName string
param subnetId string
param vnetId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags

  sku: {
    name: 'Standard_LRS'
  }

  kind: 'StorageV2'

  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  name: '${storageAccount.name}/default/backups'

  properties: {
    publicAccess: 'None'
  }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  name: '${storageAccount.name}/default/auditlogs'

  properties: {
    publicAccess: 'None'
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location

  properties: {
    subnet: {
      id: subnetId
    }

    privateLinkServiceConnections: [
      {
        name: 'blobConnection'

        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
}

resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: '${blobDnsZone.name}/vnet-link'
  location: 'global'

  properties: {
    registrationEnabled: false

    virtualNetwork: {
      id: vnetId
    }
  }
}

resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: '${storagePrivateEndpoint.name}/default'
 
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'

        properties: {
          privateDnsZoneId: blobDnsZone.id
        }
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
