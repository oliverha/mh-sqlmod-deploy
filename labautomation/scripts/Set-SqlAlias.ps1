<#
.SYNOPSIS
Creates a 32-bit and a 64-bit SQL Server client alias that points to the local SQL Server instance.

.DESCRIPTION
The alias (default: legacySQL2017) replaces the name of the former central legacy SQL Server VM, so the
lab instructions can connect to the same server name on every lab VM. It is stored in the SQL Server
Native Client "ConnectTo" registry keys of the 64-bit and the 32-bit (WOW6432Node) registry view.
#>

[CmdletBinding()]
param
(
    [string] $AliasName = 'legacySQL2017',

    [string] $ServerInstance = 'localhost',

    [int] $Port = 1433
)

$ErrorActionPreference = 'Stop'

$logPath = 'C:\Windows\Temp\Set-SqlAlias.log'
Start-Transcript -Path $logPath -Append

try
{
    # DBMSSOCN = TCP/IP
    $aliasValue = "DBMSSOCN,$ServerInstance,$Port"

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\MSSQLServer\Client\ConnectTo'
    )

    foreach ($key in $keys)
    {
        if (-not (Test-Path $key))
        {
            New-Item -Path $key -Force | Out-Null
        }

        New-ItemProperty -Path $key -Name $AliasName -Value $aliasValue -PropertyType String -Force | Out-Null
        Write-Host "Alias '$AliasName' -> '$aliasValue' created in $key"
    }
}
finally
{
    Stop-Transcript
}
