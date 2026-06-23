--!strict
-- EnvEvidence: structural evidence for 3D ENVIRONMENT subjects, for evaluate's grader. Censuses the build's
-- BaseParts/meshes/models + material craft (non-default vs Plastic, SurfaceAppearance) + placed lights, and
-- reads the global Lighting service (Atmosphere, Technology, post-effects), so evaluate can grade the
-- material/lighting/performance criteria on real structure (composition/visual criteria still lean on
-- captures). Pure helpers unit-tested; impure gather() reads the DataModel. Mirrors GuiEvidence. "" when the
-- subject has no BaseParts (e.g. a pure GUI subject).

local Lighting = game:GetService("Lighting")

local EnvEvidence = {}

local DEFAULT_MATERIALS: { [string]: boolean } = { Plastic = true, SmoothPlastic = true }
local POST_EFFECTS: { [string]: boolean } = {
	ColorCorrectionEffect = true,
	BloomEffect = true,
	SunRaysEffect = true,
	DepthOfFieldEffect = true,
	BlurEffect = true,
}

export type Stats = {
	meshes: number,
	models: number,
	totalParts: number,
	craftedMat: number,
	surfaceAppearance: number,
	lights: number,
	atmosphere: boolean,
	postEffects: number,
}

-- ---- pure ----

-- A material is "default" (the generic floor) if it is Plastic/SmoothPlastic (or empty).
function EnvEvidence.isDefaultMaterial(name: string): boolean
	return name == "" or DEFAULT_MATERIALS[name] == true
end

-- Format a stats record into a one-paragraph evidence line.
function EnvEvidence.summarize(s: Stats): string
	return string.format(
		"Environment structure: %d BaseParts (%d MeshParts, %d Models); materials: %d/%d parts use a crafted "
			.. "(non-Plastic) material, %d SurfaceAppearance; %d placed lights; lighting: Atmosphere=%s, "
			.. "%d post-effects (ColorCorrection/Bloom/SunRays/DepthOfField/Blur).",
		s.totalParts,
		s.meshes,
		s.models,
		s.craftedMat,
		s.totalParts,
		s.surfaceAppearance,
		s.lights,
		(if s.atmosphere then "yes" else "no"),
		s.postEffects
	)
end

-- ---- impure ----

-- Census the subject's parts/materials/lights + the global Lighting service. "" if no BaseParts.
function EnvEvidence.gather(subject: Instance): string
	local meshes, models, totalParts, craftedMat, surfaceAppearance, lights = 0, 0, 0, 0, 0, 0
	for _, d in subject:GetDescendants() do
		if d:IsA("BasePart") then
			totalParts += 1
			if d:IsA("MeshPart") then
				meshes += 1
			end
			if not EnvEvidence.isDefaultMaterial((d :: BasePart).Material.Name) then
				craftedMat += 1
			end
		elseif d:IsA("Model") then
			models += 1
		elseif d:IsA("SurfaceAppearance") then
			surfaceAppearance += 1
		elseif d:IsA("Light") then
			lights += 1
		end
	end
	if totalParts == 0 then
		return ""
	end
	local postEffects = 0
	for _, d in Lighting:GetChildren() do
		if POST_EFFECTS[d.ClassName] then
			postEffects += 1
		end
	end
	local stats: Stats = {
		meshes = meshes,
		models = models,
		totalParts = totalParts,
		craftedMat = craftedMat,
		surfaceAppearance = surfaceAppearance,
		lights = lights,
		atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") ~= nil,
		postEffects = postEffects,
	}
	return EnvEvidence.summarize(stats)
end

return EnvEvidence
