$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$App = Join-Path $Root 'apps\flutter'
$Dist = Join-Path $Root 'dist\windows'
$Stage = Join-Path $Dist 'stage'
$Version = if ($env:VERSION) { $env:VERSION } else { '0.1.0' }

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required"
    }
}

Require-Command flutter
Require-Command cargo
Require-Command cl.exe

if (-not (Test-Path (Join-Path $App 'windows'))) {
    Push-Location $App
    try { flutter create --platforms=windows . } finally { Pop-Location }
}

Push-Location $App
try {
    flutter pub get
    flutter build windows --release
} finally { Pop-Location }

Push-Location $Root
try {
    cargo build -p milmit-vpn-flutter-ffi --release
    cargo build --manifest-path native\windows\service\Cargo.toml --release
    & cl.exe /nologo /O2 /W4 /DUNICODE /D_UNICODE native\windows\wfp-helper\wfp_helper.c /Fe:native\windows\wfp-helper\wfp-helper.exe /link Fwpuclnt.lib Rpcrt4.lib Ws2_32.lib
    if ($LASTEXITCODE -ne 0) { throw 'WFP helper compilation failed' }
} finally { Pop-Location }

$Bundle = Join-Path $App 'build\windows\x64\runner\Release'
if (-not (Test-Path $Bundle)) { throw "Flutter Windows release bundle not found: $Bundle" }

Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item (Join-Path $Bundle '*') $Stage -Recurse -Force
Copy-Item (Join-Path $Root 'target\release\milmit_vpn_flutter_ffi.dll') $Stage -Force
Copy-Item (Join-Path $Root 'native\windows\wfp-helper\wfp-helper.exe') $Stage -Force

$ServiceExe = Join-Path $Root 'native\windows\service\target\release\milmit-vpn-windows-service.exe'
if (-not (Test-Path $ServiceExe)) {
    $ServiceExe = Join-Path $Root 'target\release\milmit-vpn-windows-service.exe'
}
if (-not (Test-Path $ServiceExe)) { throw 'Windows service executable was not produced' }

$PortableZip = Join-Path $Dist "MilMit-VPN-$Version-windows-x64.zip"
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $PortableZip -Force

$Heat = Get-Command heat.exe -ErrorAction SilentlyContinue
$Candle = Get-Command candle.exe -ErrorAction SilentlyContinue
$Light = Get-Command light.exe -ErrorAction SilentlyContinue
if (-not ($Heat -and $Candle -and $Light)) {
    Write-Warning 'WiX Toolset 3 (heat/candle/light) is not installed. Portable ZIP created; MSI skipped.'
    exit 0
}

$Harvest = Join-Path $Dist 'FlutterAppFiles.wxs'
& $Heat.Path dir $Stage -cg FlutterAppFiles -dr INSTALLFOLDER -srd -sreg -gg -var var.SourceDir -out $Harvest

$MainWxs = Join-Path $Root 'packaging\windows\MilMitVPN.wxs'
$HarvestObj = Join-Path $Dist 'FlutterAppFiles.wixobj'
$MainObj = Join-Path $Dist 'MilMitVPN.wixobj'
& $Candle.Path -arch x64 -dSourceDir="$Stage" -dServiceExe="$ServiceExe" -dProductVersion="$Version" -out $HarvestObj $Harvest
& $Candle.Path -arch x64 -dSourceDir="$Stage" -dServiceExe="$ServiceExe" -dProductVersion="$Version" -out $MainObj $MainWxs

$Msi = Join-Path $Dist "MilMit-VPN-$Version-x64.msi"
& $Light.Path -ext WixUIExtension -out $Msi $MainObj $HarvestObj

Get-FileHash $PortableZip -Algorithm SHA256 | Format-List | Out-File (Join-Path $Dist 'SHA256SUMS.txt')
Get-FileHash $Msi -Algorithm SHA256 | Format-List | Out-File (Join-Path $Dist 'SHA256SUMS.txt') -Append
Write-Host "Created: $PortableZip"
Write-Host "Created: $Msi"
