-- strm-handler.lua
-- 让 mpv 支持播放 .strm 文件的脚本

local mp = require("mp")

local function is_strm(path)
    return path:sub(-5):lower() == ".strm"
end

mp.add_hook("on_load", 50, function()
    local path = mp.get_property("path")

    if not path or not is_strm(path) then
        return
    end

    local file = io.open(path, "r")
    if not file then
        return
    end

    local url = file:read("*l")
    file:close()

    if not url then
        return
    end

    url = url:gsub("^\239\187\191", "")
        :gsub("^%s*(.-)%s*$", "%1")

    if url:match("^https?://") or url:match("^rtsp://") or url:match("^rtmp://") or url:match("^ftp://") then
        mp.set_property("stream-open-filename", url)
        mp.msg.info("STRM → " .. url)
    end
end)
