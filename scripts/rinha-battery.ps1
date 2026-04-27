# Bateria k6: oficial (2x) + ramp + peak; defina K6_FULL=1 para carga sustained (longa)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

Write-Host "=== docker compose up --build ===" -ForegroundColor Cyan
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://localhost:9999/ready" -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $ok = $true; break }
  } catch { Start-Sleep -Seconds 2 }
}
if (-not $ok) { Write-Error "ready failed"; exit 1 }

$k6 = "grafana/k6:latest"
$script = "test/test.js"

function Invoke-RinhaK6 {
  param(
    [string] $ResultFile,
    [string] $Stress = "official"
  )
  if ($Stress -eq "official") {
    docker run --rm `
      -e "URL=http://host.docker.internal:9999/fraud-score" `
      -e "K6_RESULT_FILE=$ResultFile" `
      -v "${root}:/work" -w /work `
      $k6 run $script
  } else {
    docker run --rm `
      -e "URL=http://host.docker.internal:9999/fraud-score" `
      -e "K6_STRESS=$Stress" `
      -e "K6_RESULT_FILE=$ResultFile" `
      -v "${root}:/work" -w /work `
      $k6 run $script
  }
  if ($LASTEXITCODE -ne 0) { throw "k6 $Stress -> $ResultFile failed: $LASTEXITCODE" }
}

Write-Host "`n>>> official #1" -ForegroundColor Yellow
Invoke-RinhaK6 "test/results-run-1.json" "official"

Write-Host "`n>>> official #2" -ForegroundColor Yellow
Invoke-RinhaK6 "test/results-run-2.json" "official"

Write-Host "`n>>> stress ramp" -ForegroundColor Yellow
Invoke-RinhaK6 "test/results-stress-ramp.json" "ramp"

Write-Host "`n>>> stress peak" -ForegroundColor Yellow
Invoke-RinhaK6 "test/results-stress-peak.json" "peak"

if ($env:K6_FULL) {
  Write-Host "`n>>> stress sustained" -ForegroundColor Yellow
  Invoke-RinhaK6 "test/results-stress-sustained.json" "sustained"
}

Write-Host "`n>>> official (results.json final)" -ForegroundColor Yellow
Invoke-RinhaK6 "test/results.json" "official"

Write-Host "`n=== feito. test/results*.json ===" -ForegroundColor Green
