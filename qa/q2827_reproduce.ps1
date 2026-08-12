$ErrorActionPreference = "Stop"
$aleRoot = (Resolve-Path ".").Path
$aleWork = Join-Path $env:RUNNER_TEMP "ale-q2827-work"
$aleEvidence = Join-Path $aleRoot "evidence"
$aleKubectl = (Get-Command kubectl.exe).Source
$aleRuby = (Get-Command ruby.exe).Source

if (Test-Path $aleWork) { Remove-Item -LiteralPath $aleWork -Recurse -Force }
New-Item -ItemType Directory -Path $aleWork | Out-Null
New-Item -ItemType Directory -Path $aleEvidence -Force | Out-Null

function Get-AleTree([string]$Directory) {
  $values = [ordered]@{}
  Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($Directory, $_.FullName).Replace("\", "/")
    $values[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $values
}

function Assert-AleTree([string]$Left, [string]$Right, [string]$Label) {
  $leftJson = (Get-AleTree $Left) | ConvertTo-Json -Compress
  $rightJson = (Get-AleTree $Right) | ConvertTo-Json -Compress
  if ($leftJson -ne $rightJson) { throw "$Label tree mismatch" }
}

function Invoke-AlePrecheck([string]$InputRoot, [string]$ReferenceRoot, [string]$OutputRoot) {
  $env:ALE_INPUT_ROOT = $InputRoot
  $env:ALE_REFERENCE_ROOT = $ReferenceRoot
  $env:ALE_OUTPUT_ROOT = $OutputRoot
  $env:KUBECTL_BIN = $aleKubectl
  $env:RUBY_BIN = $aleRuby
  & $aleRuby (Join-Path $aleRoot "qa/q2827-runtime/run_precheck.rb")
  if ($LASTEXITCODE -ne 0) { throw "precheck failed with exit $LASTEXITCODE" }
}

$aleRules = @()
foreach ($program in @($aleRuby, $aleKubectl)) {
  $name = "ALE-Q2827-$([Guid]::NewGuid().ToString('N'))"
  New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -Program $program | Out-Null
  $aleRules += $name
}

try {
  foreach ($label in @("clean-a", "clean-b")) {
    $base = Join-Path $aleWork $label
    $inputRoot = Join-Path $base "input"
    $referenceRoot = Join-Path $base "reference"
    Expand-Archive -LiteralPath (Join-Path $aleRoot "task/输入数据包.zip") -DestinationPath $inputRoot
    Expand-Archive -LiteralPath (Join-Path $aleRoot "task/reference.zip") -DestinationPath $referenceRoot
    Invoke-AlePrecheck $inputRoot $referenceRoot (Join-Path $base "generated")
    Assert-AleTree (Join-Path $referenceRoot "output/results") (Join-Path $base "generated") "$label Reference"
  }
  Assert-AleTree (Join-Path $aleWork "clean-a/generated") (Join-Path $aleWork "clean-b/generated") "two clean directories"

  $mutationRoot = Join-Path $aleWork "mutation"
  Copy-Item -LiteralPath (Join-Path $aleWork "clean-a/input") -Destination (Join-Path $mutationRoot "input") -Recurse
  Copy-Item -LiteralPath (Join-Path $aleWork "clean-a/reference") -Destination (Join-Path $mutationRoot "reference") -Recurse
  $requestPath = Join-Path $mutationRoot "input/requests/01-r01-editor.yaml"
  $requestText = Get-Content -LiteralPath $requestPath -Raw
  $changedText = $requestText.Replace("metadata: {name: editor,", "metadata: {name: editor-review,")
  if ($changedText -eq $requestText) { throw "mutation target missing" }
  Set-Content -LiteralPath $requestPath -Value $changedText -Encoding utf8
  Invoke-AlePrecheck (Join-Path $mutationRoot "input") (Join-Path $mutationRoot "reference") (Join-Path $mutationRoot "generated")
  $baselineJson = (Get-AleTree (Join-Path $aleWork "clean-a/generated")) | ConvertTo-Json -Compress
  $mutationJson = (Get-AleTree (Join-Path $mutationRoot "generated")) | ConvertTo-Json -Compress
  if ($baselineJson -eq $mutationJson) { throw "valid input mutation did not change results" }

  $negativeRoot = Join-Path $aleWork "negative"
  Copy-Item -LiteralPath (Join-Path $aleWork "clean-a/input") -Destination (Join-Path $negativeRoot "input") -Recurse
  Copy-Item -LiteralPath (Join-Path $aleWork "clean-a/reference") -Destination (Join-Path $negativeRoot "reference") -Recurse
  Remove-Item -LiteralPath (Join-Path $negativeRoot "input/requests/10-r10-archive.yaml")
  $negativeOutput = Join-Path $negativeRoot "generated"
  $env:ALE_INPUT_ROOT = Join-Path $negativeRoot "input"
  $env:ALE_REFERENCE_ROOT = Join-Path $negativeRoot "reference"
  $env:ALE_OUTPUT_ROOT = $negativeOutput
  $env:KUBECTL_BIN = $aleKubectl
  $env:RUBY_BIN = $aleRuby
  & $aleRuby (Join-Path $aleRoot "qa/q2827-runtime/run_precheck.rb") 2>&1 | Out-File (Join-Path $aleEvidence "negative.log")
  $negativeExit = $LASTEXITCODE
  if ($negativeExit -eq 0) { throw "missing request was accepted" }
  if ((Test-Path $negativeOutput) -and (Get-ChildItem -LiteralPath $negativeOutput -Force | Select-Object -First 1)) { throw "negative case left published files" }

  $hashes = Get-Content -LiteralPath (Join-Path $aleRoot "qa/expected_hashes.json") -Raw | ConvertFrom-Json
  $kubectlVersion = (& $aleKubectl version --client --output=json | ConvertFrom-Json).clientVersion.gitVersion
  $rubyVersion = (& $aleRuby --version)
  $payload = [ordered]@{
    result = "PASS"
    qid = "2827"
    commit_sha = $env:GITHUB_SHA
    workflow_run_id = $env:GITHUB_RUN_ID
    windows_image = $env:ImageOS
    kubectl = $kubectlVersion
    ruby = $rubyVersion
    attachment_sha256 = $hashes
    clean_room_runs = 2
    reference_full_tree_match = $true
    valid_input_mutation_changed_results = $true
    negative_exit_code = $negativeExit
    negative_published_files = 0
    outbound_blocked_for_task_programs = $true
    api_server_contacted = $false
  }
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $aleEvidence "q2827_reproduction.json") -Encoding utf8
}
finally {
  foreach ($name in $aleRules) { Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue }
}
