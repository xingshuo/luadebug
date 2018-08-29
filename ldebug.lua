local sformat = string.format
local tconcat = table.concat
local tinsert = table.insert
local tostring = tostring
local srep = string.rep


local stack_level --next cmd's counter
local in_hooking = false
local quit_debug = false
local hk_base_level = 6 --M.probe -> dispatch_input -> pcall -> dbg_cmd[xxx] -> debug_hook - > debug.sethook
local dbg_base_level = 4 --M.probe/_hook -> dispatch_input -> pcall -> dbg_cmd[xxx]

local cur_list_file
local cur_list_line
local last_list_line

local function list_source_codes(file, start_line, follow_line)
	if not start_line then
		if not last_list_line then
			start_line = cur_list_line
		else
			start_line = last_list_line + 1
		end
	end
	follow_line = follow_line or 4
	local end_line = start_line + follow_line - 1
	local line_num = 1
	for context in io.lines(file) do
		if line_num >= start_line then
			print(line_num,":",context)
			last_list_line = line_num
		end
		if line_num >= end_line then
			break
		end
		line_num = line_num + 1
	end
end

local function tostring_r(root)
	if type(root) ~= "table" then
		return tostring(root)
	end
	local cache = {  [root] = "." }
	local function _dump(t,space,name)
		local temp = {}
		for k,v in pairs(t) do
			local key = tostring(k)
			if cache[v] then
				tinsert(temp,"+" .. key .. " {" .. cache[v].."}")
			elseif type(v) == "table" then
				local new_key = name .. "." .. key
				cache[v] = new_key
				tinsert(temp,"+" .. key .. _dump(v,space .. (next(t,k) and "|" or " " ).. srep(" ",#key),new_key))
			else
				tinsert(temp,"+" .. key .. " [" .. tostring(v).."]")
			end
		end
		return tconcat(temp,"\n"..space)
	end
	return _dump(root, "","")
end

local function find_var(level, varname)
	local i = -1
	while true do --变参local
		local name,v = debug.getlocal(level, i)
		if name == nil then
			break
		end
		if varname == name then
			return v
		end
		i = i - 1
	end

	i = 1
	while true do --local
		local name,v = debug.getlocal(level, i)
		if name == nil then
			break
		end
		if varname == name then
			return v
		end
		i = i + 1
	end

	local info = debug.getinfo(level, "f")
	if not info then
		return
	end

	i = 1
	while true do --upvalue
		local name,v = debug.getupvalue(info.func, i)
		if name == nil then
			break
		end
		if varname == name then
			return v
		end
		i = i + 1
	end

	return _ENV[varname] --env
end

local function reply(s, ...)
	s = "gdb>" .. s
	print(sformat(s, ...))
end

local dbg_cmd = {}

local function dispatch_input()
	while true do
		local c = io.read()
		local cc,param
		if dbg_cmd[c] then
			cc = c
		elseif #c > 1 and dbg_cmd[c:sub(1,1)] then --p and f
			cc = c:sub(1,1)
			param = c:sub(3)
		end

		if cc then
			local ok, err = pcall(dbg_cmd[cc], param)
			if ok then
				if err then
					break
				end
			else
				reply ("cmd:[%s] err:%s", cc, err)
			end
		elseif c == "" then
			dbg_cmd.l(true)
		else
			reply ("unknow cmd:" .. c)
		end
	end
end

local function _hook(event)
	if stack_level then
		if event == "call" or event == "tail call" then
			stack_level = stack_level + 1
		elseif event == "return" then
			stack_level = stack_level - 1
		end
		if stack_level > 0 then
			return
		end
		stack_level = nil
	end

	if event ~= "line" then --like outside hook-func's return event
		return
	end

	local info = debug.getinfo(2, "Sln")
	reply ("%s:%s-> %s",info.short_src, info.currentline, info.name)
	cur_list_file = info.short_src
	cur_list_line = info.currentline

	in_hooking = true
	dispatch_input()

	if quit_debug then
		return
	end
	if not in_hooking then
		reply "Program continue running"
	end
end

local function debug_hook(back_level, db_cmd)
	debug.sethook(function ( event, line)
		if event == "call" or event == "tail call" then
			back_level = back_level + 1
		elseif event == "return" then
			back_level = back_level - 1
		end

		if back_level == 0 then
			if db_cmd == "next" then
				stack_level = 0
				debug.sethook(_hook, "crl")
			elseif db_cmd == "step" then
				debug.sethook(_hook, "l")
			end
		end
	end, "cr")
end


function dbg_cmd.h()
	reply [[
s : run step
n : run next
r : run until return
l : show below codes
p var : print var
c : continue to next probe
h : help message
bt : show stack frame
f level : show locals at level frame
q : quit interactive mode]]
end

function dbg_cmd.l(enter_cmd)
	if enter_cmd then
		list_source_codes(cur_list_file)
	else
		list_source_codes(cur_list_file, cur_list_line)
	end
end

function dbg_cmd.p( name )
	if not name or #name == 0 then
		reply "need a var name"
		return
	end
	local var = find_var(dbg_base_level + 2, name)
	reply(tostring_r(var))
end

function dbg_cmd.bt()
	local i = 1
	local tmp = {}
	while true do
		local info = debug.getinfo(dbg_base_level + i, "Sl")
		if info == nil then
			break
		end
		local source = sformat("[%d] %s:%d",i, info.short_src,info.currentline)
		tinsert(tmp, source)
		i = i + 1
	end
	reply(tconcat(tmp, "\n"))
end

function dbg_cmd.f(level)
	level = level or 1
	local s = dbg_base_level + level
	local info = debug.getinfo(s, "uf")
	local tmp = {}
	for i = 1, info.nparams do
		local name , value = debug.getlocal(s,i)
		tinsert(tmp, sformat("P %s : %s", name, tostring_r(value)))
	end
	if info.isvararg then
		local index = -1
		while true do
			local name,value = debug.getlocal(s,index)
			if name == nil then
				break
			end
			tinsert(tmp, sformat("P [%d] : %s", -index, tostring_r(value)))
			index = index - 1
		end
	end
	local index = info.nparams + 1
	while true do
		local name ,value = debug.getlocal(s,index)
		if name == nil then
			break
		end
		tinsert(tmp, sformat("L %s : %s", name, tostring_r(value)))
		index = index + 1
	end
	for i = 1, info.nups do
		local name, value = debug.getupvalue(info.func,i)
		if name ~= "_ENV" then
			tinsert(tmp, sformat("U %s : %s", name, tostring_r(value)))
		end
	end

	reply(table.concat(tmp, "\n"))
end

function dbg_cmd.n()
	if in_hooking then
		stack_level = 0
		debug.sethook(_hook, "crl")
	else
		debug_hook(hk_base_level, "next")
	end
	return true
end

function dbg_cmd.s()
	if in_hooking then
		debug.sethook(_hook,"l")
	else
		debug_hook(hk_base_level, "step")
	end
	return true
end

function dbg_cmd.q()
	in_hooking = false
	debug.sethook()
	quit_debug = true
	return true
end

function dbg_cmd.c()
	in_hooking = false
	debug.sethook()
	return true
end

function dbg_cmd.r()
	if in_hooking then
		debug_hook(1, "step")
	else
		debug_hook(1 + hk_base_level, "step")
	end
	return true
end

local M = {}

function M.probe()
	if quit_debug then
		return
	end
	local info = debug.getinfo(2, "Sln")
	reply ("%s:%s> %s",info.short_src, info.currentline, info.name)
	cur_list_file = info.short_src
	cur_list_line = info.currentline

	if in_hooking then
		debug.sethook()
		in_hooking = false
	end
	dispatch_input()
end

return M