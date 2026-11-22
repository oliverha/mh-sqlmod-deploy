<#
.SYNOPSIS
    Local test of the SQL Modernization MicroHack in your own MCAPS environment.

.DESCRIPTION
    1. Sign in to Microsoft Graph (device code) and check that the Global Administrator role is active
    2. Sign in to Az PowerShell and Azure CLI in the MCAPS tenant
    3. Select the MCAPS subscription
    4. Create the shared RG and the lab RG(s) in swedencentral
    5. Run shared-deploy-lab.ps1 (optionally followed by deploy-lab.ps1, like the platform does)

    The local Graph login only uses the process cache, not the persistent Graph user cache.
    The shared deployment connects to Graph separately via Az. Before a new local Graph login,
    an existing Graph session is disconnected so that its access token is not read as MSAL cache.
    -SkipGraphLogin only skips this login; the shared deployment still uses a Graph token
    obtained via Az. The Global Administrator check is not possible in that case.

    With -LabUserCount, local Entra ID test users LABUSER-0001 ... are created (UPN labuser-0001@<domain>),
    one lab RG/lab VM is deployed per test user, and a Temporary Access Pass (TAP) is created for each user
    at the end. The TAPs are created after the deployments so that their lifetime (default 8 hours) is
    still available for the lab. This requires an active Global Administrator role (or User Administrator +
    Authentication Administrator) and a TAP policy that allows the requested lifetime.
    With -CheckTapPolicyOnly the script only checks whether TAPs with the requested lifetime are allowed
    (nothing is created or deployed).

.NOTES
    Run it from the labautomation folder in the adminpwsh container:

        cd <...>\03-Azure\01-02 Data\<SQLModAI>\labautomation
        docker run -it -v '.\:/app' --rm "ghcr.io/qxsch/adminpwsh:latest"
        cd /app
        ./Start-LocalLabTest.ps1 -TenantId <MCAPS-tenant-id>

    Examples:
        ./Start-LocalLabTest.ps1 -TenantId <id>                                   # shared stage only
        ./Start-LocalLabTest.ps1 -TenantId <id> -RunLabDeployment                 # shared stage + lab VM
        ./Start-LocalLabTest.ps1 -TenantId <id> -SubscriptionId <sub-id>          # use a specific subscription
        ./Start-LocalLabTest.ps1 -TenantId <id> -CheckTapPolicyOnly               # am I allowed to create 8h TAPs?
        ./Start-LocalLabTest.ps1 -TenantId <id> -LabUserCount 3 -RunLabDeployment # LABUSER-0001..0003 + 3 lab VMs + TAPs
#>
[CmdletBinding()]
param(
    # Tenant ID (GUID) or domain of the MCAPS tenant
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    # Use a specific subscription - otherwise the subscription is searched with the name filter
    [string]$SubscriptionId = '',

    # Name filter for the MCAPS subscription
    [string]$SubscriptionNameFilter = 'MCAP',

    [string]$Location = 'swedencentral',

    [string]$SharedResourceGroupName = 'rg-sqlhack-shared',

    # Resource group for the lab VM (local simulation of the participant RG).
    # With -LabUserCount, one RG per test user is used: '<name>-labuser-0001' etc.
    [string]$LabResourceGroupName = 'rg_lab_local',

    # Skip the separate Graph login; the shared deployment then uses a Graph token obtained via Az
    [switch]$SkipGraphLogin,

    # Also run deploy-lab.ps1 after the shared stage succeeded
    [switch]$RunLabDeployment,

    # Number of local Entra ID test users (LABUSER-0001 ...) and therefore lab VMs. 0 = only the signed-in user, no test users.
    [ValidateRange(0, 9999)]
    [int]$LabUserCount = 0,

    # Number of the first test user (LABUSER-0001 = 1). Allows to add more test users later, e.g. starting at 11.
    [ValidateRange(1, 9999)]
    [int]$FirstLabUserNumber = 1,

    # Domain of the test users (UPN labuser-0001@<domain>). Default: default domain of the tenant.
    [string]$UserDomain = '',

    # Lifetime of the Temporary Access Pass in minutes (default 480 = 8 hours)
    [ValidateRange(10, 43200)]
    [int]$TapLifetimeMinutes = 480,

    # Adjust the TAP policy of the tenant (enabled, lifetime, reusable) if it does not allow the lifetime
    [switch]$UpdateTapPolicy,

    # Only sign in to Graph and check the TAP policy; nothing is created or deployed
    [switch]$CheckTapPolicyOnly,

    # Skip the check that the Global Administrator role is active (e.g. if another sufficient role is used)
    [switch]$SkipGlobalAdminCheck,

    # File the test users and their TAPs are written to (contains secrets, excluded by .gitignore)
    [string]$TapOutputFile = (Join-Path $PSScriptRoot 'local-lab-taps.csv')
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

function Connect-LocalGraph {
    param([string[]]$Scopes)
    # The shared deployment leaves an access token in the Graph process cache, not an MSAL JSON.
    if (Get-MgContext) {
        Write-Host '    Existing Graph session and process cache are reset.'
        Disconnect-MgGraph -ErrorAction Stop | Out-Null
    }
    Connect-MgGraph -TenantId $TenantId -UseDeviceCode -NoWelcome -ContextScope Process -Scopes $Scopes
    $graphUser = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=userPrincipalName').userPrincipalName
    Write-Host "    Graph connected as $graphUser" -ForegroundColor Green
}

function Get-GraphScopes {
    $policyScope = if ($UpdateTapPolicy) { 'Policy.ReadWrite.AuthenticationMethod' } else { 'Policy.Read.All' }
    if ($CheckTapPolicyOnly) { return @($policyScope, 'RoleManagement.Read.Directory') }

    $scopes = @('Application.Read.All', 'RoleManagement.ReadWrite.Directory')
    if ($LabUserCount -gt 0) {
        $scopes += 'User.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All', 'Domain.Read.All', $policyScope
    }
    $scopes
}

# Checks whether the signed-in user currently has the Global Administrator role active (directly or via group).
# With PIM only an activated role counts, an "eligible" assignment is not sufficient.
function Get-GlobalAdminStatus {
    $globalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'
    $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
    $status = [pscustomobject]@{ User = $me.userPrincipalName; Source = ''; ActiveRoles = @(); IsGlobalAdmin = $false }

    # Activated roles (also via PIM or role-assignable group) show up as directoryRole in transitiveMemberOf
    try {
        $roles = @((Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=id,roleTemplateId,displayName').value)
        $status.Source = 'transitiveMemberOf'
        $status.ActiveRoles = @($roles | ForEach-Object { $_.displayName })
        $status.IsGlobalAdmin = @($roles | Where-Object { $_.roleTemplateId -eq $globalAdminRoleId }).Count -gt 0
        return $status
    }
    catch {
        Write-Host "    transitiveMemberOf is not available ($($_.Exception.Message)), checking direct role assignments." -ForegroundColor Yellow
    }

    # Fallback: direct active role assignments
    $filter = [uri]::EscapeDataString("principalId eq '$($me.id)' and roleDefinitionId eq '$globalAdminRoleId'")
    $assignments = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$filter").value)
    $status.Source = 'roleAssignments'
    $status.IsGlobalAdmin = $assignments.Count -gt 0
    $status
}

# Checks whether the TAP policy of the tenant allows TAPs with the requested lifetime. Returns $true if it does.
function Test-TapPolicy {
    $uri = 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'
    $policy = Invoke-MgGraphRequest -Method GET -Uri $uri

    Write-Host ("    TAP policy: state={0}, lifetime min/default/max = {1}/{2}/{3} minutes, one-time use={4}" -f `
            $policy.state, $policy.minimumLifetimeInMinutes, $policy.defaultLifetimeInMinutes, $policy.maximumLifetimeInMinutes, $policy.isUsableOnce)

    $patch = @{ '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration' }
    $problems = @()

    if ($policy.state -ne 'enabled') {
        $problems += 'The TAP method is not enabled in the tenant.'
        $patch.state = 'enabled'
    }
    if ($policy.maximumLifetimeInMinutes -lt $TapLifetimeMinutes) {
        $problems += "The maximum TAP lifetime ($($policy.maximumLifetimeInMinutes) min) is smaller than $TapLifetimeMinutes min."
        $patch.maximumLifetimeInMinutes = $TapLifetimeMinutes
    }
    if ($policy.minimumLifetimeInMinutes -gt $TapLifetimeMinutes) {
        $problems += "The minimum TAP lifetime ($($policy.minimumLifetimeInMinutes) min) is larger than $TapLifetimeMinutes min."
        $patch.minimumLifetimeInMinutes = $TapLifetimeMinutes
    }
    if ($policy.isUsableOnce) {
        $problems += 'The policy only allows one-time use TAPs; reusable TAPs are required for a lab.'
        $patch.isUsableOnce = $false
    }
    $allUsers = @($policy.includeTargets | Where-Object { $_.id -eq 'all_users' })
    if ($allUsers.Count -eq 0) {
        $problems += 'The TAP policy does not apply to all users (includeTargets). The test users must be members of the included group.'
        $patch.includeTargets = @(@{ targetType = 'group'; id = 'all_users'; isRegistrationRequired = $false })
    }

    if ($problems.Count -eq 0) {
        Write-Host "    According to the policy, TAPs with a lifetime of $TapLifetimeMinutes minutes are allowed." -ForegroundColor Green
        return $true
    }

    $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }

    if (-not $UpdateTapPolicy) {
        Write-Host '    Use -UpdateTapPolicy to let the script adjust the policy (Entra ID > Authentication methods > Temporary Access Pass).' -ForegroundColor Yellow
        return $false
    }

    Write-Host '    Adjusting the TAP policy...' -ForegroundColor Yellow
    Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($patch | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
    Write-Host '    TAP policy adjusted. Note: MCAPS governance may reset the policy.' -ForegroundColor Green
    return $true
}

function New-RandomPassword {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%&*?')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Get-Char([string]$Chars) {
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $Chars[[int]([BitConverter]::ToUInt32($b, 0) % $Chars.Length)]
    }
    $chars = @($sets | ForEach-Object { Get-Char $_ })
    $chars += 1..20 | ForEach-Object { Get-Char ($sets -join '') }
    ($chars | Sort-Object { Get-Random }) -join ''
}

function Get-LocalLabUserName([int]$Number) { 'LABUSER-{0:D4}' -f $Number }

function Confirm-LocalLabUser {
    param([int]$Number, [string]$Domain)
    $name = Get-LocalLabUserName $Number
    $upn = "$($name.ToLower())@$Domain"
    $filter = [uri]::EscapeDataString("userPrincipalName eq '$upn'")
    $existing = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users?`$filter=$filter&`$select=id,userPrincipalName").value)

    if ($existing.Count -gt 0) {
        Write-Host "    User $upn already exists - reusing it." -ForegroundColor Yellow
        return [pscustomobject]@{ Name = $name; UserPrincipalName = $upn; Id = $existing[0].id }
    }

    $body = @{
        accountEnabled    = $true
        displayName       = $name
        mailNickname      = $name.ToLower()
        userPrincipalName = $upn
        passwordProfile   = @{ forceChangePasswordNextSignIn = $false; password = (New-RandomPassword) }
    } | ConvertTo-Json -Depth 5
    $created = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' -Body $body -ContentType 'application/json'
    Write-Host "    User $upn created." -ForegroundColor Green
    [pscustomobject]@{ Name = $name; UserPrincipalName = $upn; Id = $created.id }
}

function New-LocalLabTap {
    param([pscustomobject]$User)
    $base = "https://graph.microsoft.com/v1.0/users/$($User.Id)/authentication/temporaryAccessPassMethods"

    # Remove existing TAPs so that a new TAP with a fresh lifetime can be created
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            foreach ($old in @((Invoke-MgGraphRequest -Method GET -Uri $base).value)) {
                Invoke-MgGraphRequest -Method DELETE -Uri "$base/$($old.id)" | Out-Null
            }
            $tap = Invoke-MgGraphRequest -Method POST -Uri $base -ContentType 'application/json' `
                -Body (@{ lifetimeInMinutes = $TapLifetimeMinutes; isUsableOnce = $false } | ConvertTo-Json)
            return [pscustomobject]@{
                User    = $User.UserPrincipalName
                Team    = $User.Name
                TAP     = $tap.temporaryAccessPass
                Expires = ([datetime]$tap.startDateTime).ToLocalTime().AddMinutes($TapLifetimeMinutes).ToString('yyyy-MM-dd HH:mm')
            }
        }
        catch {
            # Newly created users are briefly not visible to the authentication methods API (replication)
            if ($attempt -eq 10) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

function Confirm-ResourceGroup {
    param([string]$Name, [string]$Location)
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Host "    RG '$Name' already exists ($($rg.Location)) - reusing it." -ForegroundColor Yellow
    }
    else {
        New-AzResourceGroup -Name $Name -Location $Location | Out-Null
        Write-Host "    RG '$Name' created in '$Location'." -ForegroundColor Green
    }
}

function Show-HackboxCredentials {
    param($Output, [string]$Stage)
    $creds = @($Output | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('HackboxCredential') } |
               ForEach-Object { [pscustomobject]$_.HackboxCredential })
    if ($creds.Count -gt 0) {
        Write-Host "`n    HackboxCredentials from $($Stage):" -ForegroundColor Green
        $creds | Format-Table name, value, note -AutoSize | Out-Host
    }
}

# ---------------------------------------------------------------------------
# 0) Validation, Graph login and Global Administrator check (stops immediately if the role is not active)
# ---------------------------------------------------------------------------
if ($LabUserCount -gt 0 -and $SkipGraphLogin) {
    throw '-LabUserCount requires the Graph login, -SkipGraphLogin cannot be used.'
}
if ($CheckTapPolicyOnly -and $SkipGraphLogin) {
    throw '-CheckTapPolicyOnly requires the Graph login, -SkipGraphLogin cannot be used.'
}
if ($LabUserCount -gt 0 -and ($FirstLabUserNumber + $LabUserCount - 1) -gt 9999) {
    throw "The test user numbers would exceed 9999 ($FirstLabUserNumber + $LabUserCount - 1)."
}

if (-not $SkipGraphLogin) {
    Write-Step 'Microsoft Graph sign-in (device code)'
    Connect-LocalGraph -Scopes (Get-GraphScopes)

    if (-not $SkipGlobalAdminCheck) {
        Write-Step 'Checking that the Global Administrator role is active'
        $adminStatus = Get-GlobalAdminStatus
        Write-Host "    Signed in as:  $($adminStatus.User)"
        Write-Host "    Active roles:  $(if ($adminStatus.ActiveRoles.Count -gt 0) { $adminStatus.ActiveRoles -join ', ' } else { '(none found)' })  [source: $($adminStatus.Source)]"
        if (-not $adminStatus.IsGlobalAdmin) {
            throw "The 'Global Administrator' role is not active for '$($adminStatus.User)'. Please activate it in PIM first (then wait 1-2 minutes if necessary) and restart the script. Use -SkipGlobalAdminCheck to skip this check."
        }
        Write-Host '    Global Administrator is active.' -ForegroundColor Green
    }
}
elseif (-not $SkipGlobalAdminCheck) {
    Write-Warning 'The Global Administrator role cannot be checked with -SkipGraphLogin.'
}

if ($CheckTapPolicyOnly) {
    Write-Step 'Checking the TAP policy'
    $tapAllowed = Test-TapPolicy
    if (-not $tapAllowed) { Write-Warning "TAPs with a lifetime of $TapLifetimeMinutes minutes are currently not allowed." }
    return
}

# ---------------------------------------------------------------------------
# 1) Az PowerShell
# ---------------------------------------------------------------------------
Write-Step "Az PowerShell sign-in to tenant '$TenantId' (device code)"
Connect-AzAccount -Tenant $TenantId -UseDeviceAuthentication | Out-Null

# ---------------------------------------------------------------------------
# 2) Select the MCAPS subscription
# ---------------------------------------------------------------------------
Write-Step 'Selecting the subscription'
if (-not $SubscriptionId) {
    $subs = @(Get-AzSubscription -TenantId $TenantId |
              Where-Object { $_.State -eq 'Enabled' -and $_.Name -like "*$SubscriptionNameFilter*" } |
              Sort-Object Name)

    if ($subs.Count -eq 0) {
        throw "No enabled subscription with '$SubscriptionNameFilter' in its name found. Specify -SubscriptionId or -SubscriptionNameFilter."
    }
    elseif ($subs.Count -eq 1) {
        $selected = $subs[0]
    }
    else {
        for ($i = 0; $i -lt $subs.Count; $i++) {
            Write-Host ("    [{0}] {1}  ({2})" -f $i, $subs[$i].Name, $subs[$i].Id)
        }
        do {
            $choice = Read-Host '    Number of the subscription'
        } until ($choice -match '^\d+$' -and [int]$choice -lt $subs.Count)
        $selected = $subs[[int]$choice]
    }
    $SubscriptionId = $selected.Id
}

Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
$ctx = Get-AzContext
Write-Host "    Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Green
Write-Host "    Account:      $($ctx.Account.Id)"
Write-Host "    Location:     $Location"

# ---------------------------------------------------------------------------
# 3) Azure CLI (used by az calls in the scripts)
# ---------------------------------------------------------------------------
Write-Step 'Azure CLI sign-in (device code)'
az login --tenant $TenantId --use-device-code --output none
if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw 'az account set failed.' }

# ---------------------------------------------------------------------------
# 4) Microsoft Graph: the login already happened in step 0
# 4b) Optional: create the local Entra ID test users LABUSER-0001 ...
# ---------------------------------------------------------------------------
$labUsers = @()
if ($LabUserCount -gt 0) {
    Write-Step 'Checking the TAP policy'
    if (-not (Test-TapPolicy)) {
        throw "TAPs with a lifetime of $TapLifetimeMinutes minutes are not allowed. Adjust the policy in the tenant or use -UpdateTapPolicy or -TapLifetimeMinutes."
    }

    Write-Step "Creating / checking $LabUserCount Entra ID test users"
    if (-not $UserDomain) {
        $UserDomain = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains').value |
            Where-Object { $_.isDefault } | Select-Object -First 1 -ExpandProperty id
    }
    Write-Host "    Domain: $UserDomain"
    $labUsers = @($FirstLabUserNumber..($FirstLabUserNumber + $LabUserCount - 1) |
        ForEach-Object { Confirm-LocalLabUser -Number $_ -Domain $UserDomain })
}

# ---------------------------------------------------------------------------
# 5) Create the resource groups
# ---------------------------------------------------------------------------
Write-Step 'Checking / creating resource groups'
Confirm-ResourceGroup -Name $SharedResourceGroupName -Location $Location

$me = (Get-AzADUser -SignedIn).Id
if ($labUsers.Count -gt 0) {
    # The permissions on the RGs are granted by the deployment framework based on the passed Entra IDs
    $allowedIds = @($me) + @($labUsers | ForEach-Object { $_.Id })
    foreach ($labUser in $labUsers) {
        $labUser | Add-Member -NotePropertyName ResourceGroupName -NotePropertyValue "$LabResourceGroupName-$($labUser.Name.ToLower())"
        Confirm-ResourceGroup -Name $labUser.ResourceGroupName -Location $Location
    }
}
else {
    $allowedIds = @($me)
    Confirm-ResourceGroup -Name $LabResourceGroupName -Location $Location
}
Write-Host "    AllowedEntraUserIds: $($allowedIds -join ', ')"

# ---------------------------------------------------------------------------
# 6) Run shared-deploy-lab.ps1
# ---------------------------------------------------------------------------
$sharedScript = Join-Path $PSScriptRoot 'shared-deploy-lab.ps1'
if (-not (Test-Path $sharedScript)) { throw "shared-deploy-lab.ps1 not found in '$PSScriptRoot'." }

if (-not (Select-String -Path $sharedScript -SimpleMatch $SharedResourceGroupName -Quiet)) {
    Write-Warning "The name '$SharedResourceGroupName' does not appear in shared-deploy-lab.ps1. Please adjust `$sharedResourceGroup there, otherwise a different RG is used."
}

Write-Step 'Running shared-deploy-lab.ps1'
$sharedOutput = & $sharedScript `
    -SubscriptionId      $SubscriptionId `
    -PreferredLocation   $Location `
    -AllowedEntraUserIds $allowedIds
Show-HackboxCredentials -Output $sharedOutput -Stage 'shared-deploy-lab.ps1'
Write-Host '    Shared stage completed.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 7) Optional: deploy-lab.ps1 for the lab VM(s)
# ---------------------------------------------------------------------------
if ($RunLabDeployment) {
    $labScript = Join-Path $PSScriptRoot 'deploy-lab.ps1'
    if (-not (Test-Path $labScript)) { throw "deploy-lab.ps1 not found in '$PSScriptRoot'." }

    # Without test users: one lab VM for the signed-in user, otherwise one lab VM per test user (one after the other)
    $labTargets = if ($labUsers.Count -gt 0) {
        $labUsers | ForEach-Object { [pscustomobject]@{ ResourceGroupName = $_.ResourceGroupName; UserId = $_.Id } }
    }
    else {
        [pscustomobject]@{ ResourceGroupName = $LabResourceGroupName; UserId = $me }
    }

    foreach ($target in $labTargets) {
        Write-Step "Running deploy-lab.ps1 in '$($target.ResourceGroupName)'"
        $labOutput = & $labScript `
            -DeploymentType      'resourcegroup' `
            -SubscriptionId      $SubscriptionId `
            -ResourceGroupName   $target.ResourceGroupName `
            -PreferredLocation   $Location `
            -AllowedEntraUserIds $target.UserId
        Show-HackboxCredentials -Output $labOutput -Stage "deploy-lab.ps1 ($($target.ResourceGroupName))"
    }
    Write-Host '    Lab deployment completed.' -ForegroundColor Green
}
else {
    Write-Host "`nLab VM not deployed yet. Use -RunLabDeployment to run deploy-lab.ps1." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 8) TAPs for the test users (created only now so that the lifetime starts after the deployment)
# ---------------------------------------------------------------------------
if ($labUsers.Count -gt 0) {
    # The shared deployment replaces the Graph session with an Az token (without the required scopes), and the token has expired after the deployments
    $graphContext = Get-MgContext
    if (-not $graphContext -or $graphContext.AuthType -eq 'UserProvidedAccessToken' -or $graphContext.Scopes -notcontains 'UserAuthenticationMethod.ReadWrite.All') {
        Write-Step 'Microsoft Graph sign-in for the TAPs (device code)'
        Connect-LocalGraph -Scopes (Get-GraphScopes)
    }

    Write-Step "Creating Temporary Access Passes ($TapLifetimeMinutes minutes) for $($labUsers.Count) test users"
    $taps = @($labUsers | ForEach-Object { New-LocalLabTap -User $_ })

    Write-Host "`n    Temporary Access Passes (valid until the Expires column):" -ForegroundColor Green
    $taps | Format-Table User, Team, TAP, Expires -AutoSize | Out-Host

    if ($TapOutputFile) {
        $taps | Export-Csv -Path $TapOutputFile -NoTypeInformation -Encoding UTF8
        Write-Host "    TAPs saved to '$TapOutputFile' (contains secrets, do not check in)." -ForegroundColor Yellow
    }
}
