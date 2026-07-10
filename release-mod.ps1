param(
  [string]$Version
)

$ErrorActionPreference = 'Stop'

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
$zipOut = Join-Path $mods ("$folderName.zip")

if (Test-Path $tmp) {
  Remove-Item $tmp -Recurse -Force
}
New-Item -ItemType Directory -Path $tmp | Out-Null

$exclude = @('.git', '.gitignore', '.github', 'web')
Get-ChildItem $src | Where-Object { $_.Name -notin $exclude } | ForEach-Object {
  Copy-Item $_.FullName $tmp -Recurse
}

Get-ChildItem $mods -Filter "${name}_*.zip" | Where-Object { $_.Name -ne "$folderName.zip" } | ForEach-Object {
  try {
    Remove-Item $_.FullName -Force -ErrorAction Stop
  } catch {
    Write-Warning "Could not remove stale archive $($_.Name): $($_.Exception.Message)"
  }
}

if (Test-Path $zipOut) {
  Remove-Item $zipOut -Force
}

Compress-Archive -Path $tmp -DestinationPath $zipOut -Force
Remove-Item $tmp -Recurse -Force

Write-Host "Packed $zipOut"
