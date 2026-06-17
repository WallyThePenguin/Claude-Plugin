--!strict
-- Retry: the transient-error classification + capped-exponential-backoff send, shared by the parent
-- AgentLoop and the read-only Subagent runner. Policy (single source of truth): Overloaded / 429 /
-- 5xx / transport / the cold-proxy "unknown provider" race are RETRYABLE; the subscription
-- usage-window ("out of extra usage") is NOT (retrying re-reserves max_tokens and worsens it).

local Retry = {}

-- Worth retrying? Transient server/transport conditions, NOT the usage-window or a real client error.
function Retry.isTransient(res: any): boolean
	if res.kind == "transport" then
		return true
	end
	if res.kind == "http" then
		local status = res.status
		if status == 408 or status == 409 or status == 429 then
			return true
		end
		if status == 500 or status == 502 or status == 503 or status == 504 or status == 529 then
			return true
		end
		local msg = string.lower(tostring(res.message))
		if string.find(msg, "out of extra usage", 1, true) then
			return false
		end
		if string.find(msg, "overloaded", 1, true) then
			return true
		end
		if string.find(msg, "unknown provider for model", 1, true) then
			return true
		end
	end
	return false
end

-- sendMessage with capped exponential backoff on transient failures.
function Retry.sendWithRetry(
	anthropic: any,
	config: any,
	opts: any,
	emit: (string, any) -> (),
	cancelled: () -> boolean
): any
	local maxAttempts = config:getRetryMaxAttempts()
	local base = config:getRetryBaseDelay()
	local maxDelay = config:getRetryMaxDelay()
	local attempt = 0
	while true do
		attempt += 1
		local res = anthropic:sendMessage(opts)
		if res.ok then
			return res
		end
		if attempt >= maxAttempts or cancelled() or not Retry.isTransient(res) then
			return res
		end
		local delay = math.min(maxDelay, base * 2 ^ (attempt - 1))
		emit(
			"status",
			"transient error ("
				.. tostring(res.kind)
				.. ") - retrying in "
				.. string.format("%.1fs", delay)
		)
		task.wait(delay)
	end
end

return Retry
