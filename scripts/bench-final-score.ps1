$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$runs = if ($env:RUNS) { [int]$env:RUNS } else { 5 }
$k6 = "grafana/k6:latest"
$outDir = "test/bench"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Wait-Ready {
  for ($i = 0; $i -lt 90; $i++) {
    try {
      $r = Invoke-WebRequest -Uri "http://localhost:9999/ready" -UseBasicParsing -TimeoutSec 2
      if ($r.StatusCode -eq 200) { return $true }
    } catch { }
    Start-Sleep -Seconds 2
  }
  return $false
}

Write-Host "=== docker compose up --build ===" -ForegroundColor Cyan
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d
if ($LASTEXITCODE -ne 0) { throw "docker compose failed" }
if (-not (Wait-Ready)) { throw "ready timeout" }

$summary = @()
for ($i = 1; $i -le $runs; $i++) {
  $resultFile = "$outDir/run-$i.json"
  Write-Host "`n>>> k6 run #$i" -ForegroundColor Yellow
  docker run --rm `
    -e "K6_RESULT_FILE=$resultFile" `
    -v "${root}:/work" -w /work `
    $k6 run "test/test.js"
  if ($LASTEXITCODE -ne 0) { throw "k6 failed" }

  $json = Get-Content (Join-Path $root $resultFile) -Raw | ConvertFrom-Json
  $row = [PSCustomObject]@{
    run = $i
    p99 = $json.p99
    detection = $json.scoring.detection_score.value
    final = $json.scoring.final_score
    fp = $json.scoring.breakdown.false_positive_detections
    fn = $json.scoring.breakdown.false_negative_detections
    errors = $json.scoring.breakdown.http_errors
  }
  $summary += $row
  $row | Format-Table -AutoSize
}

$summary | Format-Table -AutoSize
$summary | Export-Csv -Path (Join-Path $outDir "summary.csv") -NoTypeInformation
