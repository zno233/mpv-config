-- content-detect.lua
-- 通用视频类型检测脚本，根据配置规则自动应用对应 profile

local mp = require "mp"
local msg = require "mp.msg"

local defaults = {
    mode = "anime",
    default_profile = "",
    show_osd = true,
    osd_duration = 2000,
    show_no_match = false,
    max_rules = 10,
    path_depth = 0,
}

local opts = {}
for k, v in pairs(defaults) do opts[k] = v end

local success, config = pcall(require, "mp.options")
if success then
    local options = config.create_options()
    options:read_options(opts, "content-detect")
end

local function split(str, sep)
    local result = {}
    if not str or str == "" then return result end
    for match in (str .. sep):gmatch("(.-)" .. sep) do
        if match ~= "" then result[#result + 1] = match:lower() end
    end
    return result
end

local sep_pat = "[%._%-%[%] ]"

local function word_match(str, kw)
    return str == kw or
           str:find("^" .. kw .. sep_pat) or
           str:find(sep_pat .. kw .. "$") or
           str:find(sep_pat .. kw .. sep_pat)
end

local function match_path(path, keywords)
    if not path or path == "" then return false end
    local lower = path:lower()
    local depth = opts.path_depth
    local i, n = 1, #lower
    if depth > 0 then
        local count = 0
        for _ in lower:gmatch("/") do count = count + 1 end
        local skip = math.max(0, count - depth + 1)
        for _ = 1, skip do
            local p = lower:find("/", i)
            if p then i = p + 1 else break end
        end
    end
    while i <= n do
        local s = lower:find("/", i) or n + 1
        local seg = lower:sub(i, s - 1)
        for _, kw in ipairs(keywords) do
            if word_match(seg, kw) then return true end
        end
        i = s + 1
    end
    return false
end

local function match_name(name, keywords)
    if not name or name == "" then return false end
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if kw:match("^[%w_]+$") then
            if word_match(lower, kw) then return true end
        else
            if lower:find(kw, 1, true) then return true end
        end
    end
    return false
end

local function match_lang(audio_lang, languages)
    if not audio_lang or audio_lang == "" then return false end
    local lower = audio_lang:lower()
    for _, lang in ipairs(languages) do
        if lower == lang then return true end
    end
    return false
end

local eval_or, parse_and, parse_atom

parse_atom = function(expr, pos, nm, tm, pm, lm)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    if pos.i <= #expr and expr:sub(pos.i, pos.i) == "(" then
        pos.i = pos.i + 1
        local val = eval_or(expr, pos, nm, tm, pm, lm)
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
        if pos.i <= #expr and expr:sub(pos.i, pos.i) == ")" then pos.i = pos.i + 1 end
        return val
    end
    local word = ""
    while pos.i <= #expr do
        local c = expr:sub(pos.i, pos.i)
        if c == " " or c == ")" or c == "&" or c == "|" then break end
        word = word .. c
        pos.i = pos.i + 1
    end
    word = word:lower()
    if word == "title" then return tm
    elseif word == "name" then return nm
    elseif word == "path" then return pm
    elseif word == "audio" then return lm
    else return false end
end

parse_and = function(expr, pos, nm, tm, pm, lm)
    local left = parse_atom(expr, pos, nm, tm, pm, lm)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == "&" do
        pos.i = pos.i + 1
        local right = parse_atom(expr, pos, nm, tm, pm, lm)
        left = left and right
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    end
    return left
end

eval_or = function(expr, pos, nm, tm, pm, lm)
    local left = parse_and(expr, pos, nm, tm, pm, lm)
    while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    while pos.i <= #expr - 1 and expr:sub(pos.i, pos.i + 1) == "||" do
        pos.i = pos.i + 2
        local right = parse_and(expr, pos, nm, tm, pm, lm)
        left = left or right
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    end
    return left
end

local function eval_match(expr, nm, tm, pm, lm)
    return eval_or(expr, {i = 1}, nm, tm, pm, lm)
end

local function load_rules()
    local rules = {}
    if opts.mode == "general" then
        for i = 1, opts.max_rules do
            local p = "rule" .. i .. "_"
            local name, profile = opts[p .. "name"], opts[p .. "profile"]
            if name and name ~= "" and profile and profile ~= "" then
                rules[#rules + 1] = {
                    name = name,
                    keywords = split(opts[p .. "keywords"], ","),
                    languages = split(opts[p .. "languages"], ","),
                    profile = profile,
                    match_mode = opts[p .. "match"] or "path",
                }
            end
        end
    else
        for _, mode in ipairs(split(opts.mode, ",")) do
            local p = mode .. "_"
            local profile = opts[p .. "profile"]
            if profile and profile ~= "" then
                rules[#rules + 1] = {
                    name = mode,
                    keywords = split(opts[p .. "keywords"], ","),
                    languages = split(opts[p .. "languages"], ","),
                    profile = profile,
                    match_mode = opts[p .. "match"] or "path",
                }
            end
        end
    end
    return rules
end

local rules = load_rules()

local function on_file_loaded()
    if #rules == 0 then return end
    local path = mp.get_property("path") or ""
    local name = mp.get_property("filename") or ""
    local title = mp.get_property("metadata/title") or ""
    local lang = mp.get_property("current-tracks/audio/lang") or ""

    for _, rule in ipairs(rules) do
        local nm = match_name(name, rule.keywords)
        local tm = match_name(title, rule.keywords)
        local pm = match_path(path, rule.keywords)
        local lm = match_lang(lang, rule.languages)

        if eval_match(rule.match_mode, nm, tm, pm, lm) then
            mp.commandv("apply-profile", rule.profile)
            msg.info("Applied: " .. rule.profile .. " (" .. rule.name .. ")")
            if opts.show_osd then mp.osd_message("自动模式: " .. rule.name, opts.osd_duration) end
            return
        end
    end

    if opts.default_profile and opts.default_profile ~= "" then
        mp.commandv("apply-profile", opts.default_profile)
        msg.info("Applied default: " .. opts.default_profile)
        if opts.show_osd then mp.osd_message("默认模式", opts.osd_duration) end
    elseif opts.show_no_match then
        mp.osd_message("未匹配", opts.osd_duration)
    end
end

mp.register_event("file-loaded", on_file_loaded)
