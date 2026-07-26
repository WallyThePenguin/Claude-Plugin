--!strict
-- Oracle — the four oracle tools (SP2 spec §3): oracle_check, oracle_suite, read_frame,
-- stamp_frame. Suites emit a blindspot manifest: all-green must be unreadable as "done".
local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)
local OracleChecks = require(script.Parent.OracleChecks)
local OracleFrames = require(script.Parent.OracleFrames)
local AnimationClip = require(script.Parent.Parent.AnimationClip)

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
				{
					check = "scale_ratio",
					args = { target = target, expected = 4.5, tolerance_frac = 0.6 },
				},
				{ check = "extents_profile", args = { target = target } },
				{ check = "mesh_persisted", args = { target = target } },
				{ check = "texture_applied", args = { target = target } },
				{ check = "texel_stretch", args = { target = target } },
				{ check = "grip_sane", args = { tool = target, rig = rig } },
				{ check = "tool_clip_current", args = { tool = target } },
				{ check = "joint_census", args = { rig = rig } },
				{ check = "rig_channel_check", args = { rig = rig, clip = clip } },
				{ check = "clip_arc_of", args = { rig = rig, tool = target, clip = clip } },
				{ check = "weapon_channel_of", args = { rig = rig, clip = clip } },
				{ check = "clip_self_intersect", args = { rig = rig, tool = target, clip = clip } },
				{ check = "capture_vantage", args = { rig = rig, tool = target } },
				{ check = "clip_posture_sane", args = { rig = rig, clip = clip } },
			}
		end,
		notAsserted = {
			"texture AESTHETICS — style/palette/theme match vs the reference (texel GEOMETRY is now asserted: texel_stretch/texture_applied; taste is not)",
			"silhouette aesthetics vs references",
			"color palette",
			"swing FEEL (weight/anticipation)",
			"damage numbers at runtime (playtest twin)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
			"edge_dir orientation (declared, not cross-validated)",
			"clip channel coverage when rig_channel_check is UNKNOWN",
			"clip visual correctness when tool_clip_current is green (it asserts grip-stamp FRESHNESS — staleness, not that the motion reads right)",
			"articulated chain SWEEP magnitude (default weapon_channel_of fails only an UNKEYED chain; run it with require_chain=true for strike clips — keyed-but-static segments pass the suite)",
		},
	},
	["animation"] = {
		-- target doubles as the rig path when no separate rig is given (animation rungs ARE rigs).
		checks = function(target: string, rig: string?, clip: string?)
			local r = rig or target
			return {
				{ check = "joint_census", args = { rig = r } },
				{ check = "rig_channel_check", args = { rig = r, clip = clip } },
				{ check = "weapon_channel_of", args = { rig = r, clip = clip } },
			}
		end,
		notAsserted = {
			"arc/timing/weight vs references (filmstrip judgment)",
			"foot-slide and limb clipping (capture-only)",
			"tip sweep / self-intersection without a gripped Tool (clip_arc_of needs Semantic_BladeTip)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
			"articulated chain SWEEP magnitude (default weapon_channel_of fails only an UNKEYED chain; run it with require_chain=true for strike clips)",
		},
	},
}

-- Merge run-mode twin envelopes (verbatim JSON from `play oracle`) into the pending-twin ledger.
-- Anti-Goodhart: an envelope only DISCHARGES a pending entry when it is the mapped twin name for
-- that check, ran with context="run", PASSed, AND quoted non-empty magnitudes; a twin FAIL is a
-- suite failure outright; UNKNOWN (and edit-context or magnitude-free results) discharge nothing.
local function mergeTwins(
	twin_pending: { string },
	twinResults: { any }
): ({ string }, { [string]: any }, { any })
	local discharged: { [string]: any } = {}
	local failures: { any } = {}
	for _, tr in twinResults do
		if type(tr) == "table" then
			for _, pending in twin_pending do
				local want = (OracleChecks :: any).twinOf[pending]
				if want ~= nil and tr.check == want then
					if tr.verdict == "FAIL" then
						table.insert(failures, tr)
					elseif
						tr.verdict == "PASS"
						and tr.context == "run"
						and type(tr.magnitudes) == "table"
						and next(tr.magnitudes) ~= nil
					then
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

-- Twin-source precedence (SP2e follow-up; INTER-AGENT CONTRACT with the sidecar): the sidecar
-- ARCHIVES every `play oracle` envelope per play session and serves them at GET /play/twins as
-- {"session": N, "active": bool, "twins": [verbatim envelopes]}. Sidecar-witnessed envelopes are
-- the TRUSTED source (the sidecar saw them arrive over the play channel); caller-supplied
-- twin_results are honest-agent evidence but FORGEABLE, so they are only the fail-open fallback.
-- Pure table logic (selftest-covered); the merge RULES are identical for both sources.
local function chooseTwinSource(sidecarBody: any, callerTwins: { any }?): ({ any }?, string)
	if
		type(sidecarBody) == "table"
		and type(sidecarBody.twins) == "table"
		and #sidecarBody.twins > 0
	then
		return sidecarBody.twins,
			"twin source: sidecar-witnessed (session " .. tostring(sidecarBody.session) .. ")"
	end
	if callerTwins ~= nil then
		local why = if sidecarBody == nil
			then "sidecar /play/twins unreachable"
			else "sidecar /play/twins empty/malformed"
		return callerTwins,
			"twin source: caller-supplied ("
				.. why
				.. "; fail-open — caller-supplied evidence is FORGEABLE, quote the play-channel output verbatim)"
	end
	return nil, "twin source: none (sidecar /play/twins unavailable, no caller twin_results)"
end

-- One silent-graceful GET: any connection error, non-200 (the route 404s until the sidecar's next
-- restart), or undecodable body degrades to fail-open — one note line in the suite, never an error.
local function fetchSidecarTwins(baseUrl: string?): any
	if baseUrl == nil then
		return nil
	end
	local okReq, res = pcall(function()
		return HttpService:RequestAsync({ Url = baseUrl .. "/play/twins", Method = "GET" })
	end)
	if not okReq or res == nil or not (res :: any).Success then
		return nil
	end
	local okJ, body = pcall(function()
		return HttpService:JSONDecode((res :: any).Body)
	end)
	return if okJ then body else "malformed body"
end

local function runSuite(
	family: string,
	target: string,
	rig: string?,
	clip: string?,
	twinResults: { any }?,
	sidecarBase: string?,
	allowStaticGrip: boolean?
): any
	local clipName = clip or "SwordSwing"
	local suite = SUITES[family]
	if suite == nil then
		local names = {}
		for n in SUITES do
			table.insert(names, n)
		end
		return {
			ok = false,
			error = "unknown suite family: " .. family .. " (available: " .. table.concat(
				names,
				", "
			) .. ")",
		}
	end
	local results = {}
	local counts = { PASS = 0, FAIL = 0, UNKNOWN = 0 } :: { [string]: number }
	local twin_pending: { string } = {}
	local twin_plan: { any } = {}
	for _, spec in suite.checks(target, rig, clipName) do
		if spec.check == "weapon_channel_of" and allowStaticGrip == true then
			-- retargeted held-weapon clips keep the grip channel static by design
			spec.args.allow_static_grip = true
		end
		local r = OracleChecks.run(spec.check, spec.args)
		table.insert(results, r)
		counts[r.verdict] = (counts[r.verdict] or 0) + 1
		-- EDIT_MISLEADS passes are only provisionally green: they need a runtime twin.
		if r.validity == "EDIT_MISLEADS" and r.verdict == "PASS" then
			table.insert(twin_pending, r.check)
			local twin = (OracleChecks :: any).twinOf[r.check]
			if twin ~= nil then
				-- per-twin args: played_arc_of measures the rig+clip, the census twins the target
				local argsJson = if twin == "played_arc_of"
					then '{"rig":"'
						.. (rig or "game.Workspace.AgentRig")
						.. '","clip":"'
						.. clipName
						.. '"}'
					else '{"target":"' .. target .. '"}'
				table.insert(twin_plan, {
					check = r.check,
					twin = twin,
					cmd = 'play oracle {"check":"' .. twin .. '","args":' .. argsJson .. "}",
				})
			end
		end
	end
	-- SP2d/SP2e: merge run-mode twin envelopes — SIDECAR-WITNESSED (GET /play/twins) beats
	-- caller-supplied twin_results (forgeable, fail-open). A twin FAIL joins results and counts.FAIL;
	-- a discharged check also leaves twin_plan (its run already happened).
	local twin_evidence: { [string]: any }? = nil
	local twin_source: string? = nil
	if #twin_pending > 0 then
		local chosen, sourceNote = chooseTwinSource(fetchSidecarTwins(sidecarBase), twinResults)
		twin_source = sourceNote
		if chosen ~= nil then
			local still, discharged, failures = mergeTwins(twin_pending, chosen)
			twin_pending = still
			twin_evidence = discharged
			local plan: { any } = {}
			for _, p in twin_plan do
				if discharged[p.check] == nil then
					table.insert(plan, p)
				end
			end
			twin_plan = plan
			for _, f in failures do
				counts.FAIL += 1
				table.insert(results, f)
			end
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
		twin_source = twin_source,
		green = counts.FAIL == 0 and counts.UNKNOWN == 0 and #twin_pending == 0,
		frameMissing = frameMissing,
		blindspots = suite.notAsserted,
		note = "UNKNOWN never satisfies; blindspots list what was NOT asserted — a green suite is not 'done'. "
			.. "green=false while twin_pending is non-empty (EDIT_MISLEADS passes need their runtime twin). "
			.. "To discharge: playtest_start {mode:'run'}, run each twin_plan[].cmd over the play channel, "
			.. "playtest_stop, then re-run oracle_suite — envelopes are auto-fetched from the sidecar witness "
			.. "(GET /play/twins, trusted) when available; otherwise pass the VERBATIM returned JSON as "
			.. "twin_results[] (fail-open, forgeable — quote the play-channel output as evidence; a twin FAIL "
			.. "fails the suite).",
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
		table.insert(results, {
			name = name,
			expected = verdict,
			got = r.verdict,
			ok = r.verdict == verdict,
			reason = r.reason,
			magnitudes = r.magnitudes,
		})
	end
	expect(
		"boxes intersect (overlapping)",
		"PASS",
		OracleChecks.run(
			"intersects",
			{ a = grip, b = box("Overlap", Vector3.new(1, 1, 1), origin) }
		)
	)
	expect(
		"gap within limit",
		"PASS",
		OracleChecks.run("gap_between", { a = grip, b = blade, max_gap = 1.5 })
	)
	expect(
		"far boxes fail gap",
		"FAIL",
		OracleChecks.run("gap_between", {
			a = grip,
			b = box("Far", Vector3.new(1, 1, 1), origin * CFrame.new(20, 0, 0)),
			max_gap = 0.5,
		})
	)
	-- extents_profile: the toy blade is weapon-shaped (PASS); a photo-card slab FAILs (GIGO gate)
	expect(
		"blade-shaped extents pass profile",
		"PASS",
		OracleChecks.run("extents_profile", { target = blade })
	)
	expect(
		"slab extents fail profile",
		"FAIL",
		OracleChecks.run(
			"extents_profile",
			{ target = box("Slab", Vector3.new(4, 3, 0.1), origin * CFrame.new(0, 0, 8)) }
		)
	)
	-- mesh persistence: a naked MeshPart (empty MeshId, no local-rebuild data) FAILs; parts-only PASSes
	do
		local nakedHolder = Instance.new("Model")
		nakedHolder.Name = "NakedMeshHolder"
		nakedHolder.Parent = folder
		local mp = Instance.new("MeshPart")
		mp.Name = "NakedMesh"
		mp.Anchored = true
		mp.Parent = nakedHolder
		expect(
			"naked MeshPart fails persistence",
			"FAIL",
			OracleChecks.run("mesh_persisted", { target = nakedHolder })
		)
		expect(
			"parts-only target passes persistence",
			"PASS",
			OracleChecks.run("mesh_persisted", { target = grip })
		)
		-- upload-era arm (b): a recorded in-flight upload (pending attrs) passes without a MeshId
		mp:SetAttribute("SAMeshAssetPending", true)
		mp:SetAttribute("SAMeshAssetId", 125859573478095)
		expect(
			"pending-upload MeshPart passes persistence",
			"PASS",
			OracleChecks.run("mesh_persisted", { target = nakedHolder })
		)
		mp:SetAttribute("SAMeshAssetPending", nil)
		mp:SetAttribute("SAMeshAssetId", nil)
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
	table.insert(results, {
		name = "stamp accepts a valid frame",
		expected = true,
		got = stampOk,
		ok = stampOk == true,
	})
	expect(
		"consistent frame passes",
		"PASS",
		OracleChecks.run("frame_consistent", { target = model })
	)
	-- sabotage: declare blade_dir 90 degrees off -> the anti-lie layer must FAIL it
	OracleFrames.stamp(
		model,
		{ family = "melee-weapon", dirs = { blade_dir = { x = 1, y = 0, z = 0 } } }
	)
	expect(
		"lying blade_dir is caught",
		"FAIL",
		OracleChecks.run("frame_consistent", { target = model })
	)
	expect("unknown check reports UNKNOWN", "UNKNOWN", OracleChecks.run("no_such_check", {}))
	-- twin-merge logic (pure; the twin IMPLEMENTATIONS live in the run-mode server and are
	-- exercised live via `play oracle` — see liveVerify in the SP2 spec):
	do
		local pending = { "anchored_ok" }
		local runPass = {
			check = "anchored_weld_census",
			verdict = "PASS",
			context = "run",
			magnitudes = { anchored = 0, parts = 3 },
		}
		local still1, disc1 = mergeTwins(pending, { runPass })
		table.insert(results, {
			name = "run-context PASS twin discharges pending",
			expected = 0,
			got = #still1,
			ok = #still1 == 0 and disc1.anchored_ok ~= nil,
		})
		local editPass = {
			check = "anchored_weld_census",
			verdict = "PASS",
			context = "edit",
			magnitudes = { anchored = 0 },
		}
		local still2 = mergeTwins(pending, { editPass })
		table.insert(results, {
			name = "edit-context twin does NOT discharge",
			expected = 1,
			got = #still2,
			ok = #still2 == 1,
		})
		local noMag =
			{ check = "anchored_weld_census", verdict = "PASS", context = "run", magnitudes = {} }
		local still3 = mergeTwins(pending, { noMag })
		table.insert(results, {
			name = "magnitude-free twin does NOT discharge",
			expected = 1,
			got = #still3,
			ok = #still3 == 1,
		})
		local runFail = {
			check = "anchored_weld_census",
			verdict = "FAIL",
			context = "run",
			magnitudes = { anchored = 2, parts = 3 },
		}
		local still4, _, fails4 = mergeTwins(pending, { runFail })
		table.insert(results, {
			name = "twin FAIL is a suite failure and does not discharge",
			expected = 1,
			got = #fails4,
			ok = #fails4 == 1 and #still4 == 1,
		})
		-- twin-source precedence (SP2e follow-up; pure — the /play/twins HTTP fetch is exercised live):
		local witnessed = {
			check = "anchored_weld_census",
			verdict = "PASS",
			context = "run",
			magnitudes = { anchored = 0 },
		}
		local callerForged = {
			check = "anchored_weld_census",
			verdict = "FAIL",
			context = "run",
			magnitudes = { anchored = 9 },
		}
		local chosen5, note5 = chooseTwinSource(
			{ session = 3, active = false, twins = { witnessed } },
			{ callerForged }
		)
		local sidecarWon = chosen5 ~= nil
			and chosen5[1] == witnessed
			and string.find(note5, "sidecar%-witnessed %(session 3%)") ~= nil
		table.insert(results, {
			name = "sidecar-witnessed beats caller-supplied",
			expected = "sidecar",
			got = if sidecarWon then "sidecar" else "caller",
			ok = sidecarWon,
		})
		local chosen6, note6 = chooseTwinSource("HTML error page, not JSON", { callerForged })
		local fellOpen6 = chosen6 ~= nil
			and chosen6[1] == callerForged
			and string.find(note6, "caller%-supplied") ~= nil
		table.insert(results, {
			name = "malformed sidecar body falls open to caller-supplied",
			expected = "caller",
			got = if fellOpen6 then "caller" else "other",
			ok = fellOpen6,
		})
		local chosen7, note7 = chooseTwinSource(nil, { callerForged })
		local fellOpen7 = chosen7 ~= nil
			and chosen7[1] == callerForged
			and string.find(note7, "unreachable") ~= nil
		table.insert(results, {
			name = "unreachable sidecar (404 today) falls open to caller-supplied",
			expected = "caller",
			got = if fellOpen7 then "caller" else "other",
			ok = fellOpen7,
		})
	end
	-- tool_clip_current pure logic (grip-stamp staleness — the stale-clip saga check; the
	-- Anims/* attribute plumbing is exercised live via stampToolClips on a real Tool):
	do
		local OC: any = OracleChecks
		local stampNow = OC.gripStampOf(CFrame.new(0, 1.5, 0) * CFrame.Angles(math.rad(140), 0, 0))
		local stampOld = OC.gripStampOf(CFrame.new(0, 1.5, 0) * CFrame.Angles(math.rad(141), 0, 0))
		table.insert(results, {
			name = "grip stamp is rotation-sensitive (1 deg changes it)",
			expected = true,
			got = stampNow ~= stampOld,
			ok = stampNow ~= stampOld,
		})
		expect(
			"matching clip stamp passes",
			"PASS",
			OC.clipStampVerdict(stampNow, { { name = "use", stamp = stampNow } })
		)
		expect(
			"mismatched clip stamp fails (stale clip)",
			"FAIL",
			OC.clipStampVerdict(stampNow, { { name = "use", stamp = stampOld } })
		)
		expect(
			"unstamped clip is UNKNOWN (fail-open)",
			"UNKNOWN",
			OC.clipStampVerdict(stampNow, { { name = "use" } })
		)
		expect(
			"mismatch beats unstamped (a proven-stale clip FAILs)",
			"FAIL",
			OC.clipStampVerdict(stampNow, { { name = "idle" }, { name = "use", stamp = stampOld } })
		)
		expect("no clips at all is UNKNOWN", "UNKNOWN", OC.clipStampVerdict(stampNow, {}))
	end
	-- weapon-chain first-class (weapon-as-limb, 2026-07-11; hardened same-day after the
	-- review pass): a Forearm->RightHand BODY joint + a DEPTH-2 chain (Handle->SegA->SegB)
	-- inside a real Tool, a fabricated multi-keyframe clip, and negative rows for every
	-- honesty property — production weaponChildNames coupling, default unkeyed-chain
	-- escalation, all-channels require_chain, root-connectivity, MIXED arm, duplicates.
	do
		local chainRig = Instance.new("Model")
		chainRig.Name = "ChainRigFixture"
		chainRig.Parent = folder
		local function cpart(name: string, parent: Instance): Part
			local p = Instance.new("Part")
			p.Name = name
			p.Size = Vector3.new(1, 1, 1)
			p.Anchored = true
			p.Parent = parent
			return p
		end
		local function cjoint(name: string, p0: BasePart, p1: BasePart): Motor6D
			local m = Instance.new("Motor6D")
			m.Name = name
			m.Part0 = p0
			m.Part1 = p1
			m.Parent = p0
			return m
		end
		local forearm = cpart("Forearm", chainRig)
		local hand = cpart("RightHand", chainRig)
		local toolInst = Instance.new("Tool")
		toolInst.Name = "ChainTool"
		toolInst.Parent = chainRig
		local handle = cpart("Handle", toolInst)
		local segA = cpart("SegA", toolInst)
		local segB = cpart("SegB", toolInst)
		cjoint("RightWrist", forearm, hand) -- BODY joint: the census split must file it as body
		cjoint("AgentEditGrip", hand, handle)
		cjoint("SegA", handle, segA)
		cjoint("SegB", segA, segB)
		local jc = OracleChecks.run("joint_census", { rig = chainRig })
		local jcOk = jc.verdict == "PASS"
			and jc.magnitudes.weapon_motor6d == 3
			and jc.magnitudes.motor6d == 1
		table.insert(results, {
			name = "census splits weapon-chain joints from body joints (3 weapon / 1 body)",
			expected = "PASS w=3 b=1",
			got = jc.verdict
				.. " w="
				.. tostring(jc.magnitudes.weapon_motor6d)
				.. " b="
				.. tostring(jc.magnitudes.motor6d),
			ok = jcOk,
			reason = jc.reason,
		})
		-- couple the selftest to the PRODUCTION chain walk (not just the oracle's own BFS):
		-- add_keyframe {weapon=true} keys exactly what weaponChildNames returns
		local wnames = AnimationClip.weaponChildNames(chainRig)
		local wOk = #wnames == 3
			and wnames[1] == "Handle"
			and wnames[2] == "SegA"
			and wnames[3] == "SegB"
		table.insert(results, {
			name = "production weaponChildNames walks the depth-2 chain",
			expected = "Handle,SegA,SegB",
			got = table.concat(wnames, ","),
			ok = wOk,
		})
		-- fabricated clip rooted at the rig root (Forearm): Forearm > RightHand > Handle > SegA > SegB
		local saves = Instance.new("Folder")
		saves.Name = "AnimSaves"
		saves.Parent = chainRig
		local function mkpose(name: string, cf: CFrame, parent: Instance): Instance
			local p = Instance.new("Pose")
			p.Name = name
			p.CFrame = cf
			p.Parent = parent
			return p
		end
		local function mkclip(
			clipName: string,
			kfSpecs: { { handle: CFrame, segA: CFrame?, segB: CFrame?, strayA: CFrame? } }
		): KeyframeSequence
			local ks = Instance.new("KeyframeSequence")
			ks.Name = clipName
			ks.Parent = saves
			for i, spec in kfSpecs do
				local kf = Instance.new("Keyframe")
				local top = mkpose("Forearm", CFrame.identity, kf)
				local ph = mkpose("RightHand", CFrame.identity, top)
				local pHandle = mkpose("Handle", spec.handle, ph)
				if spec.segA ~= nil then
					local pA = mkpose("SegA", spec.segA :: CFrame, pHandle)
					if spec.segB ~= nil then
						mkpose("SegB", spec.segB :: CFrame, pA)
					end
				end
				if spec.strayA ~= nil then
					-- an UNROOTED subtree directly under the Keyframe: the Animator never
					-- applies it (top-level pose != rig root), so the check must ignore it
					local strayHandle = mkpose("Handle", CFrame.identity, kf)
					mkpose("SegA", spec.strayA :: CFrame, strayHandle)
				end
				kf.Time = (i - 1) * 0.5
				ks:AddKeyframe(kf)
			end
			return ks
		end
		local ks = mkclip("ChainClip", {
			{ handle = CFrame.identity, segA = CFrame.identity, segB = CFrame.identity },
			{
				handle = CFrame.Angles(math.rad(40), 0, 0),
				segA = CFrame.Angles(0, 0, math.rad(30)),
				segB = CFrame.Angles(0, 0, math.rad(20)),
			},
		})
		expect(
			"weapon_channel_of passes a fully-driven grip+chain (default)",
			"PASS",
			OracleChecks.run("weapon_channel_of", { rig = chainRig, clip = "ChainClip" })
		)
		local wc = OracleChecks.run(
			"weapon_channel_of",
			{ rig = chainRig, clip = "ChainClip", require_chain = true }
		)
		local wcOk = wc.verdict == "PASS"
			and wc.magnitudes.chain_joints == 2
			and math.abs((wc.magnitudes.chain_swept_deg or 0) - 30) < 1
		table.insert(results, {
			name = "require_chain passes with EVERY channel keyed (chain_joints=2, swept ~30)",
			expected = "PASS chain 30",
			got = wc.verdict .. " chain " .. tostring(wc.magnitudes.chain_swept_deg),
			ok = wcOk,
			reason = wc.reason,
		})
		-- freeze the segments (keyed but identity): idle clips are legitimate -> default PASS;
		-- require_chain (a strike contract) FAILs on zero sweep
		for _, kf in ks:GetKeyframes() do
			for _, d in (kf :: Keyframe):GetDescendants() do
				if d:IsA("Pose") and (d.Name == "SegA" or d.Name == "SegB") then
					d.CFrame = CFrame.identity
				end
			end
		end
		expect(
			"keyed-but-static chain passes the default contract (idle clips)",
			"PASS",
			OracleChecks.run("weapon_channel_of", { rig = chainRig, clip = "ChainClip" })
		)
		expect(
			"require_chain fails a static (zero-sweep) chain",
			"FAIL",
			OracleChecks.run(
				"weapon_channel_of",
				{ rig = chainRig, clip = "ChainClip", require_chain = true }
			)
		)
		-- partial keying: drop SegB poses entirely -> require_chain fails 1/2 channels
		for _, kf in ks:GetKeyframes() do
			local pB = (kf :: Keyframe):FindFirstChild("SegB", true)
			if pB ~= nil then
				pB:Destroy()
			end
		end
		-- restore SegA sweep so ONLY the partial-keying arm trips
		do
			local kfs = ks:GetKeyframes()
			local pA = (kfs[#kfs] :: Keyframe):FindFirstChild("SegA", true)
			if pA ~= nil and pA:IsA("Pose") then
				pA.CFrame = CFrame.Angles(0, 0, math.rad(30))
			end
		end
		expect(
			"require_chain fails a partially-keyed chain (1/2 channels)",
			"FAIL",
			OracleChecks.run(
				"weapon_channel_of",
				{ rig = chainRig, clip = "ChainClip", require_chain = true }
			)
		)
		-- unkeyed chain: drop SegA too -> the DEFAULT contract escalates (articulated weapon,
		-- chain never keyed = the forgot-weapon=true / regression defect class)
		for _, kf in ks:GetKeyframes() do
			local pA = (kf :: Keyframe):FindFirstChild("SegA", true)
			if pA ~= nil then
				pA:Destroy()
			end
		end
		expect(
			"DEFAULT fails an articulated weapon whose chain is never keyed",
			"FAIL",
			OracleChecks.run("weapon_channel_of", { rig = chainRig, clip = "ChainClip" })
		)
		-- root-connectivity: a stray unrooted subtree carrying big rotations must NOT satisfy
		-- the chain sweep (the Animator would never play it)
		mkclip("StrayClip", {
			{
				handle = CFrame.identity,
				segA = CFrame.identity,
				segB = CFrame.identity,
				strayA = CFrame.Angles(0, 0, math.rad(50)),
			},
			{
				handle = CFrame.Angles(math.rad(40), 0, 0),
				segA = CFrame.identity,
				segB = CFrame.identity,
				strayA = CFrame.Angles(0, 0, math.rad(-50)),
			},
		})
		expect(
			"an unrooted stray subtree cannot fake the chain sweep (require_chain)",
			"FAIL",
			OracleChecks.run(
				"weapon_channel_of",
				{ rig = chainRig, clip = "StrayClip", require_chain = true }
			)
		)
		-- MIXED arm: a weapon Motor6D chain + a body AnimationConstraint = the T-pose trap
		local ac = Instance.new("AnimationConstraint")
		ac.Parent = forearm
		expect(
			"census fails a MIXED weapon-Motor6D + AnimationConstraint rig",
			"FAIL",
			OracleChecks.run("joint_census", { rig = chainRig })
		)
		ac:Destroy()
		-- duplicate pose-channel name (a second SegA part): the Animator matches by part NAME,
		-- so this silently clobbers a channel — census must FAIL loudly
		local segDup = cpart("SegA", toolInst)
		cjoint("SegADup", segA, segDup)
		expect(
			"census fails duplicate pose-channel names",
			"FAIL",
			OracleChecks.run("joint_census", { rig = chainRig })
		)
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
OracleChecks.register(
	"__selftest",
	"EDIT_OK",
	"Builds fixtures and asserts expected verdicts; cleans up.",
	function(_args)
		local r = selftest()
		return {
			verdict = if r.ok then "PASS" else "FAIL",
			reason = if r.ok then nil else (r.failures .. " selftest rows failed"),
			magnitudes = r,
		}
	end
)

Oracle.descriptors = {
	{
		name = "oracle_check",
		description = "Run ONE named oracle check (deterministic measurement, ~50-token result with raw magnitudes). "
			.. "Checks: intersects{a,b}, penetration_depth{a,b,max_depth}, gap_between{a,b,max_gap}, "
			.. "alignment{target,dir,against,max_deg,length}, scale_ratio{target,expected,tolerance_frac}, "
			.. "mesh_persisted{target}, "
			.. "anchored_ok{target}, frame_consistent{target}, grip_sane{tool,rig}, tool_clip_current{tool}, "
			.. "joint_census{rig} (weapon-chain joints reported first-class; duplicate channel names FAIL), "
			.. "rig_channel_check{rig,clip}, clip_arc_of{rig,tool,clip,samples,min_sweep}, "
			.. "weapon_channel_of{rig,clip,min_swept_deg,require_chain} (an articulated weapon's UNKEYED "
			.. "chain FAILs by default; require_chain=true demands every channel keyed AND sweeping), "
			.. "clip_self_intersect{rig,tool,clip,samples,max_depth,max_blade_in_arm,max_blade_in_body}, "
			.. "capture_vantage{rig,tool,angles,min_visible_frac} (does each sign-off angle SHOW the weapon), "
			.. "clip_posture_sane{rig,clip,max_tilt_deg,allow_inverted} (does the BODY stay a body — every other clip check is joint-relative), __selftest{}. "
			.. "Verdicts: PASS|FAIL|UNKNOWN (UNKNOWN never counts as pass). Prefer these over captures for anything measurable.",
		inputSchema = {
			type = "object",
			properties = {
				check = { type = "string", description = "check name from the registry" },
				args = {
					type = "object",
					description = "check arguments (paths as dot-paths, e.g. game.StarterPack.Sword)",
				},
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
				rig = {
					type = "string",
					description = "optional dot-path to the rig (default workspace.AgentRig)",
				},
				clip = {
					type = "string",
					description = "clip name for the animation checks (default SwordSwing)",
				},
				allow_static_grip = {
					type = "boolean",
					description = "true for RETARGETED full-body clips (Kimodo/SOMA): the grip "
						.. "channel is legitimately static (the sword rides the arm) — "
						.. "weapon_channel_of skips its sweep bound. Leave unset for authored "
						.. "weapon-swing clips.",
				},
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
		run = function(input, context)
			local args = if type(input) == "table" then input else {}
			-- sidecar base for the trusted twin-witness fetch (the Playtest.luau config pattern);
			-- nil (no config) just means fail-open to caller-supplied twin_results.
			local sidecarBase: string? = nil
			if context ~= nil and context.config ~= nil then
				pcall(function()
					sidecarBase = context.config:getSidecarUrl()
				end)
			end
			local r = runSuite(
				tostring(args.family),
				tostring(args.target),
				if args.rig ~= nil then tostring(args.rig) else nil,
				if args.clip ~= nil then tostring(args.clip) else nil,
				if type(args.twin_results) == "table" then args.twin_results else nil,
				sidecarBase,
				args.allow_static_grip == true
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
			return encode({
				ok = true,
				family = frame.family,
				points = points,
				dirs = dirs,
				roles = roles,
				missing = frame.missing,
			}),
				false
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
			local summary, ok =
				OracleFrames.stamp(inst, if type(args.frame) == "table" then args.frame else {})
			summary.ok = ok
			return encode(summary), not ok
		end,
	},
}

return Oracle
