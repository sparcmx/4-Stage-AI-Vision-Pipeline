param(
    [string]$StageName,
    [string]$DatasetPath,
    [string]$ParamsPath,
    [string]$Bucket = "datasets",
    [string]$Prefix = $StageName,
    [string]$Endpoint = "http://localhost:9000",
    [string]$AccessKey = "minioadmin",
    [string]$SecretKey = "minioadmin",
    [switch]$AllowPickFirst
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Resolve repo root = parent of the scripts folder (this file usually lives in ...\mlops-pipeline\scripts)
$RepoRoot   = Split-Path $PSScriptRoot -Parent
$StagesRoot = Join-Path $RepoRoot "yolo-trainer\config\stages"

function Normalize-Prefix {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    if (-not $p.EndsWith("/")) { return "$p/" }
    return $p
}

function Find-File([string]$explicit, [string]$fallback1, [string]$fallback2) {
    if ($explicit -and (Test-Path $explicit)) { return (Resolve-Path $explicit).Path }
    if ($fallback1 -and (Test-Path $fallback1)) { return (Resolve-Path $fallback1).Path }
    if ($fallback2 -and (Test-Path $fallback2)) { return (Resolve-Path $fallback2).Path }
    return $null
}

function Find-Stage {
    param([string]$StageName, [string]$DatasetPath, [string]$StagesRoot, [switch]$AllowPickFirst)

    if (-not [string]::IsNullOrWhiteSpace($StageName)) { return $StageName }

    if ($DatasetPath -and (Test-Path $DatasetPath)) {
        $dp = (Resolve-Path $DatasetPath).Path
        $parent = Split-Path $dp -Parent
        $name = Split-Path $parent -Leaf
        if ($name) { return $name }
    }

    $cwdDs = Join-Path (Get-Location) "dataset.yaml"
    if (Test-Path $cwdDs) {
        $cwdName = Split-Path (Get-Location) -Leaf
        if ($cwdName) { return $cwdName }
    }

    $candidates = @()
    if ($StagesRoot -and (Test-Path $StagesRoot)) {
        $candidates = Get-ChildItem -Path $StagesRoot -Filter "dataset.yaml" -Recurse -File |
                      Select-Object -ExpandProperty DirectoryName -Unique
    }

    if ($candidates.Count -eq 1) {
        return (Split-Path $candidates[0] -Leaf)
    } elseif ($candidates.Count -gt 1) {
        if ($AllowPickFirst) {
            $pick = ($candidates | Sort-Object)[0]
            Write-Host "Multiple stages found under $StagesRoot; picking: $(Split-Path $pick -Leaf)"
            return (Split-Path $pick -Leaf)
        }
        $list = ($candidates | ForEach-Object { " - " + (Split-Path $_ -Leaf) }) -join "`n"
        throw "Multiple stages found under $StagesRoot. Use -StageName. Candidates:`n$list"
    }

    return $null
}

# -------- Resolve StageName --------
$StageName = Find-Stage -StageName $StageName -DatasetPath $DatasetPath -StagesRoot $StagesRoot -AllowPickFirst:$AllowPickFirst
if ([string]::IsNullOrWhiteSpace($StageName)) {
    throw "StageName not found. Use -StageName <name>, -DatasetPath <path>, run inside a stage folder, or keep one stage under $StagesRoot."
}

# Default Prefix -> StageName/
if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix = Normalize-Prefix $StageName
} else {
    $Prefix = Normalize-Prefix $Prefix
}


# ---------- Resolve dataset/params ----------
$datasetAbs = Find-File `
    -explicit $DatasetPath `
    -fallback1 (Join-Path (Join-Path $StagesRoot $StageName) "dataset.yaml") `
    -fallback2 (Join-Path (Get-Location) "dataset.yaml")

if (-not $datasetAbs) {
    throw "dataset.yaml not found. Pass -DatasetPath or place it at $StagesRoot\$StageName\dataset.yaml (or .\dataset.yaml)."
}

$paramsAbs = Find-File `
    -explicit $ParamsPath `
    -fallback1 (Join-Path (Split-Path $datasetAbs -Parent) "params.yaml") `
    -fallback2 (Join-Path (Get-Location) "params.yaml")

# ---------- AWS (MinIO) profile ----------
aws configure set aws_access_key_id $AccessKey --profile minio | Out-Null
aws configure set aws_secret_access_key $SecretKey --profile minio | Out-Null
aws configure set default.region us-east-1 --profile minio | Out-Null

Write-Host "Ensuring bucket $Bucket exists..."
try {
    aws --endpoint-url $Endpoint s3 ls "s3://$Bucket" --profile minio 1>$null 2>$null
} catch {
    aws --endpoint-url $Endpoint s3 mb "s3://$Bucket" --profile minio 1>$null
}

# ---------- Upload ----------
Write-Host "Uploading dataset.yaml for stage '$StageName' from $datasetAbs -> s3://$Bucket/${Prefix}dataset.yaml"
aws --endpoint-url $Endpoint s3 cp "$datasetAbs" "s3://$Bucket/${Prefix}dataset.yaml" --profile minio

if ($paramsAbs) {
    Write-Host "Uploading params.yaml from $paramsAbs -> s3://$Bucket/${Prefix}params.yaml"
    aws --endpoint-url $Endpoint s3 cp "$paramsAbs" "s3://$Bucket/${Prefix}params.yaml" --profile minio
} else {
    Write-Host "No params.yaml found (optional)."
}

$imagesRoot = Split-Path $datasetAbs -Parent
Write-Host "Uploading data under $imagesRoot -> s3://$Bucket/$Prefix (excluding dataset.yaml, params.yaml)"
aws --endpoint-url $Endpoint s3 cp "$imagesRoot" "s3://$Bucket/$Prefix" --recursive `
    --exclude "dataset.yaml" --exclude "params.yaml" --profile minio
