--!strict
-- OracleFrames — semantic frames: declare asset semantics at BUILD time (SP2 spec §2.6).
-- Points ride as Attachments on the Handle (Semantic_<Name>); directions ride the
-- SemanticFrame JSON attribute as Handle-local unit vectors; part roles ride
-- CollectionService tags (Semantic_<role>). Never infer at verify time what the
-- builder could declare at build time.
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)

local M = {}

M.TAG_PREFIX = "Semantic_"
M.ATTR = "SemanticFrame"

M.SCHEMAS = {
	["melee-weapon"] = {
		points = { "Grip", "BladeTip" },
		dirs = { "blade_dir", "edge_dir" },
		roles = { required = { "hilt", "blade" }, optional = { "guard", "pommel" } },
	},
}

function M.handleOf(inst: Instance): BasePart?
	if inst:IsA("Tool") then
		local h = inst:FindFirstChild("Handle")
		return if h ~= nil and h:IsA("BasePart") then h else nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function vec(t: any): Vector3
	return Vector3.new(tonumber(t.x) or 0, tonumber(t.y) or 0, tonumber(t.z) or 0)
end

-- stamp(target, frame) -> (summary, ok). frame = { family, points = {Grip={x,y,z}, ...} (Handle-local),
-- dirs = {blade_dir={x,y,z}, ...} (Handle-local, normalized here), roles = {hilt={"partNameOrPath",...}, ...} }
function M.stamp(target: Instance, frame: any): (any, boolean)
	local schema = M.SCHEMAS[tostring(frame.family)]
	if schema == nil then
		return { error = "unknown family: " .. tostring(frame.family) .. " (known: melee-weapon)" }, false
	end
	local handle = M.handleOf(target)
	if handle == nil then
		return { error = "target has no BasePart handle" }, false
	end
	local stamped, errors = {}, {}
	for _, name in schema.points do
		local p = if type(frame.points) == "table" then frame.points[name] else nil
		if type(p) == "table" then
			local att = handle:FindFirstChild(M.TAG_PREFIX .. name)
			if att == nil or not att:IsA("Attachment") then
				att = Instance.new("Attachment")
				att.Name = M.TAG_PREFIX .. name
				att.Parent = handle
			end
			(att :: Attachment).Position = vec(p)
			table.insert(stamped, "point:" .. name)
		end
	end
	local dirs = {}
	for _, name in schema.dirs do
		local d = if type(frame.dirs) == "table" then frame.dirs[name] else nil
		if type(d) == "table" then
			local v = vec(d)
			if v.Magnitude < 1e-4 then
				table.insert(errors, "dir " .. name .. " is a zero vector")
			else
				dirs[name] = { x = v.Unit.X, y = v.Unit.Y, z = v.Unit.Z }
				table.insert(stamped, "dir:" .. name)
			end
		end
	end
	if type(frame.roles) == "table" then
		for role, entries in frame.roles :: { [string]: any } do
			local known = table.find(schema.roles.required, role) or table.find(schema.roles.optional, role)
			if known == nil then
				table.insert(errors, "unknown role: " .. tostring(role))
			elseif type(entries) == "table" then
				for _, entry in entries do
					local inst = select(1, Path.resolve(tostring(entry)))
					if inst == nil then
						inst = target:FindFirstChild(tostring(entry), true)
					end
					if inst ~= nil and inst:IsA("BasePart") then
						CollectionService:AddTag(inst, M.TAG_PREFIX .. role)
						table.insert(stamped, "role:" .. role .. "/" .. inst.Name)
					else
						table.insert(errors, "role " .. role .. ": part not found: " .. tostring(entry))
					end
				end
			end
		end
	end
	handle:SetAttribute(M.ATTR, HttpService:JSONEncode({ family = frame.family, dirs = dirs }))
	return { stamped = stamped, errors = errors }, #errors == 0
end

-- read(target) -> (frame, err?). frame = { family, points = {name -> Vector3 (Handle-local)},
-- dirs = {name -> Vector3 (Handle-local unit)}, roleParts = {role -> {BasePart}}, missing = {string} }
function M.read(target: Instance): (any, string?)
	local handle = M.handleOf(target)
	if handle == nil then
		return nil, "target has no BasePart handle"
	end
	local decoded: any = nil
	local raw = handle:GetAttribute(M.ATTR)
	if type(raw) == "string" then
		local ok, d = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok then
			decoded = d
		end
	end
	local family = if decoded ~= nil then decoded.family else nil
	local schema = if family ~= nil then M.SCHEMAS[family] else nil
	local frame = { family = family, points = {}, dirs = {}, roleParts = {}, missing = {} }
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") and child.Name:sub(1, #M.TAG_PREFIX) == M.TAG_PREFIX then
			frame.points[child.Name:sub(#M.TAG_PREFIX + 1)] = child.Position
		end
	end
	if decoded ~= nil and type(decoded.dirs) == "table" then
		for name, d in decoded.dirs :: { [string]: any } do
			frame.dirs[name] = vec(d)
		end
	end
	local container: Instance = if handle.Parent ~= nil and handle.Parent:IsA("Tool") then handle.Parent else handle
	local parts: { Instance } = if container:IsA("Tool") then container:GetDescendants() else { handle :: Instance }
	for _, part in parts do
		if part:IsA("BasePart") then
			for _, tag in CollectionService:GetTags(part) do
				if tag:sub(1, #M.TAG_PREFIX) == M.TAG_PREFIX then
					local role = tag:sub(#M.TAG_PREFIX + 1)
					if frame.roleParts[role] == nil then
						frame.roleParts[role] = {}
					end
					table.insert(frame.roleParts[role], part)
				end
			end
		end
	end
	if schema ~= nil then
		for _, p in schema.points do
			if frame.points[p] == nil then
				table.insert(frame.missing, "point:" .. p)
			end
		end
		for _, d in schema.dirs do
			if frame.dirs[d] == nil then
				table.insert(frame.missing, "dir:" .. d)
			end
		end
		for _, r in schema.roles.required do
			if frame.roleParts[r] == nil then
				table.insert(frame.missing, "role:" .. r)
			end
		end
	else
		table.insert(frame.missing, "frame attribute (family) — stamp_frame has not run")
	end
	return frame, nil
end

return M
