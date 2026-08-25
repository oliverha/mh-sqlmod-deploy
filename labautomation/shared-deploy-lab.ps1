<#
.SYNOPSIS
Hook that runs once per subscription before any deploy-lab.ps1 run starts.
.DESCRIPTION
Hook that runs before the per-user deploy-lab.ps1 runs are started. It can be used to deploy shared resources on a subscription level
(e.g. a hub VNet) or to prepare the subscription once instead of once per lab (e.g. registering resource providers).
If it fails for any subscription, no deploy-lab.ps1 runs at all. Emitted HackboxCredential entries are stored for every lab in this subscription.
.PARAMETER SubscriptionId
Specifies the Azure subscription that contains the lab resources.
.PARAMETER PreferredLocation
Specifies the preferred Azure regions (ordered by preference) for resource deployment.
.PARAMETER AllowedEntraUserIds
Entra user object IDs of every participant holding a lab in this subscription.
#>
param(  
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$true)]
    [string[]]$PreferredLocation = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$AllowedEntraUserIds = @()
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "[$SubscriptionId] Running shared-deploy-lab.ps1 in $scriptPath"

# EXAMPLE: Register Resource Providers here if needed
$requiredProviders = @(
    "Microsoft.Compute",
    "Microsoft.Network",
    "Microsoft.Storage",
    "Microsoft.Sql",
    "Microsoft.SqlVirtualMachine",
    "Microsoft.DevTestLab"
)
foreach($provider in $requiredProviders) {
    $state = (Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
    if($state -ne "Registered") {
        Write-Host "[$SubscriptionId] Registering resource provider: $provider"
        Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
    }
    else {
        Write-Host "[$SubscriptionId] Resource provider $provider is already registered."
    }
}

try {
    $registrationState = Get-AzProviderFeature -ProviderNamespace Microsoft.Network -FeatureName AllowBringYourOwnPublicIpAddress
    If ($registrationState.RegistrationState -ne "Registered") {
        Register-AzProviderFeature -ProviderNamespace Microsoft.Network -FeatureName AllowBringYourOwnPublicIpAddress
    }
}
catch {
    Write-Host "Could not register AllowBringYourOwnPublicIpAddress." -ForegroundColor Red
}

# EXAMPLE: shared resources, e.g. hub networks, bastion host, etc. can be deployed here...
# no resource group is pre-created for this hook, so pick your own name and never use a participant's resource group
$environmentName = "sqlhack"  # template produces rg-sqlhack-shared
$sharedResourceGroup = "rg-${environmentName}-shared"
$AdminUsername = "DemoUser"
$AdminPassword = New-MhhStablePassword -Purpose 'vm-admin' -SubscriptionId $SubscriptionId -ResourceGroupName "Default"
$SqlMiAdminUsername = "DemoUser"
$SqlMiAdminPassword = New-MhhStablePassword -Purpose 'sqlmi-admin' -SubscriptionId $SubscriptionId -ResourceGroupName "Default"
$legacySQLName = "legacySQL2016"
$arcSQLName = "arcSQL2022"


# deploy shared resources in the shared resource group (do not forget to assign the correct rbac roles to the allowed Entra users)
# Invoke-MhhDeploymentWithRegionFallback creates/recreates the resource group, re-grants Owner and falls back to the next region

# $template = Join-Path $scriptPath "template-shared.bicep"
$templatePath = Join-Path $scriptPath "infra"
$template = Join-Path $templatePath "main-shared.bicep"
Write-Host "[$SubscriptionId] Deploying shared resources from template $template to resource group $sharedResourceGroup"

Write-Host $AllowedEntraUserIds

$LabUsers = @(Get-MhhLabUser -UserId @($AllowedEntraUserIds)) | Where-Object { $_.ShortName -like "labuser-*" }
$LabCount = $LabUsers.Count
if ($LabCount -eq 0) {
    $LabCount = 1
}

New-AzResourceGroup -Name $sharedResourceGroup -Location $PreferredLocation[0] -Force -ErrorAction Stop

$tags = @{
    SecurityControl = "Ignore"
}
#$result = Invoke-MhhDeploymentWithRegionFallback `
#    -PreferredLocations      $PreferredLocation `
#    -TemplateFile            $template #`
#    -TemplateParameterObject @{
#        userIds = $AllowedEntraUserIds
#    }

$result = Invoke-MhhDeploymentWithRegionFallback `
    -PreferredLocations      $PreferredLocation `
    -RgOwnerEntraObjectIds   @($AllowedEntraUserIds) `
    -ResourceGroupName       $sharedResourceGroup `
    -TemplateFile            $template `
    -Tag                     $tags `
    -TemplateParameterObject @{
        environmentName                     = $environmentName  # z.B. "sqlhack"
        location                            = $PreferredLocation[0]
        AdminUsername                       = $AdminUsername
        AdminPassword                       = $AdminPassword
        SqlMiAdminUsername                  = $SqlMiAdminUsername
        SqlMiAdminPassword                  = $SqlMiAdminPassword
        legacySQLName                       = $legacySQLName
        arcSQLName                          = $arcSQLName
        labCount                            = $LabCount
    }

Write-Host "[$SubscriptionId] Result: $($result)"

# You can send back information to the hackbox console (credentials) - Simply return a hashtable like this:
# Note: everything returned here is shown to EVERY participant in this subscription, so never emit per-participant secrets.
# @{"HackboxCredential" = @{ name = "AdminPassword" ; value = "TopSecret"; note = "Useful info here" }}

$managedInstance = Get-AzSqlInstance -ResourceGroupName $sharedResourceGroup -ErrorAction SilentlyContinue | Select-Object -First 1
$managedInstanceName = $managedInstance.ManagedInstanceName
$managedInstanceFQDN = $managedInstance.FullyQualifiedDomainName
[string]$managedInstanceResourceId = $managedInstance.Id
$managedInstancePrincipalId = $managedInstance.Identity.PrincipalId
$RoleDirReaders = Get-MgDirectoryRole | Where-Object {$_.DisplayName -eq "Directory Readers"}

try {
    Write-Host "Connecting to MGraph..."
    $token = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
    Connect-MgGraph -AccessToken $token -NoWelcome -Erroraction Stop
    Write-Host "Calling Set-MhhManagedIdentityRoleMember for $managedInstanceResourceId ..."
    $return = Set-MhhManagedIdentityRoleMember -ResourceId $managedInstanceResourceId
    Write-Host "Calling Set-MhhManagedIdentityRoleMember returned $return ..."
}
catch {
    Write-Host "Failed to grant 'Directory Readers' to Managed Identity of $managedInstanceFQDN." -ForegroundColor Red
    $ErrorString = $_ | format-list -force | Out-String
    Write-Host "ERR: $ErrorString" -ForegroundColor Red
    Write-Host $return
}

$timeoutSeconds = 120
$pollIntervalSeconds = 10
$found = $false
for ($elapsed = 0; $elapsed -lt $timeoutSeconds; $elapsed += $pollIntervalSeconds)
{
    Write-Host "Checking Directory Readers membership ($elapsed seconds)..."
    $members = Get-MgDirectoryRoleMember `
        -DirectoryRoleId $RoleDirReaders.Id `
        -All
    if ($members.Id -contains $managedInstancePrincipalId)
    {
        $found = $true
        Write-Host "Managed Identity found in Directory Readers role."
        break
    }
    Start-Sleep -Seconds $pollIntervalSeconds
}
if (-not $found)
{
    throw "Managed Identity did not appear in Directory Readers role within 2 minutes."
}

try {
    $SQLMiEntraAdmin = Get-AzADUser -ObjectId @($AllowedEntraUserIds)[0] -ErrorAction Stop
    # Entra Admin auf der MI setzen
    #$return = Set-AzSqlInstanceActiveDirectoryAdministrator `
    #    -ResourceGroupName $sharedResourceGroup `
    #    -InstanceName $managedInstance.ManagedInstanceName `
    #    -DisplayName $SQLMiEntraAdmin.DisplayName `
    #    -ObjectId $SQLMiEntraAdmin.Id -ErrorAction Stop
    
    # Concatenate the query string; "$var?api-version=..." interpolates as a scoped variable.
    $adminPath = $managedInstance.Id + '/administrators/ActiveDirectory?api-version=2023-08-01-preview'
    $payload = @{
        properties = @{
            administratorType = 'ActiveDirectory'
            login             = $SQLMiEntraAdmin.UserPrincipalName
            sid               = $SQLMiEntraAdmin.Id
            tenantId          = (Get-AzContext).Tenant.Id
        }
    } | ConvertTo-Json -Depth 5
    $resp = Invoke-AzRestMethod -Method PUT -Path $adminPath -Payload $payload
    if ($resp.StatusCode -notin 200, 201, 202) {
        throw "Set MI Entra admin failed (HTTP $($resp.StatusCode)): $($resp.Content)"
    }
}
catch {
    Write-Host "Failed to set Entra ID Admin on $managedInstanceFQDN." -ForegroundColor Red
    $ErrorString = $_ | format-list -force | Out-String
    Write-Host "ERR: $ErrorString" -ForegroundColor Red
}

$timeoutSeconds = 120
$pollIntervalSeconds = 10
$found = $false
for ($elapsed = 0; $elapsed -lt $timeoutSeconds; $elapsed += $pollIntervalSeconds)
{
    Write-Host "Checking Entra ID Admin ($elapsed seconds)..."
    try
    {
        $admin = Get-AzSqlInstanceActiveDirectoryAdministrator `
            -ResourceGroupName $sharedResourceGroup `
            -InstanceName $managedInstanceName `
            -ErrorAction Stop

        if ($admin.Id -eq $SQLMiEntraAdmin.Id)
        {
            Write-Host "Expected Entra ID Admin is configured."

            $found = $true
            break
        }
    }
    catch
    {
        Write-Host "No Entra ID Admin configured yet."
    }
    Start-Sleep -Seconds $pollIntervalSeconds
}
if (-not $found)
{
    throw "Expected Entra ID Admin was not configured within 2 minutes."
}

@{"HackboxCredential" = @{name = 'Legacy SQL Server Name'; value = $legacySQLName; note = 'Name of legacy SQL Server'}}
@{"HackboxCredential" = @{name = 'SQLMI FQDN'; value = $managedInstanceFQDN; note = 'FQDN of SQLMI'}}
@{"HackboxCredential" = @{name = 'Arc SQL Server Name'; value = $arcSQLName; note = 'Name of new SQL Server'}}

@{"HackboxCredential" = @{name = 'VM User Name'; value = $AdminUsername; note = 'Username to connect for every VM'}}
@{"HackboxCredential" = @{name = 'VM User Password'; value = $AdminPassword; note = 'Password to connect to every VM'}}
@{"HackboxCredential" = @{name = 'SQLMI User Name'; value = $SqlMiAdminUsername; note = 'Username to connect to SQLMI'}}
@{"HackboxCredential" = @{name = 'SQLMI User Password'; value = $SqlMiAdminPassword; note = 'Password to connect to every VM'}}
