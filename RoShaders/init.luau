local RunService = game:GetService("RunService")

if RunService:IsClient() == true then
	script:WaitForChild("RunServiceLoader")
end

local RunManager = require("@self/RunServiceLoader")
local module = {}

export type FragmentConfig = {
	id: string,
	priority: number?,
	maintainOnDisable: boolean?,
	compute: (
		target: Instance,
		dt: number,
		data: {[string]: any},
		shaderData: {[string]: any},
		generated: {Instance}
	) -> {[string]: any}?,
	apply: (
		target: Instance,
		payload: {[string]: any},
		data: {[string]: any},
		shaderData: {[string]: any},
		generated: {Instance}
	) -> (),
	init: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> {Instance})?,
	onEnabled: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> ())?,
	onDisabled: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> ())?,
}

export type Fragment = {
	id: string,
	priority: number,
	active: boolean,
	_config: FragmentConfig,
	_data: {[string]: any},
	generated: {Instance},
}

export type Shader = {
	instance: Instance,
	_uid: string,
	_data: {[string]: any},
	fragments: {[string]: Fragment},
	AddFragment: (self: Shader, config: FragmentConfig) -> Fragment,
	RemoveFragment: (self: Shader, id: string) -> (),
	FlushFragment: (self: Shader, id: string) -> (),
	EnableFragment: (self: Shader, id: string) -> (),
	DisableFragment: (self: Shader, id: string) -> (),
	WriteData: (self: Shader, fragmentId: string, key: string, value: any) -> (),
	ReadData: (self: Shader, fragmentId: string, key: string) -> any,
	WriteShaderData: (self: Shader, key: string, value: any) -> (),
	ReadShaderData: (self: Shader, key: string) -> any,
	GetGenerated: (self: Shader, fragmentId: string) -> {Instance},
	Destroy: (self: Shader) -> (),
}

local _shaders: {[Instance]: Shader} = {}
local _uidCounter = 0

local function nextUID(): string
	_uidCounter += 1
	return tostring(_uidCounter)
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
		id        = config.id,
		priority  = config.priority or 0,
		active    = true,
		_config   = config,
		_data     = {},
		generated = {},
	}

	self.fragments[config.id] = frag

	if config.init then
		local ok, result = pcall(config.init, self.instance, frag._data, self._data)
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
		frag.priority,

		function(target: Instance, dt: number)
			local f = shaderRef.fragments[config.id]
			if not f or not f.active then
				return nil
			end

			if not f._config.compute then
				return nil
			end

			return f._config.compute(
				target,
				dt,
				f._data,
				shaderRef._data,
				f.generated
			)
		end,

		function(target: Instance, payloads: {{[string]: any}})
			local f = shaderRef.fragments[config.id]
			if not f or not f.active then
				return
			end

			if not f._config.apply then
				return
			end

			local latest = payloads[#payloads]
			if not latest then
				return
			end

			f._config.apply(
				target,
				latest,
				f._data,
				shaderRef._data,
				f.generated
			)
		end
	)

	if config.onEnabled then
		config.onEnabled(self.instance, frag._data, self._data)
	end

	return frag
end

function ShaderMethods:RemoveFragment(id: string)
	local frag = self.fragments[id]
	if not frag then
		return
	end

	RunManager.RemoveTask(taskKey(self._uid, id))

	if frag._config.onDisabled then
		frag._config.onDisabled(self.instance, frag._data, self._data)
	end

	flushGenerated(frag)
	self.fragments[id] = nil
end

function ShaderMethods:FlushFragment(id: string)
	local frag = self.fragments[id]
	if not frag then
		warn(`Fragment '{id}' not found.`)
		return
	end
	table.clear(frag._data)
	flushGenerated(frag)
end

function ShaderMethods:GetGenerated(id: string): {Instance}
	local frag = self.fragments[id]
	if not frag then
		return {}
	end
	return frag.generated
end

function ShaderMethods:EnableFragment(id: string)
	local frag = self.fragments[id]
	if not frag then
		warn(`Fragment '{id}' not found.`)
		return
	end
	if frag.active then
		return
	end

	frag.active = true

	if frag._config.onEnabled then
		frag._config.onEnabled(self.instance, frag._data, self._data)
	end
end

function ShaderMethods:DisableFragment(id: string)
	local frag = self.fragments[id]
	if not frag then
		warn(`Fragment '{id}' not found.`)
		return
	end
	if not frag.active then
		return
	end

	frag.active = false

	if frag._config.onDisabled then
		frag._config.onDisabled(self.instance, frag._data, self._data)
	end
end

function ShaderMethods:WriteData(fragmentId: string, key: string, value: any)
	local frag = self.fragments[fragmentId]
	if not frag then
		warn(`Fragment '{fragmentId}' not found.`)
		return
	end
	frag._data[key] = value
end

function ShaderMethods:ReadData(fragmentId: string, key: string): any
	local frag = self.fragments[fragmentId]
	if not frag then
		return nil
	end
	return frag._data[key]
end

function ShaderMethods:WriteShaderData(key: string, value: any)
	self._data[key] = value
end

function ShaderMethods:ReadShaderData(key: string): any
	return self._data[key]
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
		instance  = instance,
		_uid      = nextUID(),
		_data     = {},
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
