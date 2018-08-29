local ldebug = require "ldebug"

local a = {1,2,3,p={x=1,y=2}}
local b = 1

local function test()
	b = b + 1
end

function f(a,...)
	local i = 0
	local j = 10
	while true do
		ldebug.probe()
		i = i + 1
		j = 3
		ldebug.probe()
		test()
		if i > j then
			break
		end
	end
end

f(1,2,3)