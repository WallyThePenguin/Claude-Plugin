--!strict
-- ExemplarEvidence: VISUAL evidence for evaluate's grader. Fetches a category's curated exemplar images
-- from the sidecar (GET /exemplars) and captures the subject build (reusing CaptureCore), returning
-- labeled Anthropic content blocks (text label + base64 image). PURE buildExemplarBlocks is unit-tested
-- (ExemplarEvidenceSpec); the impure fetchExemplars / captureSubject are live-verified. Every path
-- returns (nil, err) on failure so evaluate degrades to the text-only grade. Calibration anchoring: the
-- images make the bar concrete; the per-criterion rubric text stays the spine.

local HttpService = game:GetService("HttpService")

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local ExemplarEvidence = {}

-- ---- pure ----

-- Decode a /exemplars payload ({ exemplars = { {caption,tier,source,image}, ... } }) into alternating
-- text-label + image content blocks. Entries without an image are skipped. {} if none/malformed.
function ExemplarEvidence.buildExemplarBlocks(payload: any): { any }
	local blocks: { any } = {}
	if type(payload) ~= "table" or type(payload.exemplars) ~= "table" then
		return blocks
	end
	for _, ex in payload.exemplars do
		if type(ex) == "table" then
			local data = if type(ex.image) == "string"
				then (string.gsub(ex.image, "%s", ""))
				else ""
			if data ~= "" then
				local tier = if type(ex.tier) == "string" and ex.tier ~= ""
					then ex.tier
					else "reference"
				local caption = if type(ex.caption) == "string" then ex.caption else ""
				local source = if type(ex.source) == "string" and ex.source ~= ""
					then " (" .. ex.source .. ")"
					else ""
				table.insert(blocks, {
					type = "text",
					text = "EXEMPLAR [" .. tier .. "] — " .. caption .. source,
				})
				table.insert(blocks, {
					type = "image",
					source = { type = "base64", media_type = "image/png", data = data },
				})
			end
		end
	end
	return blocks
end

-- ---- impure ----

-- GET /exemplars?category=..&b64=1 and build the labeled image blocks. (nil, err) on any failure.
function ExemplarEvidence.fetchExemplars(category: string, config: any): ({ any }?, string?)
	if config == nil then
		return nil, "no config (sidecar url) available"
	end
	local url = config:getSidecarUrl()
		.. "/exemplars?b64=1&category="
		.. HttpService:UrlEncode(category)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		return nil, "could not reach the sidecar for exemplars: " .. tostring(res)
	end
	local response = res :: any
	if not response.Success then
		return nil, "sidecar /exemplars returned HTTP " .. tostring(response.StatusCode)
	end
	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okDecode then
		return nil, "could not decode the /exemplars response"
	end
	local blocks = ExemplarEvidence.buildExemplarBlocks(payload)
	if #blocks == 0 then
		return nil, "no exemplars for category '" .. category .. "'"
	end
	return blocks, nil
end

-- Frame + capture the subject (one beauty shot) -> one image block. (nil, err) on any failure. Reuses
-- CaptureCore (aabbOf + save/frame/capture/restore + sidecar fetch), like the `capture` tool.
function ExemplarEvidence.captureSubject(subject: Instance?, config: any): ({ any }?, string?)
	if config == nil then
		return nil, "no config (sidecar url) available"
	end
	if subject == nil then
		return nil, "no subject to capture"
	end
	local center, size = CaptureCore.aabbOf({ subject :: Instance })
	if center == nil or size == nil then
		return nil, "subject has no parts to frame (no BasePart found)"
	end
	local iso = CaptureCore.PRESETS.iso
	local saved = CaptureCore.saveCamera()
	local since = os.time() - 2
	local triggered = false
	local okAll = pcall(function()
		CaptureCore.setCamera(
			CaptureCore.frameCFrame(center :: Vector3, size :: Vector3, iso.yaw, iso.pitch, 1)
		)
		CaptureCore.settle(2)
		triggered = CaptureCore.triggerCapture()
	end)
	CaptureCore.restoreCamera(saved)
	if not okAll or not triggered then
		return nil, "could not capture the subject (camera restored)"
	end
	local blocks, err = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return nil, err
	end
	return blocks, nil
end

return ExemplarEvidence
