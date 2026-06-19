# Build the standalone vision sidecar exe (no Python needed to run it). One-time setup:
#   py -m pip install pyinstaller
# Then run this script; the exe lands at sidecar\dist\StudioAgentSidecar.exe (committed to the repo).
# If antivirus flags the --onefile build, swap --onefile for --onedir (ships a folder beside the exe).
$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
	py -m PyInstaller --onefile --name StudioAgentSidecar --distpath dist --workpath build --specpath build server.py
	Write-Host "Built dist\StudioAgentSidecar.exe" -ForegroundColor Green
} finally {
	Pop-Location
}
