local RunService = game:GetService("RunService")

if RunService:IsClient() == true then
	script:WaitForChild("RunServiceLoader")
end

local RunManager = require("@self/RunServiceLoader")
local module = {}

export type FragmentAction = (shaderData: {[string]: any}, fragData: {[string]: any}, ...any) -> ()

export type FragmentConfig = {
	id: string,
	priority: number?,
	maintainOnDisable: boolean?,
	compute: (
		target: Instance,
		dt: number,
		data: {[string]: any},
		shaderData: {[string]: any}
	) -> {[string]: any}?,
	apply: (
		target: Instance,
		payload: {[string]: any},
		data: {[string]: any},
		shaderData: {[string]: any}
	) -> (),
	init: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> ())?,
	onEnabled: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> ())?,
	onDisabled: ((target: Instance, data: {[string]: any}, shaderData: {[string]: any}) -> ())?,
	onDestroy: ((shaderData: {[string]: any}, fragData: {[string]: any}) -> ())?,
	actions: {[string]: FragmentAction}?,
}

export type Fragment = {
	id: string,
	priority: number,
	active: boolean,
	_config: FragmentConfig,
	_data: {[string]: any},
	_actions: {[string]: FragmentAction},
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
	RunAction: (self: Shader, fragmentId: string, actionId: string, ...any) -> (),
	Destroy: (self: Shader) -> (),
}

local _shaders: {[Instance]: Shader} = {}
local _uidCounter = 0

local function nextUID(): string
	_uidCounter += 1
	return tostring(_uidCounter)
end

local function taskKey(shaderUID: string, fragmentId: string): string
	return `frag_{shaderUID}_{fragmentId}`
end

local ShaderMethods = {}
ShaderMethods.__index = ShaderMethods

function ShaderMethods:AddFragment(config: FragmentConfig): Fragment
	assert(not self.fragments[config.id], `Fragment '{config.id}' already exists on this shader.`)

	local frag: Fragment = {
		id       = config.id,
		priority = config.priority or 0,
		active   = true,
		_config  = config,
		_data    = {},
		_actions = config.actions or {},
	}

	self.fragments[config.id] = frag

	if config.init then
		local ok, err = pcall(config.init, self.instance, frag._data, self._data)
		if not ok then
			warn(`Fragment '{config.id}' init error: {err}`)
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
				shaderRef._data
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
				shaderRef._data
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

	if frag._config.onDestroy then
		local ok, err = pcall(frag._config.onDestroy, self._data, frag._data)
		if not ok then
			warn(`Fragment '{id}' onDestroy error: {err}`)
		end
	end

	self.fragments[id] = nil
end

function ShaderMethods:FlushFragment(id: string)
	local frag = self.fragments[id]
	if not frag then
		warn(`Fragment '{id}' not found.`)
		return
	end
	table.clear(frag._data)
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

-- Run a named action on a fragment, forwarding shaderData + fragData + any extra args
function ShaderMethods:RunAction(fragmentId: string, actionId: string, ...)
	local frag = self.fragments[fragmentId]
	if not frag then
		warn(`Fragment '{fragmentId}' not found.`)
		return
	end

	local action = frag._actions[actionId]
	if not action then
		warn(`Action '{actionId}' not found on fragment '{fragmentId}'.`)
		return
	end

	local ok, err = pcall(action, self._data, frag._data, ...)
	if not ok then
		warn(`Fragment '{fragmentId}' action '{actionId}' error: {err}`)
	end
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
