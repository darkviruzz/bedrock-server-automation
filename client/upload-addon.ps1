[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Slug,
    [Parameter(Position=1)][string]$File,
    [switch]$Reset
)
$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $HOME '.mc-bedrock-uploader.json'

if ($Reset) {
    Remove-Item $ConfigFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Uploader-Konfiguration gelöscht.'
    exit 0
}

$ServerUrl = $env:MC_BEDROCK_URL
$UploadToken = $env:MC_BEDROCK_TOKEN
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if (-not $ServerUrl) { $ServerUrl = $cfg.serverUrl }
        if (-not $UploadToken -and $cfg.tokenProtected) {
            $sec = ConvertTo-SecureString $cfg.tokenProtected
            $cred = [pscredential]::new('token',$sec)
            $UploadToken = $cred.GetNetworkCredential().Password
        }
    } catch {
        Write-Warning "Gespeicherte Konfiguration konnte nicht gelesen werden: $_"
    }
}
if (-not $ServerUrl) { $ServerUrl = Read-Host 'Minecraft Upload-URL (z.B. http://192.168.20.50:19134)' }
$ServerUrl = $ServerUrl.TrimEnd('/')
if ($ServerUrl -notmatch '^https?://') { throw "Ungültige URL: $ServerUrl" }
if (-not $UploadToken) {
    $sec = Read-Host 'Upload-Token' -AsSecureString
    $cred = [pscredential]::new('token',$sec)
    $UploadToken = $cred.GetNetworkCredential().Password
}
if (-not $UploadToken) { throw 'Upload-Token fehlt.' }

try {
    $protected = ConvertFrom-SecureString (ConvertTo-SecureString $UploadToken -AsPlainText -Force)
    @{serverUrl=$ServerUrl; tokenProtected=$protected} | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigFile
} catch {
    Write-Warning "Konfiguration konnte nicht gespeichert werden: $_"
}

$items = @(
    @{slug='bedrock-essentials'; name='Bedrock Essentials+'},
    @{slug='advanced-gravestone'; name='Advanced Gravestone'},
    @{slug='lilium-dynamic-light'; name='Lilium Dynamic Light'},
    @{slug='epic-machinery'; name='Epic Machinery'},
    @{slug='better-on-bedrock'; name='Better on Bedrock'}
)

if ($Slug -and (Test-Path -LiteralPath $Slug) -and -not $File) { $File=$Slug; $Slug=$null }
if (-not $Slug) {
    Write-Host 'Add-on auswählen:'
    for ($i=0; $i -lt $items.Count; $i++) { Write-Host ("  {0}) {1} [{2}]" -f ($i+1),$items[$i].name,$items[$i].slug) }
    $n = [int](Read-Host 'Nummer')
    if ($n -lt 1 -or $n -gt $items.Count) { throw 'Ungültige Auswahl.' }
    $Slug=$items[$n-1].slug
}
if (-not ($items | Where-Object { $_.slug -eq $Slug })) { throw "Unbekannter Slug: $Slug" }

if (-not $File) {
    $downloads = Join-Path $HOME 'Downloads'
    $candidate = Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.mcaddon','.mcpack','.zip' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) {
        $ans = Read-Host "Neueste Add-on-Datei verwenden: $($candidate.FullName) ? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^(y|yes|j|ja)$') { $File=$candidate.FullName }
    }
    if (-not $File) { $File = Read-Host 'Pfad zur heruntergeladenen .mcaddon/.mcpack/.zip-Datei' }
}
$File = (Resolve-Path -LiteralPath $File).Path

Write-Host -NoNewline 'Prüfe Upload-Dienst … '
Invoke-RestMethod -Uri "$ServerUrl/health" -Method Get -TimeoutSec 5 | Out-Null
Write-Host 'OK'
Write-Host "Lade $([IO.Path]::GetFileName($File)) als $Slug hoch. Der CT übernimmt Backup, Validierung, Installation und Test."
$headers = @{ Authorization = "Bearer $UploadToken" }
$result = Invoke-RestMethod -Uri "$ServerUrl/upload/$Slug" -Method Put -Headers $headers -InFile $File -ContentType 'application/octet-stream' -TimeoutSec 360
$result | ConvertTo-Json -Depth 5
