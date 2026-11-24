<#
.SYNOPSIS
Prepares an Azure VM so that the Azure Connected Machine agent can be installed on it (evaluation / demo only).

.DESCRIPTION
Implements the steps of
https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
that run inside the guest:
  - sets the machine environment variable MSFT_ARC_TEST so that the Arc onboarding script accepts an Azure VM,
  - blocks the Azure Instance Metadata Service (IMDS) endpoints with a firewall rule,
  - disables the Azure VM Guest Agent.

The VM extensions must already be removed (done by shared-deploy-lab.ps1 through ARM). The guest agent is only
disabled and not stopped, because this script itself runs through the guest agent (Azure Run Command). The VM has
to be restarted afterwards. Once the guest agent is disabled, neither Run Command nor VM extensions work anymore.
The script ends with SCRIPT_RESULT=Success.
#>

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\Prepare-ArcReadyVm.log'
Start-Transcript -Path $logPath -Append

try
{
    Write-Host 'Setting MSFT_ARC_TEST=true (machine scope)...'
    [System.Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', [System.EnvironmentVariableTarget]::Machine)

    # 169.254.169.254 = Azure IMDS, 169.254.169.253 = Azure Local IMDS
    Write-Host 'Blocking access to the Azure IMDS endpoints...'
    Get-NetFirewallRule -Name 'BlockAzureIMDS' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name 'BlockAzureIMDS' -DisplayName 'Block access to Azure IMDS' -Enabled True -Profile Any `
        -Direction Outbound -Action Block -RemoteAddress '169.254.169.254', '169.254.169.253' | Out-Null

    Write-Host 'Disabling the Azure VM Guest Agent...'
    Set-Service -Name 'WindowsAzureGuestAgent' -StartupType Disabled

    $startType = (Get-Service -Name 'WindowsAzureGuestAgent').StartType
    if ($startType -ne 'Disabled')
    {
        throw "The Azure VM Guest Agent start type is '$startType' instead of 'Disabled'."
    }

    Write-Host 'SCRIPT_RESULT=Success'
}
finally
{
    Stop-Transcript
}
