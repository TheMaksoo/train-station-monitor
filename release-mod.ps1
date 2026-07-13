param(
  [string]$Version,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-PortalZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$DestinationZip
  )

  if (Test-Path $DestinationZip) {
    Remove-Item $DestinationZip -Force
  }

  $parentDir = [System.IO.Path]::GetFullPath((Split-Path $SourceDir -Parent))
  $basePath = $parentDir
  if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $basePath += [System.IO.Path]::DirectorySeparatorChar
  }
  $zip = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    Get-ChildItem $SourceDir -Recurse -File | ForEach-Object {
      $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
      $relative = ($fullPath.Substring($basePath.Length) -replace '^[\\/]+', '') -replace '\\', '/'
      $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $_.LastWriteTime

      $entryStream = $entry.Open()
      try {
        $fileStream = [System.IO.File]::OpenRead($_.FullName)
        try {
          $fileStream.CopyTo($entryStream)
        } finally {
          $fileStream.Dispose()
        }
      } finally {
        $entryStream.Dispose()
      }
    }
  } finally {
    $zip.Dispose()
  }
}

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$infoPath = Join-Path $src 'info.json'
$info = Get-Content $infoPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = $info.version
}

$name = $info.name
$folderName = "${name}_$Version"
$tmp = Join-Path $env:TEMP $folderName
$mods = Join-Path $env:APPDATA 'Factorio\mods'
$zipOut = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path $mods ("$folderName.zip")
} else {
  $resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
  if ((Test-Path $resolvedOutput) -and (Get-Item $resolvedOutput).PSIsContainer) {
    Join-Path $resolvedOutput ("$folderName.zip")
  } else {
    $resolvedOutput
  }
}

if (Test-Path $tmp) {
  Remove-Item $tmp -Recurse -Force
}
New-Item -ItemType Directory -Path $tmp | Out-Null

$exclude = @('.git', '.gitignore', '.github', 'web')
$forbiddenExtensions = @('.exe', '.bat', '.ps1', '.sh', '.py')
$zipFileName = Split-Path $zipOut -Leaf
Get-ChildItem $src | Where-Object {
  $_.Name -notin $exclude -and
  $_.Name -ne $zipFileName -and
  $_.Extension -notin $forbiddenExtensions
} | ForEach-Object {
  Copy-Item $_.FullName $tmp -Recurse
}

Get-ChildItem $mods -Filter "${name}_*.zip" | Where-Object { $_.Name -ne "$folderName.zip" } | ForEach-Object {
  try {
    Remove-Item $_.FullName -Force -ErrorAction Stop
  } catch {
    Write-Warning "Could not remove stale archive $($_.Name): $($_.Exception.Message)"
  }
}

New-PortalZip -SourceDir $tmp -DestinationZip $zipOut
Remove-Item $tmp -Recurse -Force

Write-Host "Packed $zipOut"
