--[[ profile-chain.lua - Profile 触发链条脚本 (mpv)
统一的 profile 触发系统，支持多种触发方式：
1. property 观察：属性变化时触发链
2. 内容检测：根据路径/文件名/标题/音频语言检测内容类型，触发对应链
3. file-loaded：每次加载文件自动触发 Base 链
4. script-message：手动触发指定链

配置文件：script-opts/profile-chain.conf
--]]

local mp = require "mp"
local msg = require "mp.msg"

local chains = {}
local property_triggers = {}
local profile_conds = {}
local detect_rules = {}
local detect_global_needs = {}

local detect_opts = {
    mode = "anime",
    default_profile = "",
    show_osd = true,
    osd_duration = 1500,
    show_no_match = false,
    max_rules = 10,
    path_depth = 0,
}

local function split(str, sep)
    local result = {}
    if not str or str == "" then return result end
    for match in (str .. sep):gmatch("(.-)" .. sep) do
        local trimmed = match:match("^%s*(.-)%s*$")
        if trimmed ~= "" then result[#result + 1] = trimmed:lower() end
    end
    return result
end

local function pattern_escape(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local sep_pat = "[%._%-%[%] ]"

local function compile_keywords(list)
    local compiled = {}
    for i, kw in ipairs(list) do
        local is_regex = kw:sub(1, 3) == "re:"
        local raw = is_regex and kw:sub(4) or kw
        compiled[i] = {
            raw = raw,
            esc = is_regex and raw or pattern_escape(raw),
            is_regex = is_regex,
            is_word = not is_regex and kw:match("^[%w_]+$") ~= nil,
        }
    end
    return compiled
end

local function word_match(str, kw)
    return str == kw.raw or
        str:find("^" .. kw.esc .. sep_pat) ~= nil or
        str:find(sep_pat .. kw.esc .. "$") ~= nil or
        str:find(sep_pat .. kw.esc .. sep_pat) ~= nil
end

local function match_path(path, keywords)
    if not path or path == "" or #keywords == 0 then return false end
    local lower = path:lower()
    local depth = detect_opts.path_depth
    local segments = {}
    for seg in lower:gmatch("[^/]+") do
        segments[#segments + 1] = seg
    end
    local start = 1
    if depth > 0 and #segments > depth then
        start = #segments - depth + 1
    end
    for i = start, #segments do
        local seg = segments[i]
        for _, kw in ipairs(keywords) do
            if kw.is_regex then
                if seg:find(kw.esc) then return true end
            elseif word_match(seg, kw) then
                return true
            end
        end
    end
    return false
end

local function match_name(name, keywords)
    if not name or name == "" or #keywords == 0 then return false end
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if kw.is_regex then
            if lower:find(kw.esc) then return true end
        elseif kw.is_word then
            if word_match(lower, kw) then return true end
        else
            if lower:find(kw.raw, 1, true) then return true end
        end
    end
    return false
end

local function match_lang(audio_lang, languages)
    if not audio_lang or audio_lang == "" or #languages == 0 then return false end
    local lower = audio_lang:lower()
    for _, lang in ipairs(languages) do
        if lower == lang then return true end
    end
    return false
end

local parse_or, parse_and, parse_unary, parse_atom
local parse_ok = true

parse_atom = function(expr, pos)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    if pos.i <= #expr and expr:sub(pos.i, pos.i) == "(" then
        pos.i = pos.i + 1
        local node = parse_or(expr, pos)
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
        if pos.i <= #expr and expr:sub(pos.i, pos.i) == ")" then
            pos.i = pos.i + 1
        else
            msg.warn("syntax error: missing ')'")
            parse_ok = false
        end
        return node
    end
    local word = ""
    while pos.i <= #expr do
        local c = expr:sub(pos.i, pos.i)
        if c == " " or c == ")" or c == "&" or c == "|" or c == "!" then break end
        word = word .. c
        pos.i = pos.i + 1
    end
    word = word:lower()
    if word == "" then
        msg.warn("syntax error: operator missing operand")
        parse_ok = false
        return { type = "const", value = false }
    elseif word == "title" or word == "name" or word == "path" or word == "audio" then
        return { type = "var", name = word }
    else
        msg.warn("syntax error: unknown variable '" .. word .. "'")
        return { type = "const", value = false }
    end
end

parse_unary = function(expr, pos)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    if pos.i <= #expr and expr:sub(pos.i, pos.i) == "!" then
        pos.i = pos.i + 1
        local child = parse_unary(expr, pos)
        if child.type == "const" and not child.value and not parse_ok then
            return child
        end
        return { type = "not", child = child }
    end
    return parse_atom(expr, pos)
end

parse_and = function(expr, pos)
    local left = parse_unary(expr, pos)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == "&" do
        pos.i = pos.i + 1
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
        if pos.i > #expr or expr:sub(pos.i, pos.i) == "&" or expr:sub(pos.i, pos.i + 1) == "||" then
            msg.warn("syntax error: '&' missing right operand")
            parse_ok = false
            break
        end
        local right = parse_unary(expr, pos)
        left = { type = "and", left = left, right = right }
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    end
    return left
end

parse_or = function(expr, pos)
    local left = parse_and(expr, pos)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    while pos.i <= #expr - 1 and expr:sub(pos.i, pos.i + 1) == "||" do
        pos.i = pos.i + 2
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
        if pos.i > #expr or expr:sub(pos.i, pos.i) == "&" or expr:sub(pos.i, pos.i + 1) == "||" then
            msg.warn("syntax error: '||' missing right operand")
            parse_ok = false
            break
        end
        local right = parse_and(expr, pos)
        left = { type = "or", left = left, right = right }
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    end
    return left
end

local function parse_expr(expr)
    if not expr or expr == "" then return { type = "const", value = false } end
    parse_ok = true
    local pos = { i = 1 }
    local ast = parse_or(expr, pos)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    if pos.i <= #expr then
        msg.warn("syntax error: unexpected characters in '" .. expr .. "'")
        parse_ok = false
    end
    return ast
end

local function eval_ast(node, nm, tm, pm, lm)
    local t = node.type
    if t == "var" then
        local name = node.name
        if name == "title" then return tm
        elseif name == "name" then return nm
        elseif name == "path" then return pm
        else return lm end
    elseif t == "and" then
        return eval_ast(node.left, nm, tm, pm, lm) and eval_ast(node.right, nm, tm, pm, lm)
    elseif t == "or" then
        return eval_ast(node.left, nm, tm, pm, lm) or eval_ast(node.right, nm, tm, pm, lm)
    elseif t == "not" then
        return not eval_ast(node.child, nm, tm, pm, lm)
    else
        return node.value
    end
end

local function collect_needs(node, needs)
    local t = node.type
    if t == "var" then
        needs[node.name] = true
    elseif t == "and" or t == "or" then
        collect_needs(node.left, needs)
        collect_needs(node.right, needs)
    elseif t == "not" then
        collect_needs(node.child, needs)
    end
end

local function eval_cond(cond)
    if not cond or cond == "" then return true end
    local env = {}
    env.get = function(prop)
        local val = mp.get_property(prop)
        if val == nil then return 0 end
        local num = tonumber(val)
        if num then return num end
        if val == "yes" then return true end
        if val == "no" then return false end
        return val
    end
    setmetatable(env, { __index = function(_, key)
        local val = mp.get_property(key)
        if val == nil then return 0 end
        local num = tonumber(val)
        if num then return num end
        if val == "yes" then return true end
        if val == "no" then return false end
        return val
    end })
    env.p = setmetatable({}, {
        __index = function(_, key)
            local val = mp.get_property("p." .. key)
            if val == nil then return 0 end
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
    local w = mp.get_property("width")
    env.width = w and tonumber(w) or 0
    local h = mp.get_property("height")
    env.height = h and tonumber(h) or 0
    local va = mp.get_property("video-aspect")
    env.video_aspect = va and tonumber(va) or 0
    local vp = mp.get_property("video-params/par")
    env.video_par = vp and tonumber(vp) or 0
    local df = mp.get_property("display-fps")
    env.display_fps = df and tonumber(df) or 0
    local cf = mp.get_property("container-fps")
    env.container_fps = cf and tonumber(cf) or 0
    local ef = mp.get_property("estimated-vf-fps")
    env.estimated_vf_fps = ef and tonumber(ef) or 0
    env.current_vo = mp.get_property("current-vo") or ""
    local func, err = load("return " .. cond, "profile-cond", "t", env)
    if not func then
        msg.warn("condition compile failed: " .. cond .. " (" .. tostring(err) .. ")")
        return false
    end
    local ok, result = pcall(func)
    if not ok then
        msg.warn("condition eval failed: " .. cond .. " (" .. tostring(result) .. ")")
        return false
    end
    return result == true
end

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

local detected = false
local detect_timer = nil

local function do_detect()
    if detected or #detect_rules == 0 then return end
    local path = detect_global_needs.path and (mp.get_property("path") or "") or ""
    local name = detect_global_needs.name and (mp.get_property("filename") or "") or ""
    local title = detect_global_needs.title and (mp.get_property("metadata/title") or "") or ""
    local lang = detect_global_needs.audio and (mp.get_property("current-tracks/audio/lang") or "") or ""
    for _, rule in ipairs(detect_rules) do
        local needs = rule.needs
        local nm = needs.name and match_name(name, rule.keywords) or false
        local tm = needs.title and match_name(title, rule.keywords) or false
        local pm = needs.path and match_path(path, rule.keywords) or false
        local lm = needs.audio and match_lang(lang, rule.languages) or false
        if eval_ast(rule.ast, nm, tm, pm, lm) then
            detected = true
            trigger_chain(rule.chain_head)
            msg.info("detect triggered: " .. rule.chain_head .. " (" .. rule.name .. ")")
            if detect_opts.show_osd then
                mp.osd_message("auto: " .. rule.name, detect_opts.osd_duration / 1000)
            end
            return
        end
    end
    detected = true
    if detect_opts.default_profile and detect_opts.default_profile ~= "" then
        trigger_chain(detect_opts.default_profile)
        msg.info("detect default: " .. detect_opts.default_profile)
        if detect_opts.show_osd then
            mp.osd_message("default", detect_opts.osd_duration / 1000)
        end
    elseif detect_opts.show_no_match then
        mp.osd_message("no match", detect_opts.osd_duration / 1000)
    end
end

local function load_config()
    local conf_path = mp.command_native({"expand-path", "~~/script-opts/profile-chain.conf"})
    local f = io.open(conf_path, "r")
    if not f then return end
    local section = "chain"
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
        elseif line == "[detect]" then
            section = "detect"
        elseif line:match("^%[") then
            section = "other"
        elseif section == "chain" then
            local head, trigger_str = line:match("^(%S+%.trigger)%s*=%s*(.+)$")
            if head and trigger_str then
                local chain_head = head:match("^(.+)%.trigger$")
                local props = {}
                for prop in trigger_str:gmatch("[^,]+") do
                    prop = prop:match("^%s*(.-)%s*$")
                    if prop ~= "" then props[#props + 1] = prop end
                end
                property_triggers[chain_head] = props
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
        elseif section == "detect" then
            local key, val = line:match("^(%S+)%s*=%s*(.-)%s*$")
            if key and val then
                if key == "mode" then
                    detect_opts.mode = val
                elseif key == "default" then
                    detect_opts.default_profile = val
                elseif key == "show_osd" then
                    detect_opts.show_osd = val == "yes"
                elseif key == "osd_duration" then
                    detect_opts.osd_duration = tonumber(val) or 1500
                elseif key == "show_no_match" then
                    detect_opts.show_no_match = val == "yes"
                elseif key == "max_rules" then
                    detect_opts.max_rules = tonumber(val) or 10
                elseif key == "path_depth" then
                    detect_opts.path_depth = tonumber(val) or 0
                else
                    detect_opts[key] = val
                end
            end
        end
    end
    f:close()
end

local function load_detect_rules()
    local modes = split(detect_opts.mode, ",")
    local function add_rule(name, prefix)
        local chain_head = detect_opts[prefix .. "profile"]
        if not chain_head or chain_head == "" then
            if name and name ~= "" then
                msg.warn("detect rule '" .. name .. "' missing profile, skipped")
            end
            return
        end
        local match_expr = detect_opts[prefix .. "match"] or "path"
        parse_ok = true
        local ast = parse_expr(match_expr)
        if not parse_ok then
            msg.warn("detect rule '" .. name .. "' expr parse failed, skipped")
            return
        end
        local needs = {}
        collect_needs(ast, needs)
        for k in pairs(needs) do detect_global_needs[k] = true end
        detect_rules[#detect_rules + 1] = {
            name = name or "unnamed",
            keywords = compile_keywords(split(detect_opts[prefix .. "keywords"], ",")),
            languages = split(detect_opts[prefix .. "languages"], ","),
            chain_head = chain_head,
            ast = ast,
            needs = needs,
        }
    end
    if detect_opts.mode == "general" then
        for i = 1, detect_opts.max_rules do
            local p = "rule" .. i .. "_"
            local name = detect_opts[p .. "name"]
            if name and name ~= "" then
                add_rule(name, p)
            end
        end
    else
        for _, mode in ipairs(modes) do
            add_rule(mode, mode .. "_")
        end
    end
end

load_profile_conds()
load_config()
load_detect_rules()

for head, props in pairs(property_triggers) do
    for _, prop in ipairs(props) do
        mp.observe_property(prop, "native", function()
            trigger_chain_debounce(head)
        end)
    end
end

local function on_playback_restart()
    if not detected then
        do_detect()
    end
end

local function on_file_loaded()
    detected = false
    if detect_timer then
        detect_timer:kill()
        detect_timer = nil
    end
    trigger_chain("Base")
    if #detect_rules > 0 then
        if not detect_global_needs.audio then
            do_detect()
        else
            detect_timer = mp.add_timeout(0.2, function()
                detect_timer = nil
                do_detect()
            end)
        end
    end
end

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("playback-restart", on_playback_restart)
mp.register_script_message("profile-chain", function(head)
    trigger_chain(head)
end)
