local ldebug = require "ldebug"

local aa = 10
local bb = 20
local cc = 8

function abc(x, y)
	local z = x + y
	ldebug.probe()
	local w = z + 100
	return z
end

function ijk(a, b, ...)
	local c = a * b
	print(...)
	return c
end

function efg()
	local a = 10
	ldebug.probe()
	local b = 20
	local s = ijk(cc, b)
	print("ijk return:", s)
end

abc(aa, bb)

efg()