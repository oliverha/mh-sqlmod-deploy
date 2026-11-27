<#
.SYNOPSIS
Turns off the first-run experience and the other prompts of Microsoft Edge on first start.

.DESCRIPTION
Sets Edge policies (HKLM:\SOFTWARE\Policies\Microsoft\Edge): no first-run experience and welcome page, no browser
sign-in, sync or profile prompts, no import prompt, no "make Edge your default browser" prompt, no promotions.
Web sign-ins (e.g. to the Azure portal) are not affected. Run as Administrator.
#>
[CmdletBinding()]
param(
    [string]$PolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
)

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\Configure-EdgeFirstRun.log'
Start-Transcript -Path $logPath -Append

try
{
    if (-not (Test-Path $PolicyPath))
    {
        New-Item -Path $PolicyPath -Force | Out-Null
    }

    $policies = [ordered]@{
        HideFirstRunExperience        = 1  # no first-run experience
        EdgeWelcomePageEnabled        = 0  # no welcome page
        BrowserSignin                 = 0  # no browser sign-in prompt
        SyncDisabled                  = 1  # no sync prompt
        ImplicitSignInEnabled         = 0  # no automatic profile sign-in
        ImportOnEachLaunch            = 0  # no import of browser data
        DefaultBrowserSettingEnabled  = 0  # no "make Edge your default browser" prompt
        ShowRecommendationsEnabled    = 0  # no recommendations
        PromotionalTabsEnabled        = 0  # no promotional tabs
    }

    foreach ($name in $policies.Keys)
    {
        New-ItemProperty -Path $PolicyPath -Name $name -Value $policies[$name] -PropertyType DWord -Force | Out-Null
        Write-Host "Edge policy $name = $($policies[$name])"
    }

    Write-Host 'Edge first-run prompts disabled.'
}
finally
{
    Stop-Transcript
}
