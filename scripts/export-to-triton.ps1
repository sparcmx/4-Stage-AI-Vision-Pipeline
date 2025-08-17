param(
    [string]$StageName,
    [string]$Bucket = "models",
    [string]$Endpoint = "http://minio:9000",
    [string]$AccessKey = "minioadmin",
    [string]$SecretKey = "minioadmin"
)

function Normalize-Prefix {
    param([string]$p)
    if (-not $p.EndsWith("/")) { return "$p/" }
    return $p
}

$Prefix = Normalize-Prefix $StageName

aws configure set aws_access_key_id $AccessKey --profile minio
aws configure set aws_secret_access_key $SecretKey --profile minio
aws configure set default.region us-east-1 --profile minio

Write-Host "Ensuring bucket $Bucket exists..."
aws --endpoint-url $Endpoint s3 mb "s3://$Bucket" --profile minio 2>$null | Out-Null

Write-Host "Downloading ONNX model for stage $StageName"
aws --endpoint-url $Endpoint s3 cp "s3://$Bucket/${Prefix}best.onnx" "./best.onnx" --profile minio

Write-Host "Export complete. Place best.onnx in Triton model repo as needed."
