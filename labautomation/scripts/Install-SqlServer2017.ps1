<#
.SYNOPSIS
Installs SQL Server 2017 Developer Edition (database engine) on the local machine.

.DESCRIPTION
Downloads the SQL Server 2017 Developer media (unless -IsoPath is given) and the
latest cumulative update (CU31, required for the Managed Instance link), installs a
default instance with mixed mode authentication and creates a SQL login with sysadmin
rights. Local administrators and SYSTEM are sysadmins, so Windows authentication works
for the lab user.

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

    [string] $BootstrapperUri = 'https://go.microsoft.com/fwlink/?linkid=853016',

    # SQL Server 2017 CU31 (KB5016884), the last cumulative update. Required for the Managed Instance link.
    [string] $CumulativeUpdateUri = 'https://download.microsoft.com/download/C/4/F/C4F908C9-98ED-4E5F-88D5-7D6A5004AEBD/SQLServer2017-KB5016884-x64.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = 'C:\Windows\Temp\Install-SqlServer2017.log'
Start-Transcript -Path $logPath -Append

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

        if ([string]::IsNullOrWhiteSpace($IsoPath))
        {
            $bootstrapper = Join-Path $InstallDirectory 'SQL2017-SSEI-Dev.exe'

            Write-Host 'Downloading SQL Server 2017 Developer installer.'
            Invoke-WebRequest -Uri $BootstrapperUri -OutFile $bootstrapper -UseBasicParsing

            Write-Host 'Downloading SQL Server 2017 Developer media (ISO).'
            $download = Start-Process -FilePath $bootstrapper -Wait -PassThru -ArgumentList @(
                '/ACTION=Download',
                "/MEDIAPATH=`"$InstallDirectory`"",
                '/MEDIATYPE=ISO',
                '/LANGUAGE=en-US',
                '/IACCEPTSQLSERVERLICENSETERMS',
                '/QUIET'
            )

            if ($download.ExitCode -ne 0)
            {
                throw "Download of the SQL Server media failed with exit code $($download.ExitCode)."
            }

            $IsoPath = (Get-ChildItem -Path $InstallDirectory -Filter '*.iso' -File |
                Sort-Object Length -Descending |
                Select-Object -First 1).FullName

            if (-not $IsoPath)
            {
                throw "No ISO file found in $InstallDirectory after the download."
            }
        }

        $updateDirectory = Join-Path $InstallDirectory 'CU'
        New-Item -ItemType Directory -Path $updateDirectory -Force | Out-Null

        $updateFile = Join-Path $updateDirectory ([System.IO.Path]::GetFileName($CumulativeUpdateUri))
        Write-Host "Downloading cumulative update $([System.IO.Path]::GetFileName($CumulativeUpdateUri))."
        Invoke-WebRequest -Uri $CumulativeUpdateUri -OutFile $updateFile -UseBasicParsing

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
                '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators" "NT AUTHORITY\SYSTEM"',
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

            $setup = Start-Process -FilePath "${driveLetter}:\setup.exe" -ArgumentList $setupArguments -Wait -PassThru

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

    for ($attempt = 1; $attempt -le 18; $attempt++)
    {
        $connection = New-Object System.Data.SqlClient.SqlConnection('Data Source=localhost;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True;')

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
