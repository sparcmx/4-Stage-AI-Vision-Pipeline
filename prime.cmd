@echo off
cd /d "%~dp0yolo-trainer"
docker build -t mlops-pipeline-yolo-trainer -f Dockerfile .
cd /d "%~dp0"

:: Run prime.ps1 with ExecutionPolicy Bypass
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0prime.ps1"
