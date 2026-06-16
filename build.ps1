# Build the plugin to a .rbxm and install it into the local Studio Plugins folder.
# Happy path: close Studio -> run this -> reopen Studio (Studio loads plugins at startup).
rojo build default.project.json -o StudioAgent.rbxm
if ($?) {
	$dest = Join-Path $env:LOCALAPPDATA 'Roblox\Plugins\StudioAgent.rbxm'
	try {
		Copy-Item StudioAgent.rbxm $dest -Force
		Write-Host "Installed -> $dest"
	} catch {
		Write-Host "Copy failed (is Studio open and locking the file?). Close Studio and re-run."
		throw
	}
}
