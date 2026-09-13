-- strm-handler.lua
-- 让 mpv 支持播放 .strm 文件的脚本

mp.add_hook("on_load", 50, function()
    local path = mp.get_property("path", "")
    if path:sub(-5):lower() == ".strm" then
        -- 读取 strm 文件第一行写入的 URL
        local file = io.open(path, "r")
        if file then
            local url = file:read("*l") -- 读取第一行
            file:close()
            
            -- 去除可能存在的首尾空格
            if url then
                url = url:gsub("^%s*(.-)%s*$", "%1")
            end
            
            -- 如果是合法的网络链接，重定向 mpv 去播放这个链接
            if url and (url:match("^https?://") or url:match("^rtsp://") or url:match("^ftp://") or url:match("^rtmp://")) then
                mp.set_property("stream-open-filename", url)
                -- 打印日志方便调试
                print("STRM 重定向至网络流: " .. url)
            end
        end
    end
end)
