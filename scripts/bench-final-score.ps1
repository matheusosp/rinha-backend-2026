# Múltiplos runs oficiais com override de T / K / EF; prioriza final_score (p99 + det).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$OverridePath = Join-Path $root "docker-compose.tune-override.yml"
$comp = @("compose", "-f", "docker-compose.yml", "-f", "docker-compose.local.yml", "-f", "docker-compose.tune-override.yml")
$k6   = "grafana/k6:latest"
$outDir = "test/bench-3000"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Set-TuneOverride {
  param([string]$T, [string]$Fk, [string]$Ef)
  @"
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
"@ | Set-Content -Path $OverridePath -Encoding utf8
}

function Wait-Ready {
  for ($i = 0; $i -le 100; $i++) {
    try { if ((Invoke-WebRequest -Uri "http://localhost:9999/ready" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { return $true } } catch { }
    Start-Sleep -Seconds 2
  }
  $false
}

# Após Puma>1 + sem mutex: p99 costuma cair; EF baixo = mais rápido (retunar T/K).
$grid = @(
  @{ n="A_T315_K12_EF32"; T="0.315"; K="12"; Ef="32" },
  @{ n="B_T31_K12_EF30";  T="0.31";  K="12"; Ef="30" },
  @{ n="C_T32_K12_EF28";  T="0.32";  K="12"; Ef="28" },
  @{ n="D_T30_K12_EF34";  T="0.30";  K="12"; Ef="34" },
  @{ n="E_T305_K11_EF32"; T="0.305"; K="11"; Ef="32" },
  @{ n="F_T32_K11_EF30";  T="0.32";  K="11"; Ef="30" }
)

Write-Host "=== build (primeiro up) ===" -ForegroundColor Cyan
Set-TuneOverride "0.315" "12" "38"
docker @comp up -d --build
if ($LASTEXITCODE -ne 0) { throw "up failed" }
if (-not (Wait-Ready)) { throw "ready" }

$best = 0.0; $bestFile = ""
foreach ($g in $grid) {
  Write-Host "`n>>> $($g.n)" -ForegroundColor Yellow
  Set-TuneOverride $g.T $g.K $g.Ef
  docker @comp up -d --no-build --force-recreate api1 api2
  if ($LASTEXITCODE -ne 0) { throw "recreate" }
  if (-not (Wait-Ready)) { throw "ready $($g.n)" }
  $f = "$outDir/$($g.n).json"
  $rel = "test/bench-3000/$($g.n).json"
  docker run --rm `
    -e "URL=http://host.docker.internal:9999/fraud-score" `
    -e "K6_RESULT_FILE=$rel" `
    -v "${root}:/work" -w /work `
    $k6 run "test/test.js"
  if ($LASTEXITCODE -ne 0) { throw "k6" }
  $j = (Get-Content (Join-Path $root $f) -Raw) | ConvertFrom-Json
  $fin = [double]$j.scoring.final_score
  $d = $j.scoring.detection_score.value
  $p = $j.p99
  Write-Host ("  final={0:F2}  det={1:F2}  p99={2}" -f $fin, $d, $p) -ForegroundColor Green
  if ($fin -gt $best) { $best = $fin; $bestFile = $f }
}
Write-Host "`nMelhor: $bestFile -> $best" -ForegroundColor Cyan
Remove-Item -Path $OverridePath -ErrorAction SilentlyContinue
