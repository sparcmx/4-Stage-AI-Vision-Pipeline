[CmdletBinding()]
param(
  [string]$ComposeFile    = ".\docker-compose.yml",
  [string]$TrainerDir     = ".\yolo-trainer",
  [string]$MinioEndpoint  = "http://localhost:9000",
  [string]$MlflowEndpoint = "http://localhost:5000",
  [string]$AccessKey      = "minioadmin",
  [string]$SecretKey      = "minioadmin",
  [int]$WaitTimeoutSec    = 120
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
function Fail($msg) { Write-Error $msg; exit 1 }

# --- Self-unblock ---
try { Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue } catch {}

# --- Reinvoke in permissive host if policy blocks ---
$pol = Get-ExecutionPolicy -List
$blocked = $false
if ($pol.MachinePolicy -and $pol.MachinePolicy -ne 'Undefined') { $blocked = $true }
elseif ($pol.UserPolicy -and $pol.UserPolicy -ne 'Undefined')   { $blocked = $true }
elseif ($pol.Process -in 'Restricted','AllSigned')              { $blocked = $true }
elseif ($pol.CurrentUser -in 'Restricted','AllSigned')          { $blocked = $true }
elseif ($pol.LocalMachine -in 'Restricted','AllSigned')         { $blocked = $true }

if ($blocked -and -not $env:__PRIME_REINVOKED) {
  $env:__PRIME_REINVOKED = '1'
  $namedArgs = @(
    '-ComposeFile',    $ComposeFile,
    '-TrainerDir',     $TrainerDir,
    '-MinioEndpoint',  $MinioEndpoint,
    '-MlflowEndpoint', $MlflowEndpoint,
    '-AccessKey',      $AccessKey,
    '-SecretKey',      $SecretKey,
    '-WaitTimeoutSec', $WaitTimeoutSec
  )
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    & $pwsh.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @namedArgs
  } else {
    & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @namedArgs
  }
  exit $LASTEXITCODE
}

# --- Helpers ---
function Test-Exe([string]$name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Fail "$name not found in PATH." }
}
function Require-DockerLinux() {
  Test-Exe docker
  Write-Host ">> Checking Docker Desktop..."
  $os = docker info --format '{{.OSType}}' 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop not running." }
  if ($os -ne 'linux') { Fail "Docker must be in Linux containers mode (current: $os)." }
}
function Wait-HttpOk($url, $timeoutSec) {
  $start = Get-Date
  Write-Host ">> Waiting for $url (timeout ${timeoutSec}s)..."
  do {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return }
    } catch { Start-Sleep -Seconds 2 }
  } while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds($timeoutSec))
  Fail "Timeout waiting for $url"
}
function Run-IfExists($path, $splat) {
  if (Test-Path $path) { Write-Host ">> $([IO.Path]::GetFileName($path)) $($splat.Keys -join ' ')"; & $path @splat }
  else { Write-Host ">> Skipping $(Split-Path $path -Leaf) (not found)" }
}

# --- Decide compose flavor (key fix) ---
$ComposeBase = $null
try { docker compose version *> $null; $ComposeBase = @("docker","compose") } catch {}
if (-not $ComposeBase) {
  if (Get-Command docker-compose -ErrorAction SilentlyContinue) { $ComposeBase = @("docker-compose") }
  else { Fail "Neither 'docker compose' nor 'docker-compose' found in PATH." }
}
function Invoke-Compose { 
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

    # --- Ensure MinIO creds are exported for docker-compose ---
    if (-not $env:MINIO_ROOT_USER -or -not $env:MINIO_ROOT_PASSWORD) {
        # tie to script parameters so they can be overridden
        $env:MINIO_ROOT_USER = $AccessKey
        $env:MINIO_ROOT_PASSWORD = $SecretKey
    }

    if ($ComposeBase.Count -eq 2) { & $ComposeBase[0] $ComposeBase[1] @Args }
    else { & $ComposeBase[0] @Args }
}

# --- Compose service discovery ---
function Get-ComposeServices([string]$file) {
  $raw = Invoke-Compose -f $file config --services 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "Failed to parse compose file: $file" }
  $raw | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# --- Preflight ---
Write-Host ">> prime.ps1 starting..."
Require-DockerLinux
if (!(Test-Path $ComposeFile)) { Fail "Compose file not found: $ComposeFile" }
if (!(Test-Path (Join-Path $TrainerDir "Dockerfile"))) { Fail "Dockerfile not found in $TrainerDir" }

# --- Build trainer ---
Write-Host ">> Building image mlops-pipeline-yolo-trainer ..."
docker build -t mlops-pipeline-yolo-trainer -f (Join-Path $TrainerDir "Dockerfile") $TrainerDir

# --- Work out what to start (non-breaking) ---
$allServices = @( Get-ComposeServices $ComposeFile )
$wanted = @(
  'minio','mlflow',                 # existing
  'cvat_db','cvat_redis','cvat_server','cvat_ui','cvat_worker',  # CVAT
  'triton',                         # Triton
  'evidently'                       # Evidently
)
$toStart = @()
foreach ($svc in $wanted) {
  if ($allServices -contains $svc) { $toStart += $svc }
}
if ($toStart.Count -eq 0) { Fail "No known services found in compose. Check $ComposeFile" }

# --- Bring up infra (dynamic) ---
Write-Host ">> Starting services: $($toStart -join ', ') ..."
Invoke-Compose -f $ComposeFile up -d @toStart

# --- Probing core services ---
Write-Host ">> Probing core services ..."
Wait-HttpOk ("{0}/minio/health/ready" -f $MinioEndpoint.TrimEnd('/')) $WaitTimeoutSec
Wait-HttpOk ($MlflowEndpoint.TrimEnd('/')) $WaitTimeoutSec

# --- Probe optional services if present ---
if ($toStart -contains 'cvat_ui') {
  Wait-HttpOk "http://localhost:8080" $WaitTimeoutSec
}
if ($toStart -contains 'triton') {
  Wait-HttpOk "http://localhost:8000/v2/health/ready" $WaitTimeoutSec
}
if ($toStart -contains 'evidently') {
  Wait-HttpOk "http://localhost:8008" $WaitTimeoutSec
}

# --- Optional bootstrap (no-ops if missing) ---
Run-IfExists ".\scripts\init-minio.ps1"      @{ Endpoint = $MinioEndpoint; AccessKey = $AccessKey; SecretKey = $SecretKey }
Run-IfExists ".\scripts\bootstrap-stage.ps1" @{ Endpoint = $MinioEndpoint; AccessKey = $AccessKey; SecretKey = $SecretKey }
# Run-IfExists ".\scripts\start-training.ps1" @{}

Write-Host ">> ✅ Primer completed. Services up: $($toStart -join ', ')"
