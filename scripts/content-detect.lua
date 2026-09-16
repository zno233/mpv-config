--[[ content-detect.lua - 通用视频类型检测脚本 (mpv)
功能：根据配置规则（路径、文件名、标题、音频语言等）自动应用对应的 profile。

配置选项 (在 script-opts/content-detect.conf 中设置):
- mode: "anime" (默认), "movie", "general", 或逗号分隔的多个模式。
- default_profile: 未匹配任何规则时应用的默认 profile。
- show_osd: 是否显示 OSD 提示 (yes/no)。
- osd_duration: OSD 显示时间 (毫秒)。
- show_no_match: 未匹配时是否显示 OSD。
- max_rules: general 模式下的最大规则数 (默认 10)。
- path_depth: 路径匹配时保留的末尾目录层级 (0 表示全路径)。

模式特定配置 (以 anime 为例，将 anime 替换为你的 mode):
- anime_keywords: 逗号分隔的关键字。支持 "re:" 前缀使用 Lua pattern。
- anime_languages: 逗号分隔的音频语言代码 (如 jpn, eng)。
- anime_match: 匹配表达式。支持变量 (path, name, title, audio)，
  逻辑与 (&), 逻辑或 (||), 取反 (!), 括号。
  例: "path & !audio" 或 "(title || name) & audio"
- anime_profile: 匹配时应用的 mpv profile 名称。

general 模式配置:
- ruleN_name, ruleN_keywords, ruleN_languages, ruleN_match, ruleN_profile (N 为 1 到 max_rules 的数字)

【重要提示】: 建议在 mpv.conf 的 profile 定义中加入 `profile-restore=copy`，
以防止连续播放不同视频时 profile 设置残留。
--]]

local mp = require "mp"
local msg = require "mp.msg"

-- ================= 默认值 =================
local defaults = {
    mode = "anime",
    default_profile = "",
    show_osd = true,
    osd_duration = 2000,
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

local success, options = pcall(require, "mp.options")

local opts = {}
for k, v in pairs(defaults) do
    opts[k] = v
end

if success then
    for _, mode in ipairs(split(opts.mode, ",")) do
        local prefix = mode .. "_"
        opts[prefix .. "keywords"] = ""
        opts[prefix .. "languages"] = ""
        opts[prefix .. "match"] = "path"
        opts[prefix .. "profile"] = ""
    end

    for i = 1, defaults.max_rules do
        local p = "rule" .. i .. "_"
        opts[p .. "name"] = ""
        opts[p .. "keywords"] = ""
        opts[p .. "languages"] = ""
        opts[p .. "match"] = "path"
        opts[p .. "profile"] = ""
    end

    options.read_options(opts, "content-detect")
end

-- ================= 工具函数 =================
-- 1. 正则转义
local function pattern_escape(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local sep_pat = "[%._%-%[%] ]"

-- ================= 关键字编译与匹配 =================
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
    local depth = opts.path_depth

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

-- ================= AST 解析器 (支持 &, ||, !, 括号) =================
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
            msg.warn("表达式语法错误: 缺少右括号 ')'")
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
        msg.warn("表达式语法错误: 运算符缺少操作数")
        parse_ok = false
        return { type = "const", value = false }
    elseif word == "title" or word == "name" or word == "path" or word == "audio" then
        return { type = "var", name = word }
    else
        msg.warn("表达式语法错误: 未知变量 '" .. word .. "'")
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
            msg.warn("表达式语法错误: '&' 缺少右操作数")
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
            msg.warn("表达式语法错误: '||' 缺少右操作数")
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
        msg.warn("表达式语法错误: 未能完全解析 '" .. expr .. "'，可能存在多余的字符或括号不匹配")
        parse_ok = false
    end
    return ast
end

local function eval_ast(node, nm, tm, pm, lm)
    local t = node.type
    if t == "var" then
        local name = node.name
        if name == "title" then
            return tm
        elseif name == "name" then
            return nm
        elseif name == "path" then
            return pm
        else
            return lm
        end
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

-- ================= 规则加载 =================
local function load_rules()
    local rules = {}
    local global_needs = {}

    local function add_rule(name, prefix)
        local profile = opts[prefix .. "profile"]
        if not profile or profile == "" then
            if name and name ~= "" then
                msg.warn("规则 '" .. name .. "' 缺少 profile 配置，已跳过")
            end
            return
        end
        local match_expr = opts[prefix .. "match"] or "path"
        parse_ok = true
        local ast = parse_expr(match_expr)
        if not parse_ok then
            msg.warn("规则 '" .. name .. "' 表达式解析失败，已跳过")
            return
        end
        local needs = {}
        collect_needs(ast, needs)
        for k in pairs(needs) do global_needs[k] = true end

        rules[#rules + 1] = {
            name = name or "unnamed",
            keywords = compile_keywords(split(opts[prefix .. "keywords"], ",")),
            languages = split(opts[prefix .. "languages"], ","),
            profile = profile,
            ast = ast,
            needs = needs,
        }
    end

    if opts.mode == "general" then
        for i = 1, opts.max_rules do
            local p = "rule" .. i .. "_"
            local name = opts[p .. "name"]
            if name and name ~= "" then
                add_rule(name, p)
            end
        end
    else
        for _, mode in ipairs(split(opts.mode, ",")) do
            add_rule(mode, mode .. "_")
        end
    end

    if #rules == 0 then
        msg.warn("没有加载到任何有效规则，请检查配置！")
    end
    return rules, global_needs
end

local rules, global_needs = load_rules()

-- ================= 核心检测逻辑 =================
local detected = false
local detect_timer = nil
local last_profile = nil

local function apply_profile(name)
    if last_profile and last_profile ~= name then
        mp.commandv("apply-profile", last_profile, "restore")
    end
    mp.commandv("apply-profile", name)
    last_profile = name
end

local function restore_profile()
    if last_profile then
        mp.commandv("apply-profile", last_profile, "restore")
        last_profile = nil
    end
end

local function do_detect()
    if detected or #rules == 0 then return end

    local path = global_needs.path and (mp.get_property("path") or "") or ""
    local name = global_needs.name and (mp.get_property("filename") or "") or ""
    local title = global_needs.title and (mp.get_property("metadata/title") or "") or ""
    local lang = global_needs.audio and (mp.get_property("current-tracks/audio/lang") or "") or ""

    for _, rule in ipairs(rules) do
        local needs = rule.needs
        local nm = needs.name and match_name(name, rule.keywords) or false
        local tm = needs.title and match_name(title, rule.keywords) or false
        local pm = needs.path and match_path(path, rule.keywords) or false
        local lm = needs.audio and match_lang(lang, rule.languages) or false

        if eval_ast(rule.ast, nm, tm, pm, lm) then
            detected = true
            apply_profile(rule.profile)
            msg.info("Applied: " .. rule.profile .. " (" .. rule.name .. ")")
            if opts.show_osd then
                mp.osd_message("自动模式: " .. rule.name, opts.osd_duration / 1000)
            end
            return
        end
    end

    detected = true
    if opts.default_profile and opts.default_profile ~= "" then
        apply_profile(opts.default_profile)
        msg.info("Applied default: " .. opts.default_profile)
        if opts.show_osd then
            mp.osd_message("默认模式", opts.osd_duration / 1000)
        end
    elseif opts.show_no_match then
        mp.osd_message("未匹配", opts.osd_duration / 1000)
    end
end

-- ================= 事件绑定 =================
local function on_playback_restart()
    -- playback-restart 触发时，音轨和元数据通常已经就绪
    do_detect()
end

local function on_file_loaded()
    detected = false
    restore_profile()
    if detect_timer then
        detect_timer:kill()
        detect_timer = nil
    end
    if not global_needs.audio then
        do_detect()
    else
        detect_timer = mp.add_timeout(0.2, function()
            detect_timer = nil
            do_detect()
        end)
    end
end

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("playback-restart", on_playback_restart)
