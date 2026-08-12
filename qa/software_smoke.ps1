$ErrorActionPreference = "Stop"
$aleRef = Join-Path $env:RUNNER_TEMP "ale-reference"
Expand-Archive -LiteralPath ./task/reference.zip -DestinationPath $aleRef
$files = Get-ChildItem -LiteralPath $aleRef -Recurse -File | Where-Object { $_.Name -in @("kustomization.yaml", "kustomization.yml", "Kustomization") }
if (-not $files) { throw "kustomization missing" }
foreach ($file in $files) {
  kubectl kustomize (Split-Path -Parent $file.FullName) | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "kubectl kustomize failed" }
}
kubectl version --client --output=json
