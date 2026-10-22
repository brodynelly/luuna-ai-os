[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$suiteRoot = Split-Path -Parent $PSScriptRoot
$checkoutsRoot = Split-Path -Parent $suiteRoot
$repositories = @('luuna', 'luuna-atlas', 'luuna-beacon', 'luuna-missions')

if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
if (!(Get-Command bun -ErrorAction SilentlyContinue)) { throw 'Bun is required.' }

foreach ($name in $repositories) {
    $checkout = Join-Path $checkoutsRoot $name
    $expected = "https://github.com/brodynelly/$name.git"
    if (Test-Path -LiteralPath $checkout) {
        if (!(Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
            throw "Existing $name directory is not a Git checkout: $checkout"
        }
        $origin = (& git -C $checkout remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0 -or !$origin) { throw "Cannot verify origin for $name." }
        $allowed = @($expected, "https://github.com/brodynelly/$name", "git@github.com:brodynelly/$name.git")
        if ($allowed -notcontains $origin.Trim()) { throw "Existing $name checkout has a different origin; refusing to use it." }
        Write-Output "Using existing $name checkout."
    } else {
        & git clone --recurse-submodules $expected $checkout
        if ($LASTEXITCODE -ne 0) { throw "Could not clone $name. Check GitHub access and retry." }
    }
}

$installer = Join-Path $checkoutsRoot 'luuna\scripts\install-cli.ps1'
if (!(Test-Path -LiteralPath $installer)) { throw 'Luuna CLI installer is missing from its checkout.' }
& $installer -ComponentsRoot $checkoutsRoot
if (!$?) { throw 'Luuna CLI installer failed.' }
