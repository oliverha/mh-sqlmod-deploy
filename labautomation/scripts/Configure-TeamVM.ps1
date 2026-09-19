# Disable Privacy Experience / First Sign-In Experience
# Run as Administrator

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\Configure-TeamVM.log'
Start-Transcript -Path $logPath -Append

$policies = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
)

foreach ($path in $policies)
{
    if (-not (Test-Path $path))
    {
        New-Item -Path $path -Force | Out-Null
    }
}

# Skip privacy experience
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" `
    -Name "DisablePrivacyExperience" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

# Disable consumer experiences
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" `
    -Name "DisableWindowsConsumerFeatures" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

# Required diagnostics only
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name "AllowTelemetry" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

# Skip user privacy consent prompts
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" `
    -Name "PrivacyConsentStatus" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

# Disable "Let's finish setting up your device"
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" `
    -Name "DisableSoftLanding" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

# Disable welcome experience
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" `
    -Name "DisableWindowsSpotlightWindowsWelcomeExperience" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

$cdmPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"

New-ItemProperty -Path $cdmPath `
    -Name "DisableTailoredExperiencesWithDiagnosticData" `
    -Value 1 `
    -PropertyType DWord `
    -Force

New-ItemProperty -Path $cdmPath `
    -Name "DisableThirdPartySuggestions" `
    -Value 1 `
    -PropertyType DWord `
    -Force

New-ItemProperty -Path $cdmPath `
    -Name "DisableConsumerAccountStateContent" `
    -Value 1 `
    -PropertyType DWord `
    -Force

Write-Output "Privacy Experience disabled."

Stop-Transcript