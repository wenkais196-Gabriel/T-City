-- server/city_feed.lua — CityFeed 的纯规则（城市公告 / 玩家帖子）
--
-- 为什么单独一份：`server/main.lua` 里的 callbacks 需要 QBCore 与 MySQL，
-- 离线 harness 加载不了；而「什么文案能进公告」「城市公告显示成谁」是规则，
-- 必须能离线反证（改错要红）。与 server/sms.lua 同一个模式：纯规则在这里，
-- IO 在 main.lua。

CityFeed = {}

--- 城市公告的写者身份。`phone_cityfeed.citizenid` 是 NOT NULL 且被 LEFT JOIN 用来取名字，
--- 所以系统公告必须落一个哨兵值，不能让读路径去猜 NULL。
CityFeed.CITY_AUTHOR = 'city'

--- 前端与列宽对得上：玩家帖子本来就是 200 字（见 postCityFeed 的校验）。
CityFeed.MAX_LENGTH = 200

--- 城市公告在列表里的显示名（前端会加 📣 前缀）。
CityFeed.CITY_LABEL = '城市'

--- 去掉控制字符并压掉首尾空白。
---@param text any
---@return string
function CityFeed.Clean(text)
    if type(text) ~= 'string' then return '' end
    local stripped = text:gsub('[%c]', ' ')
    return stripped:match('^%s*(.-)%s*$') or ''
end

--- 长度按**字符**算（不是字节）：`#` 在 Lua 里数字节，中文一句 30 字就是 90 字节，
--- 用 `#` 判会把中文公告误判成超长。Lua 5.4 自带 utf8 库；非法字节序列退回字节数。
---@param text string
---@return number
function CityFeed.CharLength(text)
    local okLen, count = pcall(utf8.len, text)
    if okLen and type(count) == 'number' then return count end
    return #text
end

--- 校验一条城市公告。
---@param content any
---@return boolean ok, string  cleaned 文本或错误码
function CityFeed.ValidateBulletin(content)
    local cleaned = CityFeed.Clean(content)
    if cleaned == '' then return false, 'too_short' end
    if CityFeed.CharLength(cleaned) > CityFeed.MAX_LENGTH then return false, 'too_long' end
    return true, cleaned
end

--- 把一行 DB 结果规整成前端读的字段。
---@param row table|nil
---@return table|nil
function CityFeed.FormatRow(row)
    if type(row) ~= 'table' then return nil end
    local authorKind = row.author_kind
    if authorKind ~= 'city' then authorKind = 'citizen' end
    local name = row.name
    if type(name) ~= 'string' or name == '' then
        name = (authorKind == 'city') and CityFeed.CITY_LABEL or 'Anonymous'
    end
    return {
        id = row.id,
        citizenid = row.citizenid,
        name = name,
        content = row.content,
        likes = tonumber(row.likes) or 0,
        timestamp = row.timestamp,
        author_kind = authorKind,
    }
end
