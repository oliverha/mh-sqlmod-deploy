param(
    [Parameter(Mandatory)]
    [string] $sqlusername,
    [Parameter(Mandatory)]
    [string] $sqlpassword,
    [string]$ServerInstance = 'localhost'
)

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\Configure-LocalSQL.log'
Start-Transcript -Path $logPath -Append

function Invoke-SqlScript {
    param([string]$Script)

    $securePassword = ConvertTo-SecureString -String $sqlpassword -AsPlainText -Force
    $securePassword.MakeReadOnly()

    $connection = New-Object System.Data.SqlClient.SqlConnection("Data Source=$ServerInstance;Initial Catalog=master;TrustServerCertificate=True;")
    $connection.Credential = New-Object System.Data.SqlClient.SqlCredential($sqlusername, $securePassword)

    try {
        $connection.Open()

        # GO is a client-side batch separator, so the script is split into batches on a single connection
        foreach ($batch in [regex]::Split($Script, '(?im)^\s*GO\s*$')) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }

            $command = $connection.CreateCommand()
            $command.CommandText = $batch
            $command.CommandTimeout = 0
            [void]$command.ExecuteNonQuery()
        }
    }
    finally {
        $connection.Dispose()
    }
}

Write-Host 'Configuring local SQL Server instance...'

$ConfigureSql = @"
USE [master];
GO
/* ============================================================
   SQL Server configuration for SSMS Migration Assessments

   - MAXDOP = 1
   - Optimize for Ad Hoc Workloads = ON
   - Network Packet Size = 8000
   - Max Server Memory = 4 GB
   ============================================================ */
DECLARE @MaxServerMemoryMB bigint = 4096;
/* Enable advanced options */
EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
/* MAXDOP = 1 */
EXEC sys.sp_configure 'max degree of parallelism', 1;
/* Optimize for Ad Hoc Workloads */
EXEC sys.sp_configure 'optimize for ad hoc workloads', 1;
/* Network Packet Size = 8000 bytes */
EXEC sys.sp_configure 'network packet size (B)', 8000;
/* Max Server Memory */
EXEC sys.sp_configure
    'max server memory (MB)',
    @MaxServerMemoryMB;
RECONFIGURE;
GO
USE master
GO
EXEC sp_configure 'CLR Enabled', 1
/* SQL Server 2017 enables CLR strict security by default. It is turned off to keep the behavior of the former SQL Server 2016 legacy server, because the lab databases contain unsigned UNSAFE assemblies. */
EXEC sp_configure 'clr strict security', 0
RECONFIGURE WITH OVERRIDE
GO
USE [master]
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE symmetric_key_id = 101)
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$($sqlpassword.Replace("'", "''"))'
GO
"@

try {
    Invoke-SqlScript -Script $ConfigureSql
}
catch {
    $ErrorString = $_ | format-list -force | Out-String
    Write-Error "ERR: $ErrorString"
}

try {
    # Always On availability groups without a Windows Failover Cluster (CLUSTER_TYPE = NONE) are supported from SQL Server 2017 on
    # and are the base for the Managed Instance link. The registry value is the one the SQL Server Configuration Manager sets.
    Write-Host 'Enabling the Always On availability groups feature...' -ForegroundColor Green

    $instanceId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
    $hadrKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\HADR"

    if (-not (Test-Path $hadrKey)) {
        New-Item -Path $hadrKey -Force | Out-Null
    }
    Set-ItemProperty -Path $hadrKey -Name 'HADR_Enabled' -Value 1 -Type DWord

    Restart-Service -Name 'MSSQLSERVER' -Force
    Start-Service -Name 'SQLSERVERAGENT' -ErrorAction SilentlyContinue

    $verifyScript = "IF CONVERT(int, SERVERPROPERTY('IsHadrEnabled')) <> 1 THROW 50001, 'Always On availability groups are not enabled.', 1;"
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            Invoke-SqlScript -Script $verifyScript
            Write-Host 'Always On availability groups are enabled.'
            break
        }
        catch {
            if ($attempt -eq 12) { throw }
            Start-Sleep -Seconds 10
        }
    }
}
catch {
    Write-Host 'Error enabling Always On availability groups.'
    $ErrorString = $_ | format-list -force | Out-String
    Write-Error "ERR: $ErrorString"
}

Stop-Transcript
