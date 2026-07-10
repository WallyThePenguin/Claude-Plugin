--!strict
-- Oracle — the four oracle tools (SP2 spec §3): oracle_check, oracle_suite, read_frame,
-- stamp_frame. Suites emit a blindspot manifest: all-green must be unreadable as "done".
local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)
local OracleChecks = require(script.Parent.OracleChecks)
local OracleFrames = require(script.Parent.OracleFrames)

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local Oracle = {}

local function encode(payload: any): string
	local ok, s = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	return if ok then s else '{"ok":false,"error":"encode failed"}'
end

-- Per-family suites: ordered checks (args templated on {target, rig}) + the NOT-asserted list.
local SUITES = {
	["melee-weapon"] = {
		checks = function(target: string, rig: string?, clip: string?)
			return {
				{ check = "frame_consistent", args = { target = target } },
				{ check = "anchored_ok", args = { target = target } },
				{ check = "scale_ratio", args = { target = target, expected = 4.5, tolerance_frac = 0.6 } },
				{ check = "mesh_persisted", args = { target = target } },
				{ check = "grip_sane", args = { tool = target, rig = rig } },
				{ check = "joint_census", args = { rig = rig } },
				{ check = "rig_channel_check", args = { rig = rig, clip = clip } },
				{ check = "clip_arc_of", args = { rig = rig, tool = target, clip = clip } },
				{ check = "clip_self_intersect", args = { rig = rig, tool = target, clip = clip } },
			}
		end,
		notAsserted = {
			"material/texture quality", "silhouette aesthetics vs references", "color palette",
			"swing FEEL (weight/anticipation)", "damage numbers at runtime (playtest twin)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
			"edge_dir orientation (declared, not cross-validated)",
			"clip channel coverage when rig_channel_check is UNKNOWN",
		},
	},
	["animation"] = {
		-- target doubles as the rig path when no separate rig is given (animation rungs ARE rigs).
		checks = function(target: string, rig: string?, clip: string?)
			local r = rig or target
			return {
				{ check = "joint_census", args = { rig = r } },
				{ check = "rig_channel_check", args = { rig = r, clip = clip } },
			}
		end,
		notAsserted = {
			"arc/timing/weight vs references (filmstrip judgment)",
			"foot-slide and limb clipping (capture-only)",
			"tip sweep / self-intersection without a gripped Tool (clip_arc_of needs Semantic_BladeTip)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
		},
	},
}

-- Merge run-mode twin envelopes (verbatim JSON from `play oracle`) into the pending-twin ledger.
-- Anti-Goodhart: an envelope only DISCHARGES a pending entry when it is the mapped twin name for
-- that check, ran with context="run", PASSed, AND quoted non-empty magnitudes; a twin FAIL is a
-- suite failure outright; UNKNOWN (and edit-context or magnitude-free results) discharge nothing.
local function mergeTwins(twin_pending: { string }, twinResults: { any }): ({ string }, { [string]: any }, { any })
	local discharged: { [string]: any } = {}
	local failures: { any } = {}
	for _, tr in twinResults do
		if type(tr) == "table" then
			for _, pending in twin_pending do
				local want = (OracleChecks :: any).twinOf[pending]
				if want ~= nil and tr.check == want then
					if tr.verdict == "FAIL" then
						table.insert(failures, tr)
					elseif tr.verdict == "PASS" and tr.context == "run" and type(tr.magnitudes) == "table" and next(tr.magnitudes) ~= nil then
						discharged[pending] = tr
					end
				end
			end
		end
	end
	local still: { string } = {}
	for _, pending in twin_pending do
		if discharged[pending] == nil then
			table.insert(still, pending)
		end
	end
	return still, discharged, failures
end

local function runSuite(family: string, target: string, rig: string?, clip: string?, twinResults: { any }?): any
	local clipName = clip or "SwordSwing"
	local suite = SUITES[family]
	if suite == nil then
		local names = {}
		for n in SUITES do
			table.insert(names, n)
		end
		return { ok = false, error = "unknown suite family: " .. family .. " (available: " .. table.concat(names, ", ") .. ")" }
	end
	local results = {}
	local counts = { PASS = 0, FAIL = 0, UNKNOWN = 0 } :: { [string]: number }
	local twin_pending: { string } = {}
	local twin_plan: { any } = {}
	for _, spec in suite.checks(target, rig, clipName) do
		local r = OracleChecks.run(spec.check, spec.args)
		table.insert(results, r)
		counts[r.verdict] = (counts[r.verdict] or 0) + 1
		-- EDIT_MISLEADS passes are only provisionally green: they need a runtime twin.
		if r.validity == "EDIT_MISLEADS" and r.verdict == "PASS" then
			table.insert(twin_pending, r.check)
			local twin = (OracleChecks :: any).twinOf[r.check]
			if twin ~= nil then
				table.insert(twin_plan, {
					check = r.check,
					twin = twin,
					cmd = 'play oracle {"check":"' .. twin .. '","args":{"target":"' .. target .. '"}}',
				})
			end
		end
	end
	-- SP2d follow-up: merge run-mode twin envelopes. A twin FAIL joins results and counts.FAIL.
	local twin_evidence: { [string]: any }? = nil
	if twinResults ~= nil then
		local still, discharged, failures = mergeTwins(twin_pending, twinResults)
		twin_pending = still
		twin_evidence = discharged
		for _, f in failures do
			counts.FAIL += 1
			table.insert(results, f)
		end
	end
	local frameMissing: { string }
	local inst = select(1, Path.resolve(target))
	if inst == nil then
		frameMissing = { "target unresolved" }
	else
		local frame, ferr = OracleFrames.read(inst)
		frameMissing = if frame ~= nil then frame.missing else { "no frame: " .. tostring(ferr) }
	end
	return {
		ok = true,
		family = family,
		counts = counts,
		results = results,
		twin_pending = twin_pending,
		twin_plan = twin_plan,
		twin_evidence = twin_evidence,
		green = counts.FAIL == 0 and counts.UNKNOWN == 0 and #twin_pending == 0,
		frameMissing = frameMissing,
		blindspots = suite.notAsserted,
		note = "UNKNOWN never satisfies; blindspots list what was NOT asserted — a green suite is not 'done'. "
			.. "green=false while twin_pending is non-empty (EDIT_MISLEADS passes need their runtime twin). "
			.. "To discharge: playtest_start {mode:'run'}, run each twin_plan[].cmd over the play channel, "
			.. "playtest_stop, then re-run oracle_suite passing the VERBATIM returned JSON as twin_results[] "
			.. "(quote the play-channel output as evidence; a twin FAIL fails the suite).",
	}
end

-- __selftest: builds known-good/known-bad fixtures under workspace.OracleSelfTest,
-- asserts expected verdicts, cleans up. Geometry + frame checks only (grip/clip need a
-- rig and are exercised by the acceptance demo).
local function selftest(): any
	local old = workspace:FindFirstChild("OracleSelfTest")
	if old ~= nil then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "OracleSelfTest"
	folder.Parent = workspace
	local function box(name: string, size: Vector3, cf: CFrame): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Anchored = true
		p.Parent = folder
		return p
	end
	local origin = CFrame.new(0, 100, 0)
	-- a toy sword: grip cylinder at origin, blade box above it along +Y
	local grip = box("GripPart", Vector3.new(0.4, 1.2, 0.4), origin)
	local blade = box("BladePart", Vector3.new(0.4, 4, 0.15), origin * CFrame.new(0, 2.6, 0))
	local results = {}
	local function expect(name: string, verdict: string, r: any)
		table.insert(results, { name = name, expected = verdict, got = r.verdict, ok = r.verdict == verdict, reason = r.reason, magnitudes = r.magnitudes })
	end
	expect("boxes intersect (overlapping)", "PASS", OracleChecks.run("intersects", { a = grip, b = box("Overlap", Vector3.new(1, 1, 1), origin) }))
	expect("gap within limit", "PASS", OracleChecks.run("gap_between", { a = grip, b = blade, max_gap = 1.5 }))
	expect("far boxes fail gap", "FAIL", OracleChecks.run("gap_between", { a = grip, b = box("Far", Vector3.new(1, 1, 1), origin * CFrame.new(20, 0, 0)), max_gap = 0.5 }))
	-- mesh persistence: a naked MeshPart (empty MeshId, no local-rebuild data) FAILs; parts-only PASSes
	do
		local nakedHolder = Instance.new("Model")
		nakedHolder.Name = "NakedMeshHolder"
		nakedHolder.Parent = folder
		local mp = Instance.new("MeshPart")
		mp.Name = "NakedMesh"
		mp.Anchored = true
		mp.Parent = nakedHolder
		expect("naked MeshPart fails persistence", "FAIL", OracleChecks.run("mesh_persisted", { target = nakedHolder }))
		expect("parts-only target passes persistence", "PASS", OracleChecks.run("mesh_persisted", { target = grip }))
	end
	-- frame roundtrip on the toy sword (grip as the "handle": stamp on a Model wrapper)
	local model = Instance.new("Model")
	model.Name = "ToySword"
	model.Parent = folder
	grip.Parent = model
	blade.Parent = model
	model.PrimaryPart = grip
	local _, stampOk = OracleFrames.stamp(model, {
		family = "melee-weapon",
		points = { Grip = { x = 0, y = 0, z = 0 }, BladeTip = { x = 0, y = 4.6, z = 0 } },
		dirs = { blade_dir = { x = 0, y = 1, z = 0 }, edge_dir = { x = 0, y = 0, z = 1 } },
		roles = { hilt = { "GripPart" }, blade = { "BladePart" } },
	})
	table.insert(results, { name = "stamp accepts a valid frame", expected = true, got = stampOk, ok = stampOk == true })
	expect("consistent frame passes", "PASS", OracleChecks.run("frame_consistent", { target = model }))
	-- sabotage: declare blade_dir 90 degrees off -> the anti-lie layer must FAIL it
	OracleFrames.stamp(model, { family = "melee-weapon", dirs = { blade_dir = { x = 1, y = 0, z = 0 } } })
	expect("lying blade_dir is caught", "FAIL", OracleChecks.run("frame_consistent", { target = model }))
	expect("unknown check reports UNKNOWN", "UNKNOWN", OracleChecks.run("no_such_check", {}))
	-- twin-merge logic (pure; the twin IMPLEMENTATIONS live in the run-mode server and are
	-- exercised live via `play oracle` — see liveVerify in the SP2 spec):
	do
		local pending = { "anchored_ok" }
		local runPass = { check = "anchored_weld_census", verdict = "PASS", context = "run", magnitudes = { anchored = 0, parts = 3 } }
		local still1, disc1 = mergeTwins(pending, { runPass })
		table.insert(results, { name = "run-context PASS twin discharges pending", expected = 0, got = #still1, ok = #still1 == 0 and disc1.anchored_ok ~= nil })
		local editPass = { check = "anchored_weld_census", verdict = "PASS", context = "edit", magnitudes = { anchored = 0 } }
		local still2 = mergeTwins(pending, { editPass })
		table.insert(results, { name = "edit-context twin does NOT discharge", expected = 1, got = #still2, ok = #still2 == 1 })
		local noMag = { check = "anchored_weld_census", verdict = "PASS", context = "run", magnitudes = {} }
		local still3 = mergeTwins(pending, { noMag })
		table.insert(results, { name = "magnitude-free twin does NOT discharge", expected = 1, got = #still3, ok = #still3 == 1 })
		local runFail = { check = "anchored_weld_census", verdict = "FAIL", context = "run", magnitudes = { anchored = 2, parts = 3 } }
		local still4, _, fails4 = mergeTwins(pending, { runFail })
		table.insert(results, { name = "twin FAIL is a suite failure and does not discharge", expected = 1, got = #fails4, ok = #fails4 == 1 and #still4 == 1 })
	end
	folder:Destroy()
	local failures = 0
	for _, r in results do
		if not r.ok then
			failures += 1
		end
	end
	return { ok = failures == 0, failures = failures, results = results }
end

-- Register the selftest as a first-class check so it runs through OracleChecks.run (with the
-- standard validity/context/cost_ms envelope). selftest() returns {ok, failures, results},
-- so wrap it into the {verdict, reason, magnitudes} result shape the registry expects.
OracleChecks.register("__selftest", "EDIT_OK", "Builds fixtures and asserts expected verdicts; cleans up.", function(_args)
	local r = selftest()
	return {
		verdict = if r.ok then "PASS" else "FAIL",
		reason = if r.ok then nil else (r.failures .. " selftest rows failed"),
		magnitudes = r,
	}
end)

Oracle.descriptors = {
	{
		name = "oracle_check",
		description = "Run ONE named oracle check (deterministic measurement, ~50-token result with raw magnitudes). "
			.. "Checks: intersects{a,b}, penetration_depth{a,b,max_depth}, gap_between{a,b,max_gap}, "
			.. "alignment{target,dir,against,max_deg,length}, scale_ratio{target,expected,tolerance_frac}, "
			.. "mesh_persisted{target}, "
			.. "anchored_ok{target}, frame_consistent{target}, grip_sane{tool,rig}, joint_census{rig}, "
			.. "rig_channel_check{rig,clip}, clip_arc_of{rig,tool,clip,samples,min_sweep}, "
			.. "clip_self_intersect{rig,tool,clip,samples,max_depth}, __selftest{}. "
			.. "Verdicts: PASS|FAIL|UNKNOWN (UNKNOWN never counts as pass). Prefer these over captures for anything measurable.",
		inputSchema = {
			type = "object",
			properties = {
				check = { type = "string", description = "check name from the registry" },
				args = { type = "object", description = "check arguments (paths as dot-paths, e.g. game.StarterPack.Sword)" },
			},
			required = { "check" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			-- __selftest is now a registered check; a non-PASS verdict (incl. unknown-check) is the tool error.
			local r = OracleChecks.run(tostring(args.check), args.args)
			return encode(r), r.verdict ~= "PASS"
		end,
	},
	{
		name = "oracle_suite",
		description = "Run the full oracle suite for a family against a target (and optional rig). Returns per-check "
			.. "verdicts + magnitudes, counts, the frame's missing fields, and the BLINDSPOT MANIFEST (what was NOT "
			.. "asserted — those items still need captures/rubric judgment). Families: melee-weapon, animation.",
		inputSchema = {
			type = "object",
			properties = {
				family = { type = "string" },
				target = { type = "string", description = "dot-path to the Tool/Model under test" },
				rig = { type = "string", description = "optional dot-path to the rig (default workspace.AgentRig)" },
				clip = { type = "string", description = "clip name for the animation checks (default SwordSwing)" },
				twin_results = {
					type = "array",
					description = "run-mode twin envelopes: the VERBATIM JSON objects `play oracle` returned "
						.. "(from a playtest_start {mode:'run'} session). Discharges matching twin_pending entries; "
						.. "a twin FAIL fails the suite. Only run-context PASSes with magnitudes discharge.",
				},
			},
			required = { "family", "target" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local r = runSuite(
				tostring(args.family),
				tostring(args.target),
				if args.rig ~= nil then tostring(args.rig) else nil,
				if args.clip ~= nil then tostring(args.clip) else nil,
				if type(args.twin_results) == "table" then args.twin_results else nil
			)
			return encode(r), r.ok ~= true
		end,
	},
	{
		name = "read_frame",
		description = "Read a target's semantic frame: declared points/dirs/part-roles and which schema fields are missing.",
		inputSchema = {
			type = "object",
			properties = { target = { type = "string" } },
			required = { "target" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local inst, err = Path.resolve(tostring(args.target))
			if inst == nil then
				return encode({ ok = false, error = err or "not found" }), true
			end
			local frame, ferr = OracleFrames.read(inst)
			if frame == nil then
				return encode({ ok = false, error = ferr }), true
			end
			local points = {}
			for name, v in frame.points :: { [string]: Vector3 } do
				points[name] = { x = v.X, y = v.Y, z = v.Z }
			end
			local dirs = {}
			for name, v in frame.dirs :: { [string]: Vector3 } do
				dirs[name] = { x = v.X, y = v.Y, z = v.Z }
			end
			local roles = {}
			for role, parts in frame.roleParts :: { [string]: { BasePart } } do
				roles[role] = {}
				for _, p in parts do
					table.insert(roles[role], p.Name)
				end
			end
			return encode({ ok = true, family = frame.family, points = points, dirs = dirs, roles = roles, missing = frame.missing }), false
		end,
	},
	{
		name = "stamp_frame",
		description = "Declare a target's semantic frame at BUILD time (points are Handle-local {x,y,z}; dirs are "
			.. "Handle-local unit vectors; roles list part names or dot-paths). Schema for melee-weapon: points Grip+"
			.. "BladeTip, dirs blade_dir+edge_dir, roles hilt+blade (optional guard/pommel). Stamp BEFORE make_tool "
			.. "previews; grip_tool aligns to Semantic_Grip when present. Unknown fields are rejected.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string" },
				frame = { type = "object", description = "{family, points, dirs, roles}" },
			},
			required = { "target", "frame" },
		},
		destructive = true,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local inst, err = Path.resolve(tostring(args.target))
			if inst == nil then
				return encode({ ok = false, error = err or "not found" }), true
			end
			local summary, ok = OracleFrames.stamp(inst, if type(args.frame) == "table" then args.frame else {})
			summary.ok = ok
			return encode(summary), not ok
		end,
	},
}

return Oracle
