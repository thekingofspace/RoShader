local RunService = game:GetService("RunService")

export type Payload = any
export type OnApply = (target: Instance, payloads: {Payload}) -> ()
export type ComputeFn = (target: Instance, dt: number, ...any) -> Payload?

local Actor = script:GetActor()

export type Task = {
	id: string,
	target: Instance,
	priority: number,   -- Lower number = applied first within the same instance
	args: {any},
	compute: ComputeFn,
	onApply: OnApply,
}

local _tasks: {[string]: Task} = {}
local _staged: {[Instance]: {[string]: {Payload}}} = {}

local Manager = {}

local function stagePayload(task: Task, payload: Payload)
	local byInstance = _staged[task.target]
	if not byInstance then
		byInstance = {}
		_staged[task.target] = byInstance
	end
	local byTask = byInstance[task.id]
	if not byTask then
		byTask = {}
		byInstance[task.id] = byTask
	end
	table.insert(byTask, payload)
end

function Manager.AddTask(
	id: string,
	target: Instance,
	priority: number,
	compute: ComputeFn,
	onApply: OnApply,
	...: any
)
	_tasks[id] = {
		id       = id,
		target   = target,
		priority = priority,
		args     = { ... },
		compute  = compute,
		onApply  = onApply,
	}
end

function Manager.RemoveTask(id: string)
	local task_ = _tasks[id]
	if task_ then
		local byInstance = _staged[task_.target]
		if byInstance then
			byInstance[id] = nil
		end
	end
	_tasks[id] = nil
end

function Manager.RemoveAllTasksFor(target: Instance)
	for id, task_ in pairs(_tasks) do
		if task_.target == target then
			_tasks[id] = nil
		end
	end
	_staged[target] = nil
end

-- All fragments compute in parallel (desynchronized), then results are staged.
local function runCompute(dt: number)
	if Actor then
		task.desynchronize()
	end
	for _, t in pairs(_tasks) do
		if t.target.Parent then
			local payload = t.compute(t.target, dt, table.unpack(t.args))
			if payload ~= nil then
				stagePayload(t, payload)
			end
		end
	end
	if Actor then
		task.synchronize()
	end
end

-- Collect all pending task IDs for an instance, sort by priority, then apply in order.
local function flushApply()
	for instance, byTask in pairs(_staged) do
		if instance.Parent then

			-- Build an ordered list of tasks that have staged payloads
			local ordered: {Task} = {}
			for taskId, payloads in pairs(byTask) do
				local t = _tasks[taskId]
				if t and #payloads > 0 then
					table.insert(ordered, t)
				end
			end

			-- Sort ascending by priority (lower number = applied first)
			table.sort(ordered, function(a, b)
				return a.priority < b.priority
			end)

			-- Apply in priority order
			for _, t in ipairs(ordered) do
				local payloads = byTask[t.id]
				t.onApply(instance, payloads)
				table.clear(payloads)
			end

			_staged[instance] = nil
		end
	end
end

RunService:BindToRenderStep(
	"RunServiceManager",
	Enum.RenderPriority.First.Value,
	function(dt: number)
		runCompute(dt)
		flushApply()
	end
)

return Manager
