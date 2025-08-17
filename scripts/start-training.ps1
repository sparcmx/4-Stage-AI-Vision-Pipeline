param(
    [string]$ConfigPath = "./stages.yaml",
    [string]$ImageName = "yolo-multistage",
    [string]$MLflowUri = "http://mlflow:5000",
    [string]$S3Endpoint = "http://minio:9000",
    [string]$Network = ""
)

$vol = "$(Resolve-Path $ConfigPath):/workspace/config/stages.yaml:ro"

$cmd = @(
    "run","--rm",
    "-e","MLFLOW_TRACKING_URI=$MLflowUri",
    "-e","MLFLOW_S3_ENDPOINT_URL=$S3Endpoint",
    "-e","AWS_ACCESS_KEY_ID=minioadmin",
    "-e","AWS_SECRET_ACCESS_KEY=minioadmin",
    "-e","S3_DATA_BUCKET=datasets",
    "-e","S3_MODELS_BUCKET=models",
    "-v",$vol
)

if ($Network -ne "") { $cmd += @("--network",$Network) }

$cmd += $ImageName

docker @cmd
