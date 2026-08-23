param location string
param managedInstanceName string
param subnetId string
param administratorLogin string

@secure()
param administratorLoginPassword string

@allowed([
  4
  8
  16
  24
  32
  40
  64
  80
])
param vCores int = 8

@minValue(32)
@maxValue(16384)
param storageSizeInGB int = 256

param tags object

resource managedInstance 'Microsoft.Sql/managedInstances@2025-02-01-preview' = {
  name: managedInstanceName
  location: location
  tags: tags

  identity: {
    type: 'SystemAssigned'
  }

  sku: {
    name: 'GP_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: vCores
  }

  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword

    subnetId: subnetId
    licenseType: 'LicenseIncluded'

    vCores: vCores
    storageSizeInGB: storageSizeInGB

    isGeneralPurposeV2: true

    publicDataEndpointEnabled: false
    proxyOverride: 'Proxy'
    minimalTlsVersion: '1.2'
    requestedBackupStorageRedundancy: 'Local'
    timezoneId: 'UTC'
  }
}

output managedInstanceName string = managedInstance.name

output fullyQualifiedDomainName string = managedInstance.properties.fullyQualifiedDomainName

output sqlmiPrincipalId string = managedInstance.identity.principalId
