<#
.SYNOPSIS
    Lokaler Test des SQLModAI MicroHack in der eigenen MCAPS-Umgebung.

.DESCRIPTION
    1. Anmeldung an Az PowerShell, Azure CLI und (optional) Microsoft Graph am MCAPS-Tenant
    2. Auswahl der MCAPS-Subscription
    3. Anlage der Shared RG (rg_shared) und der Lab-RG für die Lab-VM in swedencentral
    4. Start von shared-deploy-lab.ps1 (optional danach deploy-lab.ps1, wie es die Plattform tut)
    Der lokale Graph-Login nutzt nur den Prozess-Cache, nicht den persistenten
    Graph-Benutzercache. Das Shared-Deployment verbindet Graph separat über Az.
    Vor einem erneuten lokalen Graph-Login wird eine vorhandene Graph-Sitzung
    getrennt, damit deren Access-Token nicht als MSAL-Cache eingelesen wird.
    -SkipGraphLogin überspringt nur diesen Login; das Shared-Deployment verwendet
    dann weiterhin ein über Az bezogenes Graph-Token.

    Mit -LabUserCount werden lokale Entra-ID-Testuser LABUSER-0001 ... angelegt (UPN labuser-0001@<Domain>),
    für jeden Testuser eine eigene Lab-RG/Lab-VM deployt und am Ende pro User ein Temporary Access Pass (TAP)
    erzeugt. Der TAP wird erst nach den Deployments erstellt, damit die Laufzeit (Standard 8 Stunden) für das
    Lab nutzbar bleibt. Dafür sind Global Administrator (oder User Administrator + Authentication Administrator)
    und eine TAP-Policy erforderlich, die die gewünschte Laufzeit erlaubt. Mit -CheckTapPolicyOnly wird nur
    geprüft, ob TAPs mit der gewünschten Laufzeit erlaubt sind (nichts wird angelegt oder deployt).

.NOTES
    Im adminpwsh-Container aus dem labautomation-Ordner ausführen:

        cd <...>\03-Azure\01-02 Data\<SQLModAI>\labautomation
        docker run -it -v '.\:/app' --rm "ghcr.io/qxsch/adminpwsh:latest"
        cd /app
        ./Start-LocalLabTest.ps1 -TenantId <MCAPS-Tenant-ID>

    Beispiele:
        ./Start-LocalLabTest.ps1 -TenantId <id>                                  # nur Shared-Stage
        ./Start-LocalLabTest.ps1 -TenantId <id> -RunLabDeployment                # Shared + Lab-VM
        ./Start-LocalLabTest.ps1 -TenantId <id> -SubscriptionId <sub-id>         # Subscription direkt
        ./Start-LocalLabTest.ps1 -TenantId <id> -CheckTapPolicyOnly              # darf ich 8h-TAPs erstellen?
        ./Start-LocalLabTest.ps1 -TenantId <id> -LabUserCount 3 -RunLabDeployment # LABUSER-0001..0003 + 3 Lab-VMs + TAPs
#>
[CmdletBinding()]
param(
    # Tenant-ID (GUID) oder Domain des MCAPS-Tenants
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    # Direkt eine Subscription vorgeben – sonst wird nach dem Namensfilter gesucht
    [string]$SubscriptionId = '',

    # Namensfilter für die MCAPS-Subscription
    [string]$SubscriptionNameFilter = 'MCAP',

    [string]$Location = 'swedencentral',

    [string]$SharedResourceGroupName = 'rg-sqlhack-shared',

    # Resource Group für die Lab-VM (lokale Simulation der Teilnehmer-RG).
    # Mit -LabUserCount wird pro Testuser eine RG '<Name>-labuser-0001' usw. verwendet.
    [string]$LabResourceGroupName = 'rg_lab_local',

    # Separaten Graph-Login überspringen; Shared-Deployment nutzt dann ein Az-Graph-Token
    [switch]$SkipGraphLogin,

    # Nach erfolgreicher Shared-Stage auch deploy-lab.ps1 starten
    [switch]$RunLabDeployment,

    # Anzahl lokaler Entra-ID-Testuser (LABUSER-0001 ...) und damit Lab-VMs. 0 = nur der angemeldete User, keine Testuser.
    [ValidateRange(0, 9999)]
    [int]$LabUserCount = 0,

    # Nummer des ersten Testusers (LABUSER-0001 = 1). Erlaubt z. B. weitere Testuser ab 11 nachzuziehen.
    [ValidateRange(1, 9999)]
    [int]$FirstLabUserNumber = 1,

    # Domain der Testuser (UPN labuser-0001@<Domain>). Standard: Standarddomain des Tenants.
    [string]$UserDomain = '',

    # Laufzeit des Temporary Access Pass in Minuten (Standard 480 = 8 Stunden)
    [ValidateRange(10, 43200)]
    [int]$TapLifetimeMinutes = 480,

    # Passt die TAP-Policy des Tenants an (aktiv, Laufzeit, mehrfach nutzbar), falls sie die Laufzeit nicht erlaubt
    [switch]$UpdateTapPolicy,

    # Nur Graph-Login und Prüfung der TAP-Policy; es wird nichts angelegt oder deployt
    [switch]$CheckTapPolicyOnly,

    # Überspringt die Prüfung, ob die Global-Administrator-Rolle aktiviert ist (z. B. bei anderen ausreichenden Rollen)
    [switch]$SkipGlobalAdminCheck,

    # Datei, in die die Testuser mit TAP geschrieben werden (enthält Geheimnisse, per .gitignore ausgenommen)
    [string]$TapOutputFile = (Join-Path $PSScriptRoot 'local-lab-taps.csv')
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

function Connect-LocalGraph {
    param([string[]]$Scopes)
    # Das Shared-Deployment hinterlaesst ein Access-Token im Graph-Prozess-Cache, kein MSAL-JSON.
    if (Get-MgContext) {
        Write-Host '    Vorhandene Graph-Sitzung und Prozess-Cache werden zurueckgesetzt.'
        Disconnect-MgGraph -ErrorAction Stop | Out-Null
    }
    Connect-MgGraph -TenantId $TenantId -UseDeviceCode -NoWelcome -ContextScope Process -Scopes $Scopes
    Write-Host "    Graph verbunden als $((Get-MgContext).Account)" -ForegroundColor Green
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

# Prüft, ob der angemeldete User die Rolle Global Administrator aktuell aktiv hat (direkt oder per Gruppe).
# Bei PIM zählt nur eine aktivierte Rolle, eine "eligible" Zuweisung genügt nicht.
function Test-GlobalAdminActive {
    $globalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'
    $meId = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id').id
    $filter = [uri]::EscapeDataString("principalId eq '$meId' and roleDefinitionId eq '$globalAdminRoleId'")
    $assignments = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/transitiveRoleAssignments?`$filter=$filter").value)
    $assignments.Count -gt 0
}

# Prüft, ob die TAP-Policy des Tenants TAPs mit der gewünschten Laufzeit erlaubt. Gibt $true zurück, wenn ja.
function Test-TapPolicy {
    $uri = 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'
    $policy = Invoke-MgGraphRequest -Method GET -Uri $uri

    Write-Host ("    TAP-Policy: Status={0}, Laufzeit min/default/max = {1}/{2}/{3} Minuten, einmalig nutzbar={4}" -f `
            $policy.state, $policy.minimumLifetimeInMinutes, $policy.defaultLifetimeInMinutes, $policy.maximumLifetimeInMinutes, $policy.isUsableOnce)

    $patch = @{ '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration' }
    $problems = @()

    if ($policy.state -ne 'enabled') {
        $problems += 'Die TAP-Methode ist im Tenant nicht aktiviert.'
        $patch.state = 'enabled'
    }
    if ($policy.maximumLifetimeInMinutes -lt $TapLifetimeMinutes) {
        $problems += "Die maximale TAP-Laufzeit ($($policy.maximumLifetimeInMinutes) Min) ist kleiner als $TapLifetimeMinutes Min."
        $patch.maximumLifetimeInMinutes = $TapLifetimeMinutes
    }
    if ($policy.minimumLifetimeInMinutes -gt $TapLifetimeMinutes) {
        $problems += "Die minimale TAP-Laufzeit ($($policy.minimumLifetimeInMinutes) Min) ist größer als $TapLifetimeMinutes Min."
        $patch.minimumLifetimeInMinutes = $TapLifetimeMinutes
    }
    if ($policy.isUsableOnce) {
        $problems += 'Die Policy erlaubt nur einmal nutzbare TAPs; für ein Lab werden mehrfach nutzbare TAPs benötigt.'
        $patch.isUsableOnce = $false
    }
    $allUsers = @($policy.includeTargets | Where-Object { $_.id -eq 'all_users' })
    if ($allUsers.Count -eq 0) {
        $problems += 'Die TAP-Policy gilt nicht für alle Benutzer (includeTargets). Die Testuser müssen Mitglied der eingeschlossenen Gruppe sein.'
        $patch.includeTargets = @(@{ targetType = 'group'; id = 'all_users'; isRegistrationRequired = $false })
    }

    if ($problems.Count -eq 0) {
        Write-Host "    TAPs mit $TapLifetimeMinutes Minuten Laufzeit sind laut Policy erlaubt." -ForegroundColor Green
        return $true
    }

    $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }

    if (-not $UpdateTapPolicy) {
        Write-Host '    Mit -UpdateTapPolicy kann das Skript die Policy anpassen (Entra ID > Authentifizierungsmethoden > Temporary Access Pass).' -ForegroundColor Yellow
        return $false
    }

    Write-Host '    Passe die TAP-Policy an...' -ForegroundColor Yellow
    Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($patch | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
    Write-Host '    TAP-Policy angepasst. Hinweis: MCAPS-Governance kann die Policy wieder zurücksetzen.' -ForegroundColor Green
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
        Write-Host "    User $upn existiert bereits - wird wiederverwendet." -ForegroundColor Yellow
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
    Write-Host "    User $upn angelegt." -ForegroundColor Green
    [pscustomobject]@{ Name = $name; UserPrincipalName = $upn; Id = $created.id }
}

function New-LocalLabTap {
    param([pscustomobject]$User)
    $base = "https://graph.microsoft.com/v1.0/users/$($User.Id)/authentication/temporaryAccessPassMethods"

    # Vorhandene TAPs entfernen, damit ein neuer TAP mit frischer Laufzeit erstellt werden kann
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
            # Neu angelegte User sind für die Authentifizierungsmethoden-API kurz nicht sichtbar (Replikation)
            if ($attempt -eq 10) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

function Confirm-ResourceGroup {
    param([string]$Name, [string]$Location)
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Host "    RG '$Name' existiert bereits ($($rg.Location)) - wird wiederverwendet." -ForegroundColor Yellow
    }
    else {
        New-AzResourceGroup -Name $Name -Location $Location | Out-Null
        Write-Host "    RG '$Name' in '$Location' angelegt." -ForegroundColor Green
    }
}

function Show-HackboxCredentials {
    param($Output, [string]$Stage)
    $creds = @($Output | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('HackboxCredential') } |
               ForEach-Object { [pscustomobject]$_.HackboxCredential })
    if ($creds.Count -gt 0) {
        Write-Host "`n    HackboxCredentials aus $($Stage):" -ForegroundColor Green
        $creds | Format-Table name, value, note -AutoSize | Out-Host
    }
}

# ---------------------------------------------------------------------------
# 0) Prüfungen, Graph-Login und Global-Administrator-Check (bricht sofort ab, wenn die Rolle nicht aktiv ist)
# ---------------------------------------------------------------------------
if ($LabUserCount -gt 0 -and $SkipGraphLogin) {
    throw '-LabUserCount benötigt den Graph-Login, -SkipGraphLogin kann nicht verwendet werden.'
}
if ($CheckTapPolicyOnly -and $SkipGraphLogin) {
    throw '-CheckTapPolicyOnly benötigt den Graph-Login, -SkipGraphLogin kann nicht verwendet werden.'
}
if ($LabUserCount -gt 0 -and ($FirstLabUserNumber + $LabUserCount - 1) -gt 9999) {
    throw "Die Testuser-Nummern würden 9999 überschreiten ($FirstLabUserNumber + $LabUserCount - 1)."
}

if (-not $SkipGraphLogin) {
    Write-Step 'Anmeldung Microsoft Graph (Device Code)'
    Connect-LocalGraph -Scopes (Get-GraphScopes)

    if (-not $SkipGlobalAdminCheck) {
        Write-Step 'Prüfe, ob die Rolle Global Administrator aktiviert ist'
        if (-not (Test-GlobalAdminActive)) {
            throw "Die Rolle 'Global Administrator' ist für $((Get-MgContext).Account) nicht aktiv. Bitte zuerst in PIM aktivieren und das Skript neu starten (mit -SkipGlobalAdminCheck kann die Prüfung übersprungen werden)."
        }
        Write-Host '    Global Administrator ist aktiv.' -ForegroundColor Green
    }
}
elseif (-not $SkipGlobalAdminCheck) {
    Write-Warning 'Mit -SkipGraphLogin kann die Global-Administrator-Rolle nicht geprüft werden.'
}

if ($CheckTapPolicyOnly) {
    Write-Step 'Prüfung der TAP-Policy'
    $tapAllowed = Test-TapPolicy
    if (-not $tapAllowed) { Write-Warning "TAPs mit $TapLifetimeMinutes Minuten Laufzeit sind aktuell nicht erlaubt." }
    return
}

# ---------------------------------------------------------------------------
# 1) Az PowerShell
# ---------------------------------------------------------------------------
Write-Step "Anmeldung Az PowerShell am Tenant '$TenantId' (Device Code)"
Connect-AzAccount -Tenant $TenantId -UseDeviceAuthentication | Out-Null

# ---------------------------------------------------------------------------
# 2) MCAPS-Subscription auswählen
# ---------------------------------------------------------------------------
Write-Step 'Subscription auswählen'
if (-not $SubscriptionId) {
    $subs = @(Get-AzSubscription -TenantId $TenantId |
              Where-Object { $_.State -eq 'Enabled' -and $_.Name -like "*$SubscriptionNameFilter*" } |
              Sort-Object Name)

    if ($subs.Count -eq 0) {
        throw "Keine aktive Subscription mit '$SubscriptionNameFilter' im Namen gefunden. Mit -SubscriptionId oder -SubscriptionNameFilter angeben."
    }
    elseif ($subs.Count -eq 1) {
        $selected = $subs[0]
    }
    else {
        for ($i = 0; $i -lt $subs.Count; $i++) {
            Write-Host ("    [{0}] {1}  ({2})" -f $i, $subs[$i].Name, $subs[$i].Id)
        }
        do {
            $choice = Read-Host '    Nummer der Subscription'
        } until ($choice -match '^\d+$' -and [int]$choice -lt $subs.Count)
        $selected = $subs[[int]$choice]
    }
    $SubscriptionId = $selected.Id
}

Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
$ctx = Get-AzContext
Write-Host "    Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Green
Write-Host "    Konto:        $($ctx.Account.Id)"
Write-Host "    Location:     $Location"

# ---------------------------------------------------------------------------
# 3) Azure CLI (wird von az-Aufrufen in den Skripten genutzt)
# ---------------------------------------------------------------------------
Write-Step 'Anmeldung Azure CLI (Device Code)'
az login --tenant $TenantId --use-device-code --output none
if ($LASTEXITCODE -ne 0) { throw 'az login fehlgeschlagen.' }
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw 'az account set fehlgeschlagen.' }

# ---------------------------------------------------------------------------
# 4) Microsoft Graph: Login erfolgt bereits in Schritt 0
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 4b) Optional: lokale Entra-ID-Testuser LABUSER-0001 ... anlegen
# ---------------------------------------------------------------------------
$labUsers = @()
if ($LabUserCount -gt 0) {
    Write-Step 'TAP-Policy prüfen'
    if (-not (Test-TapPolicy)) {
        throw "TAPs mit $TapLifetimeMinutes Minuten Laufzeit sind nicht erlaubt. Policy im Tenant anpassen oder -UpdateTapPolicy bzw. -TapLifetimeMinutes verwenden."
    }

    Write-Step "$LabUserCount Entra-ID-Testuser anlegen / prüfen"
    if (-not $UserDomain) {
        $UserDomain = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains').value |
            Where-Object { $_.isDefault } | Select-Object -First 1 -ExpandProperty id
    }
    Write-Host "    Domain: $UserDomain"
    $labUsers = @($FirstLabUserNumber..($FirstLabUserNumber + $LabUserCount - 1) |
        ForEach-Object { Confirm-LocalLabUser -Number $_ -Domain $UserDomain })
}

# ---------------------------------------------------------------------------
# 5) Resource Groups anlegen
# ---------------------------------------------------------------------------
Write-Step 'Resource Groups prüfen / anlegen'
Confirm-ResourceGroup -Name $SharedResourceGroupName -Location $Location

$me = (Get-AzADUser -SignedIn).Id
if ($labUsers.Count -gt 0) {
    # Die Berechtigungen auf den RGs vergibt das Deployment-Framework anhand der übergebenen Entra-IDs
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
# 6) shared-deploy-lab.ps1 starten
# ---------------------------------------------------------------------------
$sharedScript = Join-Path $PSScriptRoot 'shared-deploy-lab.ps1'
if (-not (Test-Path $sharedScript)) { throw "shared-deploy-lab.ps1 nicht gefunden in '$PSScriptRoot'." }

if (-not (Select-String -Path $sharedScript -SimpleMatch $SharedResourceGroupName -Quiet)) {
    Write-Warning "Der Name '$SharedResourceGroupName' kommt in shared-deploy-lab.ps1 nicht vor. Bitte dort `$sharedResourceGroup anpassen, sonst wird eine andere RG verwendet."
}

Write-Step 'Starte shared-deploy-lab.ps1'
$sharedOutput = & $sharedScript `
    -SubscriptionId      $SubscriptionId `
    -PreferredLocation   $Location `
    -AllowedEntraUserIds $allowedIds
Show-HackboxCredentials -Output $sharedOutput -Stage 'shared-deploy-lab.ps1'
Write-Host '    Shared-Stage abgeschlossen.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 7) Optional: deploy-lab.ps1 für die Lab-VM(s)
# ---------------------------------------------------------------------------
if ($RunLabDeployment) {
    $labScript = Join-Path $PSScriptRoot 'deploy-lab.ps1'
    if (-not (Test-Path $labScript)) { throw "deploy-lab.ps1 nicht gefunden in '$PSScriptRoot'." }

    # Ohne Testuser: eine Lab-VM für den angemeldeten User, sonst eine Lab-VM pro Testuser (nacheinander)
    $labTargets = if ($labUsers.Count -gt 0) {
        $labUsers | ForEach-Object { [pscustomobject]@{ ResourceGroupName = $_.ResourceGroupName; UserId = $_.Id } }
    }
    else {
        [pscustomobject]@{ ResourceGroupName = $LabResourceGroupName; UserId = $me }
    }

    foreach ($target in $labTargets) {
        Write-Step "Starte deploy-lab.ps1 in '$($target.ResourceGroupName)'"
        $labOutput = & $labScript `
            -DeploymentType      'resourcegroup' `
            -SubscriptionId      $SubscriptionId `
            -ResourceGroupName   $target.ResourceGroupName `
            -PreferredLocation   $Location `
            -AllowedEntraUserIds $target.UserId
        Show-HackboxCredentials -Output $labOutput -Stage "deploy-lab.ps1 ($($target.ResourceGroupName))"
    }
    Write-Host '    Lab-Deployment abgeschlossen.' -ForegroundColor Green
}
else {
    Write-Host "`nLab-VM noch nicht deployt. Mit -RunLabDeployment wird deploy-lab.ps1 gestartet." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 8) TAPs für die Testuser (erst jetzt, damit die Laufzeit nach dem Deployment beginnt)
# ---------------------------------------------------------------------------
if ($labUsers.Count -gt 0) {
    # Das Shared-Deployment ersetzt die Graph-Sitzung durch ein Az-Token (ohne die benötigten Scopes), und das Token ist nach den Deployments abgelaufen
    $graphContext = Get-MgContext
    if (-not $graphContext -or $graphContext.AuthType -eq 'UserProvidedAccessToken' -or $graphContext.Scopes -notcontains 'UserAuthenticationMethod.ReadWrite.All') {
        Write-Step 'Anmeldung Microsoft Graph für die TAPs (Device Code)'
        Connect-LocalGraph -Scopes (Get-GraphScopes)
    }

    Write-Step "Temporary Access Pass ($TapLifetimeMinutes Minuten) für $($labUsers.Count) Testuser erstellen"
    $taps = @($labUsers | ForEach-Object { New-LocalLabTap -User $_ })

    Write-Host "`n    Temporary Access Pässe (gültig bis zur Spalte Expires):" -ForegroundColor Green
    $taps | Format-Table User, Team, TAP, Expires -AutoSize | Out-Host

    if ($TapOutputFile) {
        $taps | Export-Csv -Path $TapOutputFile -NoTypeInformation -Encoding UTF8
        Write-Host "    TAPs gespeichert in '$TapOutputFile' (enthält Geheimnisse, nicht einchecken)." -ForegroundColor Yellow
    }
}
