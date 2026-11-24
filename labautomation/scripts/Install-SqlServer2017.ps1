<#
.SYNOPSIS
Installs SQL Server 2017 Developer Edition (database engine) on the local machine.

.DESCRIPTION
Downloads the SQL Server 2017 Developer ISO (unless -IsoPath is given) and the
latest cumulative update (CU31 Azure Connect Pack, required for the Managed Instance link), installs a
default instance with mixed mode authentication and creates a SQL login with sysadmin
rights through the 'sa' account. Local administrators are sysadmins, so Windows authentication
works for the lab user. The setup account (SYSTEM in the custom script extension) is only a
temporary sysadmin during the setup, so it must not be used to connect afterwards.

The script is idempotent: it exits early if a SQL Server 2017 default instance exists.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [string] $sqlusername,

    [Parameter(Mandatory = $true)]
    [string] $sqlpassword,

    [string] $InstallDirectory = 'C:\Install\SQL2017',

    # Optional local SQL Server 2017 Developer ISO. Skips the download of the media.
    [string] $IsoPath,

    [string] $IsoUri = 'https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLServer2017-x64-ENU-Dev.iso',

    # SQL Server 2017 CU31 Azure Connect Pack (KB5050533). Required for the Managed Instance link; the plain CU31 (KB5016884) does not work with it.
    [string] $CumulativeUpdateUri = 'https://download.microsoft.com/download/c/4/f/c4f908c9-98ed-4e5f-88d5-7d6a5004aebd/SQLServer2017-KB5050533-x64.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = 'C:\Windows\Temp\Install-SqlServer2017.log'
Start-Transcript -Path $logPath -Append

# Prefix every message with a time stamp so the log shows which step takes how long
function Write-Host {
    param([Parameter(ValueFromRemainingArguments = $true)] $Object)
    Microsoft.PowerShell.Utility\Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), ($Object -join ' '))
}

try
{
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12

    if ($sqlpassword.Contains('"'))
    {
        throw 'The SQL password must not contain double quotes.'
    }

    $instanceNames = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances

    if ($instanceNames -contains 'MSSQLSERVER')
    {
        Write-Host 'SQL Server default instance is already installed. Skipping installation.'
    }
    else
    {
        New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

        # Real-time scanning of the 1.5 GB ISO, the CU and the setup files slows the installation down considerably on a small VM
        try
        {
            Add-MpPreference -ExclusionPath $InstallDirectory, 'C:\Program Files\Microsoft SQL Server', 'C:\SQLBackups' -ExclusionProcess 'sqlservr.exe', 'setup.exe' -ErrorAction Stop
            Write-Host 'Microsoft Defender exclusions for the SQL Server installation added.'
        }
        catch
        {
            Write-Host "Could not add Microsoft Defender exclusions: $($_.Exception.Message)"
        }

        $updateDirectory = Join-Path $InstallDirectory 'CU'
        New-Item -ItemType Directory -Path $updateDirectory -Force | Out-Null

        $updateFile = Join-Path $updateDirectory ([System.IO.Path]::GetFileName($CumulativeUpdateUri))

        # The media and the cumulative update are downloaded in parallel
        $downloads = @(
            @{ Name = 'cumulative update'; Uri = $CumulativeUpdateUri; Path = $updateFile }
        )

        if ([string]::IsNullOrWhiteSpace($IsoPath))
        {
            $IsoPath = Join-Path $InstallDirectory ([System.IO.Path]::GetFileName($IsoUri))
            $downloads += @{ Name = 'SQL Server media'; Uri = $IsoUri; Path = $IsoPath }
        }

        foreach ($download in $downloads)
        {
            Write-Host "Downloading $($download.Name) from $($download.Uri)."
            $download.ErrorLog = "$($download.Path).err"
            $download.Process = Start-Process -FilePath 'curl.exe' -WindowStyle Hidden -PassThru `
                -RedirectStandardError $download.ErrorLog `
                -ArgumentList @('--location', '--fail', '--silent', '--show-error', '--retry', '5', '--retry-delay', '10', '--output', "`"$($download.Path)`"", "`"$($download.Uri)`"")
            $null = $download.Process.Handle   # keeps the handle so that ExitCode is available
        }

        foreach ($download in $downloads)
        {
            $download.Process.WaitForExit()

            if ($download.Process.ExitCode -ne 0 -or -not (Test-Path $download.Path))
            {
                throw "Download of the $($download.Name) failed (curl exit code $($download.Process.ExitCode)): $(Get-Content -Path $download.ErrorLog -Raw -ErrorAction SilentlyContinue)"
            }

            Write-Host "Downloaded the $($download.Name)."
        }

        Write-Host "Mounting $IsoPath."
        $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $driveLetter = ($image | Get-Volume).DriveLetter

        try
        {
            Write-Host 'Installing SQL Server 2017 Developer Edition (including the cumulative update).'

            $setupArguments = @(
                '/Q',
                '/ACTION=Install',
                '/IACCEPTSQLSERVERLICENSETERMS',
                '/FEATURES=SQLENGINE',
                '/INSTANCENAME=MSSQLSERVER',
                '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
                '/SECURITYMODE=SQL',
                "/SAPWD=`"$sqlpassword`"",
                '/SQLSVCACCOUNT="NT Service\MSSQLSERVER"',
                '/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"',
                '/SQLSVCSTARTUPTYPE=Automatic',
                '/AGTSVCSTARTUPTYPE=Automatic',
                '/SQLSVCINSTANTFILEINIT=True',
                '/TCPENABLED=1',
                '/NPENABLED=0',
                '/UPDATEENABLED=True',
                "/UPDATESOURCE=`"$updateDirectory`""
            )

            $progressLog = 'C:\Windows\Temp\SqlServer2017-setup-progress.log'
            $setup = Start-Process -FilePath "${driveLetter}:\setup.exe" -ArgumentList ($setupArguments + '/INDICATEPROGRESS') `
                -RedirectStandardOutput $progressLog -PassThru -WindowStyle Hidden
            $null = $setup.Handle   # keeps the handle so that ExitCode is available

            # No -Wait: it would also wait for child processes. A hanging setup is stopped after 60 minutes.
            # Every minute the last progress line of the setup is written to the log.
            $deadline = (Get-Date).AddMinutes(60)
            while (-not $setup.WaitForExit(60000))
            {
                $lastProgress = Get-Content -Path $progressLog -Tail 1 -ErrorAction SilentlyContinue
                Write-Host "Setup is running (pid $($setup.Id)). Last progress: $lastProgress"

                if ((Get-Date) -gt $deadline)
                {
                    Stop-Process -Id $setup.Id -Force
                    throw "SQL Server setup did not finish within 60 minutes and was stopped. See $progressLog and C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log\Summary.txt."
                }
            }

            Write-Host "Setup finished with exit code $($setup.ExitCode)."

            if ($setup.ExitCode -notin 0, 3010)
            {
                throw "SQL Server setup failed with exit code $($setup.ExitCode). See C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log\Summary.txt."
            }
        }
        finally
        {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }

        Remove-Item -Path $InstallDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Waiting for the SQL Server service...'
    Start-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue

    $loginQuery = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($sqlusername.Replace("'", "''"))')
    CREATE LOGIN [$($sqlusername.Replace(']', ']]'))] WITH PASSWORD = N'$($sqlpassword.Replace("'", "''"))', CHECK_POLICY = OFF;
ALTER SERVER ROLE [sysadmin] ADD MEMBER [$($sqlusername.Replace(']', ']]'))];
"@

    # The login is created with the 'sa' account (SQL authentication is enabled by the setup), independent of the Windows account running this script
    $saPassword = ConvertTo-SecureString -String $sqlpassword -AsPlainText -Force
    $saPassword.MakeReadOnly()

    for ($attempt = 1; $attempt -le 18; $attempt++)
    {
        $connection = New-Object System.Data.SqlClient.SqlConnection('Data Source=localhost;Initial Catalog=master;TrustServerCertificate=True;Connect Timeout=10;')
        $connection.Credential = New-Object System.Data.SqlClient.SqlCredential('sa', $saPassword)
        try
        {
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = $loginQuery
            [void]$command.ExecuteNonQuery()
            Write-Host "SQL login '$sqlusername' is configured as sysadmin."
            break
        }
        catch
        {
            if ($attempt -eq 18)
            {
                throw
            }

            Write-Host "SQL Server is not ready yet ($($_.Exception.Message)). Retrying in 10 seconds..."
            Start-Sleep -Seconds 10
        }
        finally
        {
            $connection.Dispose()
        }
    }

    Write-Host 'SQL Server 2017 Developer Edition is ready.'
}
finally
{
    Stop-Transcript
}
