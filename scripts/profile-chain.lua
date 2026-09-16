--[[ profile-chain.lua - Profile 触发链条脚本 (mpv)
功能：定义 profile 触发链，链头触发时自动应用后续 profile。
支持 profile-cond 条件评估：有条件的 profile 需要条件满足才应用。

配置文件：script-opts/profile-chain.conf
格式：
  链头=profile1,profile2
  链头.trigger=property1,property2

示例：
  Base=SD,Deband,HDR
  Base.trigger=video-params/w,video-params/h

触发方式：
  1. file-loaded 自动触发 Base 链
  2. observe property 变化触发对应链
  3. script-message 手动触发：script-message profile-chain Base
--]]

local mp = require "mp"
local msg = require "mp.msg"

local chains = {}
local triggers = {}
local profile_conds = {}

local function load_profile_conds()
    local conf_path = mp.command_native({"expand-path", "~~/profiles.conf"})
    local f = io.open(conf_path, "r")
    if not f then return end

    local current_profile = nil
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        local profile_name = line:match("^%[(.+)%]$")
        if profile_name then
            current_profile = profile_name
        end
        if current_profile then
            local cond = line:match("^profile%-cond%=(.+)$")
            if cond then
                profile_conds[current_profile] = cond
            end
        end
    end

    f:close()
    msg.info("Loaded " .. tostring(#profile_conds) .. " profile conditions")
end

local function eval_cond(cond)
    if not cond or cond == "" then return true end

    local env = {}

    env.get = function(prop)
        local val = mp.get_property(prop)
        if val == nil then return nil end
        local num = tonumber(val)
        if num then return num end
        if val == "yes" then return true end
        if val == "no" then return false end
        return val
    end

    env.p = setmetatable({}, {
        __index = function(_, key)
            local val = mp.get_property("p." .. key)
            if val == nil then return nil end
            local num = tonumber(val)
            if num then return num end
            if val == "yes" then return true end
            if val == "no" then return false end
            return val
        end
    })

    env.path = mp.get_property("path") or ""
    env.filename = mp.get_property("filename") or ""
    env.vid = mp.get_property("vid") or 0
    env.aid = mp.get_property("aid") or 0
    env.sid = mp.get_property("sid") or 0
    env.pause = mp.get_property("bool-pause") == "yes"
    env.idle_active = mp.get_property("idle-active") == "yes"
    env.platform = mp.get_property("platform") or ""
    env.window_maximized = mp.get_property("window-maximized") == "yes"
    env.window_minimized = mp.get_property("window-minimized") == "yes"

    local func, err = load("return " .. cond, "profile-cond", "t", env)
    if not func then
        msg.warn("Failed to compile condition: " .. cond .. " (" .. tostring(err) .. ")")
        return false
    end

    local ok, result = pcall(func)
    if not ok then
        msg.warn("Failed to evaluate condition: " .. cond .. " (" .. tostring(result) .. ")")
        return false
    end

    return result == true
end

local function load_config()
    local conf_path = mp.command_native({"expand-path", "~~/script-opts/profile-chain.conf"})
    local f = io.open(conf_path, "r")
    if not f then return end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local head, trigger_str = line:match("^(%S+%.trigger)%s*=%s*(.+)$")
            if head and trigger_str then
                local chain_head = head:match("^(.+)%.trigger$")
                local props = {}
                for prop in trigger_str:gmatch("[^,]+") do
                    prop = prop:match("^%s*(.-)%s*$")
                    if prop ~= "" then props[#props + 1] = prop end
                end
                triggers[chain_head] = props
            else
                local chain_head, rest = line:match("^(%S+)%s*=%s*(.+)$")
                if chain_head and rest then
                    local chain = {}
                    for name in rest:gmatch("[^,]+") do
                        name = name:match("^%s*(.-)%s*$")
                        if name ~= "" then chain[#chain + 1] = name end
                    end
                    chains[chain_head] = chain
                end
            end
        end
    end

    f:close()
end

local function trigger_chain(head)
    local chain = chains[head]
    if not chain then return end

    for _, name in ipairs(chain) do
        local cond = profile_conds[name]
        if cond then
            if eval_cond(cond) then
                mp.commandv("apply-profile", name)
                msg.info("chain apply (cond true): " .. name)
            else
                msg.info("chain skip (cond false): " .. name)
            end
        else
            mp.commandv("apply-profile", name)
            msg.info("chain apply (no cond): " .. name)
        end
    end
end

local debounce = {}

local function trigger_chain_debounce(head)
    if debounce[head] then debounce[head]:kill() end
    debounce[head] = mp.add_timeout(0.1, function()
        debounce[head] = nil
        trigger_chain(head)
    end)
end

load_profile_conds()
load_config()

for head, props in pairs(triggers) do
    for _, prop in ipairs(props) do
        mp.observe_property(prop, "native", function()
            trigger_chain_debounce(head)
        end)
    end
end

mp.register_event("file-loaded", function()
    mp.add_timeout(0.1, function()
        trigger_chain("Base")
    end)
end)

mp.register_script_message("profile-chain", function(head)
    trigger_chain(head)
end)
