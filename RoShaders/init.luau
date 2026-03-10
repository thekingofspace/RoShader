local RunService = game:GetService("RunService")

if RunService:IsClient() == true then
	script:WaitForChild("RunServiceLoader")
end

local RunManager = require("@self/RunServiceLoader")
local module = {}

export type FragmentConfig = {
	id: string,
	maintainOnDisable: boolean?,
	compute: (target: Instance, dt: number, data: {[string]: any}) -> {[string]: any}?,
	apply: (target: Instance, payload: {[string]: any}, data: {[string]: any}) -> {[string]: any},
	init: ((target: Instance, data: {[string]: any}) -> {Instance})?,
	onEnabled: ((target: Instance) -> ())?,
	onDisabled: ((target: Instance) -> ())?,
}

export type Fragment = {
	id: string,
	active: boolean,
	_config: FragmentConfig,
	_data: {[string]: any},
	_snapshot: {[string]: any},
	_snapshotted: {[string]: boolean},
	generated: {Instance},
}

export type Shader = {
	instance: Instance,
	_uid: string,
	fragments: {[string]: Fragment},
	AddFragment: (self: Shader, config: FragmentConfig) -> Fragment,
	RemoveFragment: (self: Shader, id: string) -> (),
	FlushFragment: (self: Shader, id: string) -> (),
	EnableFragment: (self: Shader, id: string) -> (),
	DisableFragment: (self: Shader, id: string, maintain: boolean?) -> (),
	WriteData: (self: Shader, fragmentId: string, key: string, value: any) -> (),
	ReadData: (self: Shader, fragmentId: string, key: string) -> any,
	GetGenerated: (self: Shader, fragmentId: string) -> {Instance},
	Destroy: (self: Shader) -> (),
}

local _shaders: {[Instance]: Shader} = {}
local _uidCounter = 0

local function nextUID(): string
	_uidCounter += 1
	return tostring(_uidCounter)
end

local function snapshotKeys(instance: Instance, keys: {[string]: any}, snapshot: {[string]: any}, snapshotted: {[string]: boolean})
	for prop in pairs(keys) do
		if not snapshotted[prop] then
			local ok, val = pcall(function() return (instance :: any)[prop] end)
			if ok then
				snapshot[prop] = val
				snapshotted[prop] = true
			end
		end
	end
end

local function restoreSnapshot(instance: Instance, snap: {[string]: any})
	for prop, val in pairs(snap) do
		pcall(function() (instance :: any)[prop] = val end)
	end
end

local function flushGenerated(frag: Fragment)
	for _, inst in ipairs(frag.generated) do
		if inst and inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(frag.generated)
end

local function taskKey(shaderUID: string, fragmentId: string): string
	return `frag_{shaderUID}_{fragmentId}`
end

local ShaderMethods = {}
ShaderMethods.__index = ShaderMethods

function ShaderMethods:AddFragment(config: FragmentConfig): Fragment
	assert(not self.fragments[config.id], `Fragment '{config.id}' already exists on this shader.`)

	local frag: Fragment = {
		id = config.id,
		active = true,
		_config = config,
		_data = {},
		_snapshot = {},
		_snapshotted = {},
		generated = {},
	}

	self.fragments[config.id] = frag

	if config.init then
		local ok, result = pcall(config.init, self.instance, frag._data)
		if ok and result then
			for _, inst in ipairs(result) do
				table.insert(frag.generated, inst)
			end
		else
			warn(`Fragment '{config.id}' init error: {result}`)
		end
	end

	local key = taskKey(self._uid, config.id)
	local shaderRef = self

	RunManager.AddTask(
		key,
		self.instance,

		function(target: Instance, dt: number)
			local f = shaderRef.fragments[config.id]
			if not f or not f.active then return nil end
			return f._config.compute(target, dt, f._data)
		end,

		function(target: Instance, payloads: {{[string]: any}})
			local f = shaderRef.fragments[config.id]
			if not f or not f.active then return end
			local latest = payloads[#payloads]
			if not latest then return end

			local written = f._config.apply(target, latest, f._data)
			if written then
				snapshotKeys(target, written, f._snapshot, f._snapshotted)
			end
		end
	)

	if config.onEnabled then
		config.onEnabled(self.instance)
	end

	return frag
end

function ShaderMethods:RemoveFragment(id: string)
	local frag = self.fragments[id]
	if not frag then return end

	RunManager.RemoveTask(taskKey(self._uid, id))

	if not frag._config.maintainOnDisable then
		restoreSnapshot(self.instance, frag._snapshot)
	end

	if frag._config.onDisabled then
		frag._config.onDisabled(self.instance)
	end

	flushGenerated(frag)

	self.fragments[id] = nil
end

function ShaderMethods:FlushFragment(id: string)
	local frag = self.fragments[id]
	if not frag then warn(`Fragment '{id}' not found.`); return end
	flushGenerated(frag)
end

function ShaderMethods:GetGenerated(id: string): {Instance}
	local frag = self.fragments[id]
	if not frag then warn(`Fragment '{id}' not found.`); return {} end
	return frag.generated
end

function ShaderMethods:EnableFragment(id: string)
	local frag = self.fragments[id]
	if not frag then warn(`Fragment '{id}' not found.`); return end
	if frag.active then return end

	for prop in pairs(frag._snapshotted) do
		local ok, val = pcall(function() return (self.instance :: any)[prop] end)
		if ok then frag._snapshot[prop] = val end
	end

	frag.active = true

	if frag._config.onEnabled then
		frag._config.onEnabled(self.instance)
	end
end

function ShaderMethods:DisableFragment(id: string, maintain: boolean?)
	local frag = self.fragments[id]
	if not frag then warn(`Fragment '{id}' not found.`); return end
	if not frag.active then return end

	frag.active = false
	table.clear(frag._data)

	local shouldMaintain = if maintain ~= nil then maintain else (frag._config.maintainOnDisable == true)
	if not shouldMaintain then
		restoreSnapshot(self.instance, frag._snapshot)
	end

	if frag._config.onDisabled then
		frag._config.onDisabled(self.instance)
	end
end

function ShaderMethods:WriteData(fragmentId: string, key: string, value: any)
	local frag = self.fragments[fragmentId]
	if not frag then warn(`Fragment '{fragmentId}' not found.`); return end
	frag._data[key] = value
end

function ShaderMethods:ReadData(fragmentId: string, key: string): any
	local frag = self.fragments[fragmentId]
	if not frag then return nil end
	return frag._data[key]
end

function ShaderMethods:Destroy()
	for id in pairs(self.fragments) do
		self:RemoveFragment(id)
	end
	_shaders[self.instance] = nil
end

function module.CreateShader(instance: Instance): Shader
	if _shaders[instance] then
		return _shaders[instance]
	end

	local shader = setmetatable({
		instance = instance,
		_uid = nextUID(),
		fragments = {},
	}, ShaderMethods) :: any

	_shaders[instance] = shader

	instance.AncestryChanged:Connect(function()
		if not instance.Parent and _shaders[instance] then
			shader:Destroy()
		end
	end)

	return shader
end

function module.GetShader(instance: Instance): Shader?
	return _shaders[instance]
end

function module.DestroyShader(instance: Instance)
	local shader = _shaders[instance]
	if shader then
		shader:Destroy()
	end
end

return module