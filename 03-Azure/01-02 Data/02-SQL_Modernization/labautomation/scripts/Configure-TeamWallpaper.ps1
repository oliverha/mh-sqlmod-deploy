[CmdletBinding()]
param
(
    [string] $WallpaperUri,
    [int] $TeamNumber = 1
)

$DownloadDirectory = "C:\MicroHack"
$DownloadBaseWallpaperPath = Join-Path $DownloadDirectory "BaseWallpaper.jpg"
$TeamWallpaperPath = Join-Path $DownloadDirectory "Wallpaper.jpg"
[string]$TeamNumberStr = '{0:d2}' -f $TeamNumber


if (-not (Test-Path -LiteralPath "C:\MicroHack"))
{
    New-Item `
        -ItemType Directory `
        -Path "C:\MicroHack" `
        -Force |
        Out-Null
}

if (Test-Path $DownloadBaseWallpaperPath) {
    Remove-Item -LiteralPath $DownloadBaseWallpaperPath -ErrorAction SilentlyContinue -Force
}


try {
    Write-Host "Downloading wallpaper from $WallpaperUri..."
    
    $lastProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $WallpaperUri -OutFile $DownloadBaseWallpaperPath -UseBasicParsing
    $ProgressPreference = $lastProgressPreference

    Write-Host "Setting wallpaper for Team $TeamNumber..."
    Add-Type -AssemblyName System.Drawing

    $img = [System.Drawing.Image]::FromFile($DownloadBaseWallpaperPath)
    $bmp = New-Object System.Drawing.Bitmap($img)

    $graphics = [System.Drawing.Graphics]::FromImage($bmp)

    $font = New-Object System.Drawing.Font(
        "Segoe UI",
        50,
        [System.Drawing.FontStyle]::Bold
    )

    $brush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::White
    )

    $graphics.DrawString(
        "TEAM $TeamNumberStr",
        $font,
        $brush,
        1460,
        1100
    )

    $bmp.Save(
        $TeamWallpaperPath,
        [System.Drawing.Imaging.ImageFormat]::Jpeg
    )

    $graphics.Dispose()
    $bmp.Dispose()
    $img.Dispose()

    New-Item "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue -Force
    Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name Wallpaper -Value "C:\MicroHack\Wallpaper.jpg" -ErrorAction SilentlyContinue
    Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name WallpaperStyle  -Value "10" -ErrorAction SilentlyContinue
}
catch {
    Write-Host "An error occurred while configuring the team wallpaper: $_"
}
