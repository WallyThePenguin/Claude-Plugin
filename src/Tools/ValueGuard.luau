--!strict
-- ValueGuard: shared write-tool policy for structured values that DECODED to nil. Decode is total,
-- so a nil result can mean two very different things; both are refused rather than assigned:
--  - reference tags (Instance/EnumItem/BrickColor): the best-effort lookup DID NOT RESOLVE.
--    Assigning the nil would silently deparent/clear the target (Parent, PrimaryPart) and commit
--    a surprising "success", or throw the engine's cryptic type-mismatch error (BrickColor).
--  - geometric tags (Vector3/Vector2/CFrame/Color3/UDim2/UDim): strict numeric validation refused
--    a malformed payload (a non-number field -- numeric strings included -- or a missing field).
--    Post-drift (2026-07) the constructors would have coerced the garbage to 0 and produced a
--    plausible-but-wrong value; Decode yields nil instead, and the tools refuse it here with a
--    message that teaches the fix.
-- Used by set_property (hard refusal) and create_instance (per-property failed[] entry). A plain
-- JSON null for an untagged value is NOT refused here -- it still flows to the engine, which
-- rejects type-mismatched nils itself.

local ValueGuard = {}

local REFERENCE_TAGS: { [string]: boolean } = {
	Instance = true,
	EnumItem = true,
	BrickColor = true,
}

local GEOMETRIC_TAGS: { [string]: boolean } = {
	Vector3 = true,
	Vector2 = true,
	CFrame = true,
	Color3 = true,
	UDim2 = true,
	UDim = true,
}

-- If rawValue is a guarded tagged payload whose decode came back nil, return the refusal message;
-- nil means no objection (decoded is non-nil, or rawValue is not a guarded tag).
function ValueGuard.nilDecodeRefusal(rawValue: any, decoded: any): string?
	if decoded ~= nil then
		return nil
	end
	if type(rawValue) ~= "table" then
		return nil
	end
	local tag = rawValue.__t
	if type(tag) ~= "string" then
		return nil
	end
	if REFERENCE_TAGS[tag] then
		return "value reference did not resolve"
	end
	if GEOMETRIC_TAGS[tag] then
		return "value malformed: every numeric field of a "
			.. tag
			.. ' must be a JSON number (a string like "1" or a missing field is refused, never coerced)'
	end
	return nil
end

return ValueGuard
