[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$suiteRoot = Split-Path -Parent $PSScriptRoot
$checkoutsRoot = Join-Path $suiteRoot 'sources'
$repositories = @('luuna', 'luuna-atlas', 'luuna-beacon', 'luuna-missions', 'luuna-roots')

if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
if (!(Get-Command bun -ErrorAction SilentlyContinue)) { throw 'Bun is required.' }

foreach ($name in $repositories) {
    $checkout = Join-Path $checkoutsRoot $name
    $relative = "sources/$name"
    $expected = "https://github.com/brodynelly/$name.git"
    if (!(Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
        & git -C $suiteRoot submodule update --init -- $relative
        if ($LASTEXITCODE -ne 0) { throw "Could not initialize $name. Check GitHub access and retry." }
    }
    $origin = (& git -C $checkout remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or !$origin) { throw "Cannot verify origin for $name." }
    $allowed = @($expected, "https://github.com/brodynelly/$name", "git@github.com:brodynelly/$name.git")
    if ($allowed -notcontains $origin.Trim()) { throw "Existing $name checkout has a different origin; refusing to use it." }
    $tree = (& git -C $suiteRoot ls-tree HEAD -- $relative)
    if ($LASTEXITCODE -ne 0 -or !$tree) { throw "Missing committed pin for $name." }
    $pin = ($tree -split '\s+')[2]
    $actual = (& git -C $checkout rev-parse HEAD).Trim()
    if ($actual -ne $pin) { throw "The $name checkout differs from the suite pin; refusing to install." }
    $dirty = (& git -C $checkout status --porcelain)
    if ($dirty) { throw "The $name checkout has local changes; refusing to install." }
    Write-Output "Using pinned $name checkout."
}

$installer = Join-Path $checkoutsRoot 'luuna\scripts\install-cli.ps1'
if (!(Test-Path -LiteralPath $installer)) { throw 'Luuna CLI installer is missing from its checkout.' }
& $installer -ComponentsRoot $checkoutsRoot
if (!$?) { throw 'Luuna CLI installer failed.' }

$rootsCheckout = Join-Path $checkoutsRoot 'luuna-roots'
$rootsPackagePath = Join-Path $rootsCheckout 'package.json'
$rootsEntry = Join-Path $rootsCheckout 'src\index.ts'
if (!(Test-Path -LiteralPath $rootsPackagePath) -or !(Test-Path -LiteralPath $rootsEntry)) {
    throw 'Luuna Roots checkout is missing its CLI entry.'
}
$rootsPackage = Get-Content -LiteralPath $rootsPackagePath -Raw | ConvertFrom-Json
if ($rootsPackage.name -ne '@luuna/roots-cli' -or !$rootsPackage.bin.PSObject.Properties['luuna-roots']) {
    throw 'Luuna Roots checkout does not expose the expected CLI.'
}
& bun install --frozen-lockfile --ignore-scripts --cwd $rootsCheckout
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed for Luuna Roots.' }
$installDirectory = Join-Path $env:LOCALAPPDATA 'Luuna\bin'
if (!(Test-Path -LiteralPath $installDirectory)) { throw 'Luuna CLI launcher directory was not created.' }
$rootsLauncher = "@echo off`r`nbun `"$rootsEntry`" %*`r`n"
Set-Content -LiteralPath (Join-Path $installDirectory 'luuna-roots.cmd') -Value $rootsLauncher -Encoding Ascii
Set-Content -LiteralPath (Join-Path $installDirectory 'lrt.cmd') -Value "@echo off`r`n`"%~dp0luuna-roots.cmd`" %*`r`n" -Encoding Ascii
Write-Output 'Installed Luuna Roots launchers: luuna-roots, lrt.'
