<#
.SYNOPSIS
Installs the team tools (SQL Server Management Studio 22, Azure Storage Explorer) in the background.

.DESCRIPTION
The installation takes about 15 minutes, so it does not run inside the custom script extension (which would hold up
the deployment). Called without parameters, the script only registers a scheduled task (SYSTEM) that runs this script
with -Worker, starts it and returns within seconds. The task also runs at startup until the installation succeeded.
The worker installs SSMS, creates the "SSMS 22" desktop shortcut, installs Storage Explorer (optional) and records the
result in HKLM:\SOFTWARE\SQLMicroHack (TeamToolsStatus = Running, Succeeded or Failed: <message>).
The worker log is C:\Windows\Temp\install-team-tools-worker.log.
#>
[CmdletBinding()]
param(
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installDirectory = 'C:\Install'
$workerScript = Join-Path $installDirectory 'install-team-tools.ps1'
$taskName = 'InstallTeamTools'
$statusKey = 'HKLM:\SOFTWARE\SQLMicroHack'

function Get-ToolsStatus {
    (Get-ItemProperty -Path $statusKey -Name 'TeamToolsStatus' -ErrorAction SilentlyContinue).TeamToolsStatus
}

function Set-ToolsStatus {
    param([string]$Value)
    New-Item -Path $statusKey -Force | Out-Null
    New-ItemProperty -Path $statusKey -Name 'TeamToolsStatus' -Value $Value -PropertyType String -Force | Out-Null
}

if (-not $Worker) {
    Start-Transcript -Path 'C:\Windows\Temp\install-team-tools.log' -Append

    try {
        if ((Get-ToolsStatus) -eq 'Succeeded') {
            Write-Host 'The team tools are already installed.'
            return
        }

        New-Item -Path $installDirectory -ItemType Directory -Force | Out-Null

        if ($PSCommandPath -ne $workerScript) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $workerScript -Force
        }

        Set-ToolsStatus 'Running'

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -Worker"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 3) -StartWhenAvailable

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings `
            -Trigger (New-ScheduledTaskTrigger -AtStartup) | Out-Null
        Start-ScheduledTask -TaskName $taskName

        Write-Host "Started the scheduled task '$taskName' that installs the team tools in the background."
    }
    finally {
        Stop-Transcript
    }

    return
}

Start-Transcript -Path 'C:\Windows\Temp\install-team-tools-worker.log' -Append

try {
    if ((Get-ToolsStatus) -eq 'Succeeded') {
        Write-Host 'The team tools are already installed.'
        return
    }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12

    New-Item `
        -Path $installDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    $ssmsInstaller =
        Join-Path $installDirectory 'vs_SSMS.exe'

    # A failed attempt (e.g. a network problem during the package download) is repeated once
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Host "Downloading SQL Server Management Studio 22 (attempt $attempt/2)."

        Invoke-WebRequest `
            -Uri 'https://aka.ms/ssms/22/release/vs_SSMS.exe' `
            -OutFile $ssmsInstaller `
            -UseBasicParsing

        Write-Host 'Installing SQL Server Management Studio 22.'

        $ssmsProcess = Start-Process `
            -FilePath $ssmsInstaller `
            -ArgumentList '--add Microsoft.SqlServer.Workload.SSMS.AI --add Microsoft.SqlServer.Workload.SSMS.HybridAndMigration --includeRecommended --quiet --wait --norestart' `
            -Wait `
            -PassThru

        if ($ssmsProcess.ExitCode -in 0, 3010) { break }

        if ($attempt -eq 2) {
            throw "SSMS installation failed with exit code $($ssmsProcess.ExitCode)."
        }

        Write-Warning "SSMS installation failed with exit code $($ssmsProcess.ExitCode). Trying again."
    }

    $ssmsExe = 'C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\SSMS.exe'

    if (Test-Path -LiteralPath $ssmsExe) {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:Public\Desktop\SSMS 22.lnk")
        $link.TargetPath = $ssmsExe
        $link.IconLocation = "$ssmsExe,0"
        $link.Save()
    }

    # Storage Explorer is optional: a failure must not fail the whole script.
    try {
        $storageExplorerInstaller = Join-Path $installDirectory 'StorageExplorer-windows-x64.exe'

        Write-Host 'Downloading Azure Storage Explorer.'

        Invoke-WebRequest `
            -Uri 'https://go.microsoft.com/fwlink/?LinkId=708343&clcid=0x409' `
            -OutFile $storageExplorerInstaller `
            -UseBasicParsing

        Write-Host 'Installing Azure Storage Explorer.'

        $storageExplorerProcess = Start-Process `
            -FilePath $storageExplorerInstaller `
            -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS' `
            -Wait `
            -PassThru

        if ($storageExplorerProcess.ExitCode -notin 0, 3010) {
            throw "Storage Explorer installation failed with exit code $($storageExplorerProcess.ExitCode)."
        }
    }
    catch {
        Write-Warning "Azure Storage Explorer could not be installed and is skipped: $($_.Exception.Message)"
    }

    New-ItemProperty `
        -Path $statusKey `
        -Name 'TeamToolsInstalled' `
        -Value (Get-Date).ToString('o') `
        -PropertyType String `
        -Force |
        Out-Null

    Set-ToolsStatus 'Succeeded'

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host 'Team VM tool installation completed.'
}
catch {
    Set-ToolsStatus "Failed: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript
}