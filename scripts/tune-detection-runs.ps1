# 5+ runs: official k6; override threshold / K / HNSW_EF via small compose file (recria api1+api2).
# Uso: .\scripts\tune-detection-runs.ps1  (na raiz do repo)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$k6   = "grafana/k6:latest"
$outDir = "test/tune"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$OverridePath = Join-Path $root "docker-compose.tune-override.yml"
$comp = @("compose", "-f", "docker-compose.yml", "-f", "docker-compose.local.yml", "-f", "docker-compose.tune-override.yml")

function Set-TuneOverride {
  param(
    [string] $T,
    [string] $Fk,
    [string] $Ef
  )
  $yml = @"
services:
  api1:
    environment:
      FRAUD_SCORE_THRESHOLD: "$T"
      FRAUD_K: "$Fk"
      HNSW_EF: "$Ef"
  api2:
    environment:
      FRAUD_SCORE_THRESHOLD: "$T"
      FRAUD_K: "$Fk"
      HNSW_EF: "$Ef"
"@
  Set-Content -Path $OverridePath -Value $yml -Encoding utf8
}

function Wait-Ready {
  for ($i = 0; $i -le 90; $i++) {
    try {
      $r = Invoke-WebRequest -Uri "http://localhost:9999/ready" -UseBasicParsing -TimeoutSec 2
      if ($r.StatusCode -eq 200) { return $true }
    } catch { }
    Start-Sleep -Seconds 2
  }
  return $false
}

# Varredura em torno de 0,32: mais FP => subir T; mais FN => baixar T
$runs = @(
  @{ label = "T0.33_K11_EF40"; T = "0.33"; K = "11"; Ef = "40" },
  @{ label = "T0.34_K11_EF36"; T = "0.34"; K = "11"; Ef = "36" },
  @{ label = "T0.30_K11_EF40"; T = "0.30"; K = "11"; Ef = "40" },
  @{ label = "T0.325_K10_EF40"; T = "0.325"; K = "10"; Ef = "40" },
  @{ label = "T0.315_K12_EF38"; T = "0.315"; K = "12"; Ef = "38" }
)

Write-Host "=== build + up (primeira subida) ===" -ForegroundColor Cyan
Set-TuneOverride "0.32" "11" "36"
docker @comp up -d --build
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
if (-not (Wait-Ready)) { throw "ready timeout" }

$summary = @()
foreach ($run in $runs) {
  Write-Host "`n>>> $($run.label)" -ForegroundColor Yellow
  Set-TuneOverride $run.T $run.K $run.Ef
  docker @comp up -d --no-build --force-recreate api1 api2
  if ($LASTEXITCODE -ne 0) { throw "recreate failed" }
  if (-not (Wait-Ready)) { throw "ready after $($run.label) failed" }

  $f = "test/tune/$($run.label).json"
  docker run --rm `
    -e "URL=http://host.docker.internal:9999/fraud-score" `
    -e "K6_RESULT_FILE=$f" `
    -v "${root}:/work" -w /work `
    $k6 run "test/test.js"
  if ($LASTEXITCODE -ne 0) { throw "k6 $($run.label) failed" }

  $j = Get-Content (Join-Path $root $f) -Raw | ConvertFrom-Json
  $d = $j.scoring.detection_score.value
  $E = $j.scoring.weighted_errors_E
  $fp = $j.scoring.breakdown.false_positive_detections
  $fn = $j.scoring.breakdown.false_negative_detections
  $p99 = $j.p99
  $row = [PSCustomObject]@{
    label  = $run.label
    T = $run.T; K = $run.K; Ef = $run.Ef
    E = $E; FP = $fp; FN = $fn; det = $d; p99 = $p99; final = $j.scoring.final_score
  }
  $summary += $row
  Write-Host ("E={0} det={1} p99={2} FP={3} FN={4}" -f $E, $d, $p99, $fp, $fn) -ForegroundColor Green
}

$summary | Format-Table -AutoSize
$tsv = Join-Path $outDir "summary.tsv"
$summary | Export-Csv -Path (Join-Path $outDir "summary.csv") -NoTypeInformation
Write-Host "`nSalvo: $outDir/*.json, summary.csv" -ForegroundColor Cyan
Remove-Item -Path $OverridePath -ErrorAction SilentlyContinue
