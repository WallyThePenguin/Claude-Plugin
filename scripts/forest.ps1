# forest.ps1 - resolve the Forest CLI and pass everything through.
#
# WHY THIS EXISTS: the installer appends %LOCALAPPDATA%\forest-cli\bin to the USER
# PATH, which only reaches shells started afterwards. Any already-running shell
# will not see `forest` until it restarts. Resolve it here instead of asking every
# caller to remember.
#
#   .\scripts\forest.ps1 install @scope/pkg
#   .\scripts\forest.ps1 audit

$ErrorActionPreference = 'Stop'

$onPath = Get-Command forest -ErrorAction SilentlyContinue
if ($onPath) {
	& $onPath.Source @args
	exit $LASTEXITCODE
}

$candidates = @(
	(Join-Path $env:LOCALAPPDATA 'forest-cli\bin\forest.exe'),
	(Join-Path $env:USERPROFILE 'AppData\Local\forest-cli\bin\forest.exe')
)

foreach ($candidate in $candidates) {
	if (Test-Path $candidate) {
		& $candidate @args
		exit $LASTEXITCODE
	}
}

Write-Host 'error: the Forest CLI is not installed, or not where this script looks.'
Write-Host ''
Write-Host 'Install it:'
Write-Host '  irm https://releases.forest.dev/install.ps1 | iex'
Write-Host ''
Write-Host 'Then open a new terminal and check:  forest --version'
exit 127
