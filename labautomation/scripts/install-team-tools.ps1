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

        # Re-registering a running task would stop it and leave its installer processes behind
        if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running') {
            Write-Host "The scheduled task '$taskName' is already running."
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

# Real-time scanning of the ~11,000 SSMS files, the package cache and the native images slows the installation down considerably
# on a small VM. The exclusions are only active during the installation; entries that exist already (SQL Server) are left alone.
$defenderExclusionPaths = @(
    $installDirectory,
    'C:\Program Files\Microsoft SQL Server Management Studio 22',
    'C:\Program Files (x86)\Microsoft Visual Studio\Installer',
    'C:\ProgramData\Microsoft\VisualStudio',
    'C:\Windows\assembly\NativeImages_v4.0.30319_64'
)
$defenderExclusionProcesses = @('vs_SSMS.exe', 'vs_installer.exe', 'vs_installershell.exe', 'vs_setup.exe', 'setup.exe', 'ngen.exe', 'mscorsvw.exe')
$addedExclusionPaths = @()
$addedExclusionProcesses = @()

# Only one worker at a time (e.g. the startup trigger after a restart while another run is still going)
$workerMutex = New-Object System.Threading.Mutex($false, 'Global\InstallTeamTools')
$hasMutex = $false

try {
    $hasMutex = $workerMutex.WaitOne(0)
    $workerWatch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $hasMutex) {
        Write-Host 'Another installation of the team tools is already running.'
        return
    }

    if ((Get-ToolsStatus) -eq 'Succeeded') {
        Write-Host 'The team tools are already installed.'
        return
    }

    try {
        $defenderPreference = Get-MpPreference
        $addedExclusionPaths = @($defenderExclusionPaths | Where-Object { $defenderPreference.ExclusionPath -notcontains $_ })
        $addedExclusionProcesses = @($defenderExclusionProcesses | Where-Object { $defenderPreference.ExclusionProcess -notcontains $_ })

        if ($addedExclusionPaths.Count -gt 0) { Add-MpPreference -ExclusionPath $addedExclusionPaths -ErrorAction Stop }
        if ($addedExclusionProcesses.Count -gt 0) { Add-MpPreference -ExclusionProcess $addedExclusionProcesses -ErrorAction Stop }

        Write-Host 'Microsoft Defender exclusions for the installation added.'
    }
    catch {
        Write-Host "Could not add Microsoft Defender exclusions: $($_.Exception.Message)"
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
    Write-Host "SSMS installation took $([int][math]::Floor($workerWatch.Elapsed.TotalMinutes)) min $($workerWatch.Elapsed.Seconds) s."
    $storageExplorerWatch = [System.Diagnostics.Stopwatch]::StartNew()
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

    Write-Host "Storage Explorer took $([int][math]::Floor($storageExplorerWatch.Elapsed.TotalMinutes)) min $($storageExplorerWatch.Elapsed.Seconds) s."
    Write-Host "Team VM tool installation completed after $([int][math]::Floor($workerWatch.Elapsed.TotalMinutes)) min $($workerWatch.Elapsed.Seconds) s."
}
catch {
    Set-ToolsStatus "Failed: $($_.Exception.Message)"
    throw
}
finally {
    try {
        if ($addedExclusionPaths.Count -gt 0) { Remove-MpPreference -ExclusionPath $addedExclusionPaths -ErrorAction Stop }
        if ($addedExclusionProcesses.Count -gt 0) { Remove-MpPreference -ExclusionProcess $addedExclusionProcesses -ErrorAction Stop }
    }
    catch {
        Write-Host "Could not remove the Microsoft Defender exclusions: $($_.Exception.Message)"
    }

    if ($hasMutex) { $workerMutex.ReleaseMutex() }
    Stop-Transcript
}