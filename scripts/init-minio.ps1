param(
    [string]$Endpoint = "http://minio:9000",
    [string]$AccessKey = "minioadmin",
    [string]$SecretKey = "minioadmin"
)

aws configure set aws_access_key_id $AccessKey --profile minio
aws configure set aws_secret_access_key $SecretKey --profile minio
aws configure set default.region us-east-1 --profile minio

foreach ($bucket in @("datasets", "models")) {
    Write-Host "Ensuring bucket $bucket exists..."
    aws --endpoint-url $Endpoint s3 mb "s3://$bucket" --profile minio 2>$null | Out-Null
}
