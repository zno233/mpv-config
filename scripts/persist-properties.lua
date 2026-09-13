-- Script home: https://github.com/d87/mpv-persist-properties
local utils = require "mp.utils"
local msg = require "mp.msg"

local opts = {
    properties = "volume,sub-scale",
    config_path = "",
}
(require 'mp.options').read_options(opts, "persist_properties")

local function resolve_path(path)
    if path:find("~~") == 1 then
        local script_path = debug.getinfo(1).source:sub(2)
        local script_dir = script_path:match("^(.-)[^/\\]*$")
        local mpv_dir = script_dir:match("^(.+)scripts/?$")
        if not mpv_dir then mpv_dir = script_dir end
        path = path:gsub("^~~", mpv_dir)
    else
        path = path:gsub("^~", os.getenv('HOME') or '~')
    end
    return path
end

local PCONFIG
if opts.config_path ~= "" then
    PCONFIG = resolve_path(opts.config_path)
else
    local script_path = debug.getinfo(1).source:sub(2)
    local script_dir = script_path:match("^(.-)[^/\\]*$")
    local CONFIG_ROOT = script_dir:match("^(.+)scripts/?$") or script_dir
    if not utils.file_info(CONFIG_ROOT) then
        local mpv_conf_path = mp.find_config_file("scripts")
        local mpv_conf_dir = utils.split_path(mpv_conf_path)
        CONFIG_ROOT = mpv_conf_dir
    end
    PCONFIG = CONFIG_ROOT..'persistent_config.json'
end

local function split(input)
    local ret = {}
    for str in string.gmatch(input, "([^,]+)") do
        table.insert(ret, str)
    end
    return ret
end
local persisted_properties = split(opts.properties)

local print = function(...)
    -- return msg.log("info", ...)
end

-- print("Config Root is "..CONFIG_ROOT)

local isInitialized = false

local properties

local function load_config(file)
    local f = io.open(file, "r")
    if f then
        local jsonString = f:read()
        f:close()

        if jsonString == nil then
            return {}
        end

        local props = utils.parse_json(jsonString)
        if props then
            return props
        end
    end
    return {}
end

local function save_config(file, properties)
    local dir = file:match("^(.-)[^/\\]*$")
    if dir and dir ~= "" then
        os.execute('mkdir -p "' .. dir .. '"')
    end

    local serialized_props = utils.format_json(properties)

    local f = io.open(file, 'w+')
    if f then
        f:write(serialized_props)
        f:close()
    else
        msg.log("error", string.format("Couldn't open file: %s", file))
    end
end

local save_timer = nil
local got_unsaved_changed = false

local function onInitialLoad()
    properties = load_config(PCONFIG)

    for i, property in ipairs(persisted_properties) do
        local name = property
        local value = properties[name]
        if value ~= nil then
            mp.set_property_native(name, value)
        end
    end

    for i, property in ipairs(persisted_properties) do
        local property_type = nil
        mp.observe_property(property, property_type, function(name)
            if isInitialized then
                local value = mp.get_property_native(name)
                -- print(string.format("%s changed to %s at %s", name, value,  os.time()))

                properties[name] = value

                if save_timer then
                    save_timer:kill()
                end
                save_timer = mp.add_timeout(5, function()
                    save_config(PCONFIG, properties)
                    got_unsaved_changed = false
                end)
                got_unsaved_changed = true
            end
        end)
    end

    isInitialized = true
end

onInitialLoad()
mp.register_event("shutdown", function()
    if got_unsaved_changed then
        save_config(PCONFIG, properties)
    end
end)
