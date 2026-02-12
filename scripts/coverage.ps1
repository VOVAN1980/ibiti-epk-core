Set-Location $PSScriptRoot\..

Remove-Item .\lcov.info -ErrorAction SilentlyContinue
forge coverage --ir-minimum --report lcov --report summary
if ($LASTEXITCODE -ne 0) { throw "coverage failed" }

if (!(Test-Path .\lcov.info)) { throw "lcov.info not found" }

$lcov = ".\lcov.info"
$in = $false; $da0 = @(); $br0 = @()

Get-Content $lcov | ForEach-Object {
  if ($_ -eq "SF:contracts/epk/EPKernel.sol") { $in = $true; return }
  if ($in -and $_ -eq "end_of_record") { $in = $false; return }

  if ($in -and $_ -like "DA:*") {
    $p = $_.Substring(3).Split(",")
    if ([int]$p[1] -eq 0) { $da0 += [int]$p[0] }
  }

  if ($in -and $_ -like "BRDA:*") {
    $p = $_.Substring(5).Split(",")
    if ($p[3] -eq "0" -or $p[3] -eq "-") { $br0 += $_ }
  }
}

$uniqDa = @($da0 | Sort-Object -Unique)
if ($uniqDa.Count) { "EPKernel missing DA lines: $([string]::Join(', ', $uniqDa))" } else { "EPKernel missing DA lines: none" }
if ($br0.Count) { "EPKernel missing BRDA:"; $br0 | Sort-Object } else { "EPKernel missing BRDA: none" }
