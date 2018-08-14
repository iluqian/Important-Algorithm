
local cjson = require("cjson")
local uci = require("luci.model.uci").cursor()
local exec = luci.util.uciexec
local fork_exec = luci.util.fork_exec

module("luci.controller.ac.multiwan", package.seeall)
function index()
	entry({"ac", "multiwan"}, alias("ac", "multiwan", "global"))
	entry({"ac", "multiwan", "global"}, alias("ac", "multiwan", "global", "load"))
	entry({"ac", "multiwan", "global", "load"}, call("action_gload")).leaf = true
	entry({"ac", "multiwan", "global", "edit"}, call("action_gedit")).leaf = true
	entry({"ac", "multiwan", "global", "networks_load"}, call("networks_load")).leaf = true
	
	entry({"ac", "multiwan", "interface"}, alias("ac", "multiwan", "interface", "load"))
	entry({"ac", "multiwan", "interface", "load"}, call("interface_load")).leaf = true
	entry({"ac", "multiwan", "interface", "loadbyid"}, call("interface_loadbyid")).leaf = true
	entry({"ac", "multiwan", "interface", "add"}, call("interface_add")).leaf = true
	entry({"ac", "multiwan", "interface", "delete"}, call("interface_delete")).leaf = true
	entry({"ac", "multiwan", "interface", "edit"}, call("interface_edit")).leaf = true
	
	entry({"ac", "multiwan", "rule"}, alias("ac", "multiwan", "rule", "load"))
	entry({"ac", "multiwan", "rule", "load"}, call("rule_load")).leaf = true
	entry({"ac", "multiwan", "rule", "loadbyid"}, call("rule_loadbyid")).leaf = true
	entry({"ac", "multiwan", "rule", "add"}, call("rule_add")).leaf = true
	entry({"ac", "multiwan", "rule", "delete"}, call("rule_delete")).leaf = true
	entry({"ac", "multiwan", "rule", "edit"}, call("rule_edit")).leaf = true
	entry({"ac", "multiwan", "rule", "knownips_load"}, call("knownips_load")).leaf = true
end

--
---多wan口全局配置
--
function action_gload()
	local arr = {}
	arr.enabled = exec("uci get multiwan.config.enabled")
	arr.default_route = exec("uci get multiwan.config.default_route")
	luci.http.write('[' .. cjson.encode(arr) .. ']')
end

function action_gedit()
	local formvalue = luci.http.formvalue()
	exec("uci set multiwan.config.default_route=" .. formvalue.default_route)
	if formvalue.enabled == '0' then
		fork_exec("/etc/init.d/multiwan stop")
		exec("uci set multiwan.config.enabled=" .. formvalue.enabled)
		fork_exec("/etc/init.d/network reload")
	else
		exec("uci set multiwan.config.enabled=" .. formvalue.enabled)
		fork_exec("/etc/init.d/multiwan reload")
	end
	exec("uci commit multiwan")
	luci.http.write("1")
end

function networks_load()
	local arr = {}
	uci:foreach("network", "interface", function(s)
		if s['.name'] ~= "loopback" then
			table.insert(arr, {value=s['.name'], text=s['.name']})
		end
	end)
	luci.http.write_json(arr)
end

--
---多wan接口
--
local itbl = {'failover_to', 'icmp_hosts', 'dns', 'health_interval', 'timeout', 'health_fail_retries', 'health_recovery_retries', 'weight'}
function interface_load()
	local formvalue = luci.http.formvalue()
	local total = 0
	local tbl = {}
	local _start = tonumber(formvalue.start)
	local _end = _start + formvalue.limit
	uci:foreach("multiwan", "interface", function(s)
		if total >= _start and total < _end then
			local arr = {}
			for _, v in pairs(itbl) do
				arr[v] = s[v]
			end
			arr.name = s['.name']
			arr.index = s['.index']
			table.insert(tbl, arr)
		end
		total = total + 1
	end)
	luci.http.write('{totalCount:' .. total .. ',data:' .. cjson.encode(tbl) ..'}')
end

function interface_loadbyid()
	local name = luci.http.formvalue('name')
	local arr = {}
	arr.name = name
	for _, v in pairs(itbl) do
		arr[v] = exec("uci get multiwan." .. name .. "." .. v)
	end
	arr.index = "0"
	luci.http.write_json(arr)
end

function interface_add()
	local formvalue = luci.http.formvalue()
	if exec("uci get multiwan." .. formvalue.name) ~= "" then
		luci.http.write("0")
		return
	end
	exec("uci add multiwan interface")
	exec("uci rename multiwan.@interface[-1]=" .. formvalue.name)
	for _, v in pairs(itbl) do
		exec("uci set multiwan." .. formvalue.name .. "." .. v .. "=" .. formvalue[v])
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

function interface_delete()
	local names = luci.util.split(luci.http.formvalue('names'), ",")
	for _, v in pairs(names) do
		exec("uci delete multiwan." .. v)
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

function interface_edit()
	local formvalue = luci.http.formvalue()
	for _, v in pairs(itbl) do
		exec("uci set multiwan." .. formvalue.name .. "." .. v .. "=" .. formvalue[v])
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

--
---多wan流量规则
--
local rtbl = {'src', 'dst', 'proto', 'ports', 'wanrule'}
function rule_load()
	local formvalue = luci.http.formvalue()
	local total = 0
	local tbl = {}
	local _start = tonumber(formvalue.start)
	local _end = _start + formvalue.limit - 1
	uci:foreach("multiwan", "mwanfw", function(s) total = total + 1 end)
	
	for i = _start, _end do
		if exec("uci get multiwan.@mwanfw[" .. i .. "]") == "" then
			break
		end
		local arr = {}
		for _, v in pairs(rtbl) do
			arr[v] = exec("uci get multiwan.@mwanfw[" .. i .. "]." .. v)
			if arr[v] == "" then
				arr[v] = "all"
			end
		end
		arr.index = i
		table.insert(tbl, arr)
	end
	luci.http.write('{totalCount:' .. total .. ',data:' .. cjson.encode(tbl) ..'}')
end

function rule_loadbyid()
	local index = luci.http.formvalue('index')
	local arr = {}
	arr.index = index
	for _, v in pairs(rtbl) do
		arr[v] = exec("uci get multiwan.@mwanfw[" .. index .. "]." .. v)
		if arr[v] == "" then
			arr[v] = "all"
		end
	end
	luci.http.write_json(arr)
end

function rule_add()
	local formvalue = luci.http.formvalue()
	exec("uci add multiwan mwanfw")
	for _, v in pairs(rtbl) do
		if formvalue[v] == "all" then
			formvalue[v] = ""
		end
		exec("uci set multiwan.@mwanfw[-1]." .. v .. "=" .. formvalue[v])
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

function rule_delete()
	local del = luci.util.split(luci.http.formvalue('index'), ",")
	table.sort(del)
	for i = 1, #del do
		exec("uci delete multiwan.@mwanfw[" .. del[i] .. "]")
		for i = i+1, #del do
			del[i] = del[i] - 1
		end
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

function rule_edit()
	local formvalue = luci.http.formvalue()
	for _, v in pairs(rtbl) do
		if formvalue[v] == "all" then
			formvalue[v] = ""
		end
		exec("uci set multiwan.@mwanfw[" .. formvalue.index .. "]." .. v .. "=" .. formvalue[v])
	end
	exec("uci commit multiwan")
	fork_exec("/etc/init.d/multiwan reload")
	luci.http.write("1")
end

function knownips_load()
	local arr = {}
	for _, v in pairs(luci.sys.net.arptable()) do
		table.insert(arr, {value=v['IP address'], text=v['IP address']})
	end
	luci.http.write_json(arr)
end