<#
.SYNOPSIS
Prepares the shared SQL Server 2022 VM so that participants can onboard it to Azure Arc (evaluation / demo only).
.DESCRIPTION
Implements https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine for the VM.
shared-deploy-lab.ps1 calls this script as its last step. Remove that call to skip the preparation and run this script
by hand later instead. Steps:
  1. Remove the SQL IaaS registration (Microsoft.SqlVirtualMachine, it owns the SqlIaaSAgent extension) and all VM extensions.
  2. Remove the "SQL Server - Azure Arc" resources in the shared resource group. The SQL IaaS extension creates them
     for the Azure VM with the same names the Arc onboarding uses later, so they would collide.
  3. Run scripts\Prepare-ArcReadyVm.ps1 in the VM through Azure Run Command (sets MSFT_ARC_TEST, blocks the Azure IMDS
     endpoints and disables the Azure VM Guest Agent). This is the last step that needs the guest agent.
  4. Restart the VM so that the guest agent is not running anymore.
The script is safe to repeat. A VM whose guest agent is already disabled skips step 3.
It stops without changes if the VM is already onboarded to Azure Arc (the Arc SQL resources would be deleted otherwise),
unless -Force is used.
Requires Az.Accounts, Az.Compute and Az.Resources and permissions to manage and run commands on the VM (e.g. Owner/Contributor).
.PARAMETER SubscriptionId
Subscription of the shared resource group. Default: the current Az context subscription.
.PARAMETER SharedResourceGroupName
Shared resource group holding the VM.
.PARAMETER VmName
Name of the SQL Server 2022 VM.
.PARAMETER StartStoppedVM
Start the VM if it is deallocated or stopped. It stays running afterwards.
.PARAMETER Force
Also run if an Azure Arc machine with the name of the VM exists already.
.EXAMPLE
.\Initialize-ArcReadyVm.ps1 -SubscriptionId <id> -WhatIf
.\Initialize-ArcReadyVm.ps1 -SubscriptionId <id> -StartStoppedVM
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,

    [string]$SharedResourceGroupName = 'rg-sqlhack-shared',

    [string]$VmName = 'modernSQL2022',

    [switch]$StartStoppedVM,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$guestScriptPath = Join-Path $PSScriptRoot '..\scripts\Prepare-ArcReadyVm.ps1'
if (-not (Test-Path -LiteralPath $guestScriptPath -PathType Leaf)) {
    throw "Guest script '$guestScriptPath' not found."
}

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if ($SubscriptionId -and (Get-AzContext).Subscription.Id -ne $SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

function Get-VmState {
    $status = Get-AzVM -ResourceGroupName $SharedResourceGroupName -Name $VmName -Status -ErrorAction Stop
    [pscustomobject]@{
        PowerState = ($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code
        AgentReady = [bool]($status.VMAgent.Statuses | Where-Object { $_.DisplayStatus -eq 'Ready' })
    }
}

# Run Command needs the guest agent; the script must end with SCRIPT_RESULT=Success.
function Invoke-GuestScript {
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-Host "Running $(Split-Path -Leaf $guestScriptPath) on $VmName (attempt $attempt/$maxAttempts)..."
            $runResult = Invoke-AzVMRunCommand -ResourceGroupName $SharedResourceGroupName -VMName $VmName -CommandId 'RunPowerShellScript' -ScriptPath $guestScriptPath -ErrorAction Stop
            $output = ($runResult.Value | ForEach-Object { $_.Message }) -join [Environment]::NewLine
            Write-Host $output
            if ($output -notmatch 'SCRIPT_RESULT=Success') { throw "$(Split-Path -Leaf $guestScriptPath) did not finish successfully." }
            return
        }
        catch {
            if ($attempt -eq $maxAttempts) { throw }
            Write-Host "Run command failed: $($_.Exception.Message). Retrying in 60 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 60
        }
    }
}

$arcMachine = Get-AzResource -ResourceGroupName $SharedResourceGroupName -ResourceType 'Microsoft.HybridCompute/machines' -Name $VmName -ErrorAction SilentlyContinue
if ($arcMachine -and -not $Force) {
    Write-Host "$VmName is already onboarded to Azure Arc. Nothing to prepare (use -Force to run anyway)." -ForegroundColor Yellow
    return
}

$state = Get-VmState
if ($state.PowerState -ne 'PowerState/running') {
    if (-not $StartStoppedVM) { throw "VM $VmName is not running ($($state.PowerState)). Start it or use -StartStoppedVM." }
    if ($PSCmdlet.ShouldProcess($VmName, 'Start VM')) {
        Start-AzVM -ResourceGroupName $SharedResourceGroupName -Name $VmName -ErrorAction Stop | Out-Null
        $state = Get-VmState
    }
}

Write-Host "Preparing $VmName for Azure Arc onboarding..."

# 1. SQL IaaS registration and VM extensions
if (Get-AzResource -ResourceGroupName $SharedResourceGroupName -ResourceType 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' -Name $VmName -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($VmName, 'Remove SQL IaaS registration')) {
        Remove-AzResource -ResourceGroupName $SharedResourceGroupName -ResourceType 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' -ResourceName $VmName -Force -ErrorAction Stop | Out-Null
    }
}
foreach ($extension in @(Get-AzVMExtension -ResourceGroupName $SharedResourceGroupName -VMName $VmName -ErrorAction Stop)) {
    if ($PSCmdlet.ShouldProcess("$VmName/$($extension.Name)", 'Remove VM extension')) {
        Write-Host "Removing VM extension $($extension.Name)..."
        Remove-AzVMExtension -ResourceGroupName $SharedResourceGroupName -VMName $VmName -Name $extension.Name -Force -ErrorAction Stop | Out-Null
    }
}

# 2. "SQL Server - Azure Arc" resources of the Azure VM
foreach ($arcSqlInstance in @(Get-AzResource -ResourceGroupName $SharedResourceGroupName -ResourceType 'Microsoft.AzureArcData/sqlServerInstances' -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($arcSqlInstance.Name, 'Remove SQL Server - Azure Arc resource')) {
        Write-Host "Removing SQL Server - Azure Arc resource $($arcSqlInstance.Name)..."
        Remove-AzResource -ResourceId $arcSqlInstance.ResourceId -Force -ErrorAction Stop | Out-Null
    }
}

# 3. Guest preparation
if (-not $state.AgentReady) {
    Write-Host "The guest agent of $VmName is not ready (already disabled?). The guest preparation is skipped." -ForegroundColor Yellow
}
elseif ($PSCmdlet.ShouldProcess($VmName, 'Run guest preparation')) {
    Invoke-GuestScript
}

# 4. Restart so that the guest agent is not running anymore (done by the platform, not by the agent)
if ($PSCmdlet.ShouldProcess($VmName, 'Restart VM')) {
    Restart-AzVM -ResourceGroupName $SharedResourceGroupName -Name $VmName -ErrorAction Stop | Out-Null
}

if (-not $WhatIfPreference) { Write-Host "$VmName is prepared for Azure Arc onboarding." -ForegroundColor Green }
