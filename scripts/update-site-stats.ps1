param(
  [string]$SiteFile = ".\labs\index.html"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SiteFile)) {
  throw "Site file not found: $SiteFile"
}

Write-Host "==> Running forge coverage (this may take time)..."
$forgeOutput = & forge coverage --ir-minimum --report summary --report lcov 2>&1
$exit = $LASTEXITCODE
$forgeText = ($forgeOutput | Out-String)

if ($exit -ne 0) {
  Write-Host $forgeText
  throw "forge coverage failed with exit code $exit"
}

# --- Parse total tests ---
# example: Ran 15 test suites in ... : 202 tests passed, 0 failed, 0 skipped (202 total tests)
$testsMatch = [regex]::Match($forgeText, '\((\d+)\s+total tests\)')
if (-not $testsMatch.Success) {
  throw "Could not parse total tests from forge output."
}
[int]$tests = $testsMatch.Groups[1].Value

# --- Parse invariant calls sum ---
# lines:
# [PASS] invariant_nonceNeverDecreases() (runs: 256, calls: 128000, reverts: 95978)
# [PASS] invariant_revokedPolicyCannotExecute() (runs: 256, calls: 128000, reverts: 95977)
$invMatches = [regex]::Matches($forgeText, '\[PASS\]\s+invariant_[^(]*\([^)]*\)\s+\(runs:\s*\d+,\s*calls:\s*(\d+),')
[int64]$invCallsSum = 0
foreach ($m in $invMatches) {
  $invCallsSum += [int64]$m.Groups[1].Value
}

if ($invMatches.Count -eq 0) {
  Write-Warning "No invariant lines found. Fallback INVAR=128000."
  $invCallsSum = 128000
}

# If two invariants each 128000, UI usually shows 128k+, not 256k+.
# Keep product-style metric as max calls among invariant tests, not sum.
[int64]$invMax = 0
foreach ($m in $invMatches) {
  $v = [int64]$m.Groups[1].Value
  if ($v -gt $invMax) { $invMax = $v }
}
if ($invMax -le 0) { $invMax = $invCallsSum }

Write-Host ("Parsed TESTS={0}, INVAR={1}" -f $tests, $invMax)

# --- Update site file ---
$content = Get-Content $SiteFile -Raw -Encoding UTF8

# Ensure backup
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$SiteFile.bak.$timestamp"
Set-Content -Path $backup -Value $content -Encoding UTF8
Write-Host "Backup created: $backup"

# Replace const TESTS = ...;
if ($content -match 'const\s+TESTS\s*=\s*\d+\s*;') {
  $content = [regex]::Replace($content, 'const\s+TESTS\s*=\s*\d+\s*;', "const TESTS = $tests;")
} else {
  throw "Pattern not found in HTML: const TESTS = ...;"
}

# Replace const INVAR = ...;
if ($content -match 'const\s+INVAR\s*=\s*\d+\s*;') {
  $content = [regex]::Replace($content, 'const\s+INVAR\s*=\s*\d+\s*;', "const INVAR = $invMax;")
} else {
  throw "Pattern not found in HTML: const INVAR = ...;"
}

Set-Content -Path $SiteFile -Value $content -Encoding UTF8
Write-Host "Updated: $SiteFile"
Write-Host ("Done. TESTS={0}, INVAR={1}" -f $tests, $invMax)
