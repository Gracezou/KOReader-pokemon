-- SPDX-FileCopyrightText: 2026 萧涵瑾
-- SPDX-License-Identifier: MIT

--[[--
宝可梦图鉴（Pokédex）阅读激励插件
宝可梦名称、形象及其他第三方素材的权利见 COPYRIGHT.txt。

规则：
  * 每天累计阅读满 30 分钟（可调整），随机捕获一只尚未捕获的宝可梦
  * 稀有度加权：传说极少见，常见最容易遇到
  * 全九世代 1025 只，集齐即为图鉴大师
  * 图鉴可按世代 / 捕获状态筛选，支持翻页、滑动、点击查看详情

数据与立绘离线内置于插件目录，无需联网。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
-- ui/time 模块自 v2022.03 才内置；老版本（如 v2022.01）自动降级为本地单调时钟
local ok_time, time = pcall(require, "ui/time")
if not (ok_time and type(time) == "table" and type(time.now) == "function") then
    local mono_us  -- 返回单调时钟的微秒刻度，仅用于差值测量
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi then
        pcall(function()
            ffi.cdef[[
                struct pkmn_timespec_t { long tv_sec; long tv_nsec; };
                int clock_gettime(int, struct pkmn_timespec_t *);
            ]]
        end)
        local ts = ffi.new("struct pkmn_timespec_t[1]")
        local probe = pcall(function()
            ffi.C.clock_gettime(1, ts) -- 1 = CLOCK_MONOTONIC
            return ts[0].tv_sec * 1000000 + math.floor(ts[0].tv_nsec / 1000)
        end)
        if probe then
            mono_us = function()
                ffi.C.clock_gettime(1, ts)
                return ts[0].tv_sec * 1000000 + math.floor(ts[0].tv_nsec / 1000)
            end
        end
    end
    if not mono_us then
        local ok_sock, socket = pcall(require, "socket")
        if ok_sock and type(socket) == "table" and type(socket.gettime) == "function" then
            mono_us = function() return math.floor(socket.gettime() * 1000000) end
        else
            mono_us = function() return os.time() * 1000000 end
        end
    end
    time = {
        now = mono_us,
        to_s = function(us) return us / 1000000 end,
    }
    logger.info("Pokemon: ui/time not available, using fallback monotonic clock")
end

local Screen = Device.screen
local Input = Device.input

local DEX = require("pokedex_data")

local DEX_BY_ID = {}
for _i, _mon in ipairs(DEX) do
    DEX_BY_ID[_mon.id] = _mon
end

local TOTAL = #DEX
-- 构建标记：显示在图鉴标题栏和主面板副标题，用于实机确认加载的是哪个版本
local BUILD_TAG = "1027z8"
local RIGHTS_NOTICE = "本插件是免费、非营利的非官方同人作品。\n"
    .. "原创插件代码 © 2026 萧涵瑾，采用 MIT 许可证。\n"
    .. "宝可梦立绘 © The Pokémon Company，相关商标归各自权利人。"
    .. "本项目未获宝可梦官方授权。"

-- 稀有度权重（数值越大越容易遇到）
local RARITY_WEIGHT = {
    common = 30,
    uncommon = 14,
    rare = 6,
    legendary = 1,
}
local RARITY_LABEL = {
    common = "常见",
    uncommon = "少见",
    rare = "稀有",
    legendary = "传说",
}
local GEN_LABEL = {
    [1] = "关都",
    [2] = "城都",
    [3] = "丰缘",
    [4] = "神奥",
    [5] = "合众",
    [6] = "卡洛斯",
    [7] = "阿罗拉",
    [8] = "伽勒尔",
    [9] = "帕底亚",
}

-- 彩色调色板（Kaleido 3 彩屏）：饱和度拉高，电子墨水上才鲜明
local function rgb(r, g, b)
    return Blitbuffer.ColorRGB32(r, g, b, 255)
end
local RGB = {
    poke_red   = rgb(227, 53, 13),    -- 精灵球红
    leaf_green = rgb(56, 158, 76),    -- 达标绿
    water_blue = rgb(52, 120, 214),   -- 进行蓝
    gold       = rgb(240, 164, 10),   -- 金黄
    soft_pink  = rgb(233, 88, 133),   -- 粉
    orange     = rgb(240, 130, 30),   -- 奖章橙（连续达标）
    grape      = rgb(150, 90, 220),   -- 奖章紫（训练家等级）
}

-- 18 种属性的标准配色 { 背景色, 前景色 }（前景色用于浅底上的深字）
local TYPE_COLORS = {
    ["一般"] = { rgb(160, 160, 148), Blitbuffer.COLOR_WHITE },
    ["火"]   = { rgb(240, 108, 44), Blitbuffer.COLOR_WHITE },
    ["水"]   = { rgb(74, 136, 233), Blitbuffer.COLOR_WHITE },
    ["电"]   = { rgb(246, 201, 19), rgb(96, 74, 8) },
    ["草"]   = { rgb(92, 190, 92), Blitbuffer.COLOR_WHITE },
    ["冰"]   = { rgb(112, 208, 208), rgb(20, 62, 72) },
    ["格斗"] = { rgb(206, 64, 106), Blitbuffer.COLOR_WHITE },
    ["毒"]   = { rgb(171, 92, 201), Blitbuffer.COLOR_WHITE },
    ["地面"] = { rgb(216, 165, 86), rgb(74, 52, 8) },
    ["飞行"] = { rgb(146, 156, 232), Blitbuffer.COLOR_WHITE },
    ["超能力"] = { rgb(244, 108, 116), Blitbuffer.COLOR_WHITE },
    ["虫"]   = { rgb(146, 178, 44), rgb(52, 66, 8) },
    ["岩石"] = { rgb(186, 170, 118), rgb(62, 54, 28) },
    ["幽灵"] = { rgb(98, 86, 152), Blitbuffer.COLOR_WHITE },
    ["龙"]   = { rgb(112, 92, 238), Blitbuffer.COLOR_WHITE },
    ["恶"]   = { rgb(106, 92, 84), Blitbuffer.COLOR_WHITE },
    ["钢"]   = { rgb(178, 178, 198), rgb(46, 50, 66) },
    ["妖精"] = { rgb(238, 134, 174), rgb(92, 22, 48) },
}

-- 训练家等级：xp_for_level(L) = 到达 L 级所需的累计 XP
local MAX_LEVEL = 30
local function xpForLevel(L)
    return 50 * (L - 1) * L   -- L=2:100, L=3:300, L=4:600 … L=30:43500
end
local LEVEL_TITLES = {
    { 1,  "新人训练家" },
    { 4,  "普通训练家" },
    { 8,  "精英训练家" },
    { 12, "道馆馆主" },
    { 16, "大会优胜者" },
    { 20, "天王候补" },
    { 25, "四天王" },
    { 30, "地区冠军" },
}
local function levelTitle(L)
    local title = LEVEL_TITLES[1][2]
    for _i, pair in ipairs(LEVEL_TITLES) do
        if L >= pair[1] then title = pair[2] end
    end
    return title
end

-- 阶段性奖励：收集数量里程碑 + 每个世代的地区图鉴
local MILESTONES = { 10, 25, 50, 100, 200, 300, 500, 750, 1025 }
local GEN_TOTAL = {}
for _i, _mon in ipairs(DEX) do
    GEN_TOTAL[_mon.gen] = (GEN_TOTAL[_mon.gen] or 0) + 1
end

-- 连续达标奖励（天）
local STREAK_MILESTONES = { 3, 7, 14, 30, 100, 365 }

-- 捕手连击奖励（次）：连续捕获不重复的新面孔
local COMBO_MILESTONES = { 5, 10, 20, 40 }

-- 孵蛋：每天读满目标 = 蛋的孵化进度 +1，攒满 EGG_DAYS 天孵化（额外送一次捕获）
local EGG_DAYS = 3

-- 闪光个体：每次捕获有 1/SHINY_RATE 概率遇到闪闪发光的特殊个体
local SHINY_RATE = 96
-- 闪光保底：连续这么多次都没出闪光，下一次必出。
-- 96 分之一的期望是 96 次，200 次约等于两倍期望——只兜住极端倒霉的情况
-- （约 12% 的连败会摸到线），不会让闪光变成刷次数的必然产物。
local SHINY_PITY = 200

-- 时钟防呆：设备彻底亏电后 RTC 可能回退（Kobo 亏电久了会回到出厂时间）。
-- save() 把见过的最大时间戳持久化，load() 发现当前时钟早于它超过容差，
-- 就判定"时钟倒流"，冻结按天结算（奖励/周常/连击全部沿用冻结日期），
-- 直到用户校时（时钟追上高水位）自动解除。只防倒流不防快进：
-- 快进只会让冷却提前结束（小亏），不会刷奖励，校时后自然归位。
local CLOCK_BACK_TOLERANCE = 600  -- 10 分钟容差，避免误伤正常的时钟微调

-- 进化链：同一只捕获满 3 次进化为下一形态（多分支则随机选一条）
local EVO_STEP = 3

-- 老朋友：每次普通捕获有 DUP_RATE 概率再遇已捕获的（按相遇次数加权）
local DUP_RATE = 0.25

-- 等级奖励 XP：进化 / 孵蛋 / 连击达成——玩法行为接入训练家等级
local EVO_XP = 200
local EGG_XP = 150
local COMBO_XP = 100
-- 进化链映射：EVO_NEXT[id] = 下一形态（多分支为随机候选列表）
local EVO_NEXT = {
    [1]={2},
    [2]={3},
    [4]={5},
    [5]={6},
    [7]={8},
    [8]={9},
    [10]={11},
    [11]={12},
    [13]={14},
    [14]={15},
    [16]={17},
    [17]={18},
    [19]={20},
    [21]={22},
    [23]={24},
    [25]={26},
    [27]={28},
    [29]={30},
    [30]={31},
    [32]={33},
    [33]={34},
    [35]={36},
    [37]={38},
    [39]={40},
    [41]={42},
    [42]={169},
    [43]={44},
    [44]={45,182},
    [46]={47},
    [48]={49},
    [50]={51},
    [52]={53,863},
    [54]={55},
    [56]={57},
    [57]={979},
    [58]={59},
    [60]={61},
    [61]={62,186},
    [63]={64},
    [64]={65},
    [66]={67},
    [67]={68},
    [69]={70},
    [70]={71},
    [72]={73},
    [74]={75},
    [75]={76},
    [77]={78},
    [79]={80,199},
    [81]={82},
    [82]={462},
    [83]={865},
    [84]={85},
    [86]={87},
    [88]={89},
    [90]={91},
    [92]={93},
    [93]={94},
    [95]={208},
    [96]={97},
    [98]={99},
    [100]={101},
    [102]={103},
    [104]={105},
    [108]={463},
    [109]={110},
    [111]={112},
    [112]={464},
    [113]={242},
    [114]={465},
    [116]={117},
    [117]={230},
    [118]={119},
    [120]={121},
    [122]={866},
    [123]={212,900},
    [125]={466},
    [126]={467},
    [129]={130},
    [133]={134,135,136,196,197,470,471,700},
    [137]={233},
    [138]={139},
    [140]={141},
    [147]={148},
    [148]={149},
    [152]={153},
    [153]={154},
    [155]={156},
    [156]={157},
    [158]={159},
    [159]={160},
    [161]={162},
    [163]={164},
    [165]={166},
    [167]={168},
    [170]={171},
    [172]={25},
    [173]={35},
    [174]={39},
    [175]={176},
    [176]={468},
    [177]={178},
    [179]={180},
    [180]={181},
    [183]={184},
    [187]={188},
    [188]={189},
    [190]={424},
    [191]={192},
    [193]={469},
    [194]={195,980},
    [198]={430},
    [200]={429},
    [203]={981},
    [204]={205},
    [206]={982},
    [207]={472},
    [209]={210},
    [211]={904},
    [215]={461,903},
    [216]={217},
    [217]={901},
    [218]={219},
    [220]={221},
    [221]={473},
    [222]={864},
    [223]={224},
    [228]={229},
    [231]={232},
    [233]={474},
    [234]={899},
    [236]={106,107,237},
    [238]={124},
    [239]={125},
    [240]={126},
    [246]={247},
    [247]={248},
    [252]={253},
    [253]={254},
    [255]={256},
    [256]={257},
    [258]={259},
    [259]={260},
    [261]={262},
    [263]={264},
    [264]={862},
    [265]={266,268},
    [266]={267},
    [268]={269},
    [270]={271},
    [271]={272},
    [273]={274},
    [274]={275},
    [276]={277},
    [278]={279},
    [280]={281},
    [281]={282,475},
    [283]={284},
    [285]={286},
    [287]={288},
    [288]={289},
    [290]={291,292},
    [293]={294},
    [294]={295},
    [296]={297},
    [298]={183},
    [299]={476},
    [300]={301},
    [304]={305},
    [305]={306},
    [307]={308},
    [309]={310},
    [315]={407},
    [316]={317},
    [318]={319},
    [320]={321},
    [322]={323},
    [325]={326},
    [328]={329},
    [329]={330},
    [331]={332},
    [333]={334},
    [339]={340},
    [341]={342},
    [343]={344},
    [345]={346},
    [347]={348},
    [349]={350},
    [353]={354},
    [355]={356},
    [356]={477},
    [360]={202},
    [361]={362,478},
    [363]={364},
    [364]={365},
    [366]={367,368},
    [371]={372},
    [372]={373},
    [374]={375},
    [375]={376},
    [387]={388},
    [388]={389},
    [390]={391},
    [391]={392},
    [393]={394},
    [394]={395},
    [396]={397},
    [397]={398},
    [399]={400},
    [401]={402},
    [403]={404},
    [404]={405},
    [406]={315},
    [408]={409},
    [410]={411},
    [412]={413,414},
    [415]={416},
    [418]={419},
    [420]={421},
    [422]={423},
    [425]={426},
    [427]={428},
    [431]={432},
    [433]={358},
    [434]={435},
    [436]={437},
    [438]={185},
    [439]={122},
    [440]={113},
    [443]={444},
    [444]={445},
    [446]={143},
    [447]={448},
    [449]={450},
    [451]={452},
    [453]={454},
    [456]={457},
    [458]={226},
    [459]={460},
    [495]={496},
    [496]={497},
    [498]={499},
    [499]={500},
    [501]={502},
    [502]={503},
    [504]={505},
    [506]={507},
    [507]={508},
    [509]={510},
    [511]={512},
    [513]={514},
    [515]={516},
    [517]={518},
    [519]={520},
    [520]={521},
    [522]={523},
    [524]={525},
    [525]={526},
    [527]={528},
    [529]={530},
    [532]={533},
    [533]={534},
    [535]={536},
    [536]={537},
    [540]={541},
    [541]={542},
    [543]={544},
    [544]={545},
    [546]={547},
    [548]={549},
    [550]={902},
    [551]={552},
    [552]={553},
    [554]={555},
    [557]={558},
    [559]={560},
    [562]={563,867},
    [564]={565},
    [566]={567},
    [568]={569},
    [570]={571},
    [572]={573},
    [574]={575},
    [575]={576},
    [577]={578},
    [578]={579},
    [580]={581},
    [582]={583},
    [583]={584},
    [585]={586},
    [588]={589},
    [590]={591},
    [592]={593},
    [595]={596},
    [597]={598},
    [599]={600},
    [600]={601},
    [602]={603},
    [603]={604},
    [605]={606},
    [607]={608},
    [608]={609},
    [610]={611},
    [611]={612},
    [613]={614},
    [616]={617},
    [619]={620},
    [622]={623},
    [624]={625},
    [625]={983},
    [627]={628},
    [629]={630},
    [633]={634},
    [634]={635},
    [636]={637},
    [650]={651},
    [651]={652},
    [653]={654},
    [654]={655},
    [656]={657},
    [657]={658},
    [659]={660},
    [661]={662},
    [662]={663},
    [664]={665},
    [665]={666},
    [667]={668},
    [669]={670},
    [670]={671},
    [672]={673},
    [674]={675},
    [677]={678},
    [679]={680},
    [680]={681},
    [682]={683},
    [684]={685},
    [686]={687},
    [688]={689},
    [690]={691},
    [692]={693},
    [694]={695},
    [696]={697},
    [698]={699},
    [704]={705},
    [705]={706},
    [708]={709},
    [710]={711},
    [712]={713},
    [714]={715},
    [722]={723},
    [723]={724},
    [725]={726},
    [726]={727},
    [728]={729},
    [729]={730},
    [731]={732},
    [732]={733},
    [734]={735},
    [736]={737},
    [737]={738},
    [739]={740},
    [742]={743},
    [744]={745},
    [747]={748},
    [749]={750},
    [751]={752},
    [753]={754},
    [755]={756},
    [757]={758},
    [759]={760},
    [761]={762},
    [762]={763},
    [767]={768},
    [769]={770},
    [772]={773},
    [782]={783},
    [783]={784},
    [789]={790},
    [790]={791,792},
    [803]={804},
    [808]={809},
    [810]={811},
    [811]={812},
    [813]={814},
    [814]={815},
    [816]={817},
    [817]={818},
    [819]={820},
    [821]={822},
    [822]={823},
    [824]={825},
    [825]={826},
    [827]={828},
    [829]={830},
    [831]={832},
    [833]={834},
    [835]={836},
    [837]={838},
    [838]={839},
    [840]={841,842,1011},
    [843]={844},
    [846]={847},
    [848]={849},
    [850]={851},
    [852]={853},
    [854]={855},
    [856]={857},
    [857]={858},
    [859]={860},
    [860]={861},
    [868]={869},
    [872]={873},
    [878]={879},
    [884]={1018},
    [885]={886},
    [886]={887},
    [891]={892},
    [906]={907},
    [907]={908},
    [909]={910},
    [910]={911},
    [912]={913},
    [913]={914},
    [915]={916},
    [917]={918},
    [919]={920},
    [921]={922},
    [922]={923},
    [924]={925},
    [926]={927},
    [928]={929},
    [929]={930},
    [932]={933},
    [933]={934},
    [935]={936,937},
    [938]={939},
    [940]={941},
    [942]={943},
    [944]={945},
    [946]={947},
    [948]={949},
    [951]={952},
    [953]={954},
    [955]={956},
    [957]={958},
    [958]={959},
    [960]={961},
    [963]={964},
    [965]={966},
    [969]={970},
    [971]={972},
    [974]={975},
    [996]={997},
    [997]={998},
    [999]={1000},
    [1011]={1019},
    [1012]={1013},
}

-- 调试模式：正式发布版设为 false（菜单里不显示"调试："入口）；
-- 需要排错时改成 true 即可恢复全部调试功能
local DEBUG_MODE = false  -- 正式版：不显示「调试：」入口
-- （正式发布请改回 false，见下方注释）

-- 今日卡片的鼓励语（按小时轮换，读着不腻）
local TODAY_QUOTES = {
    "翻开书就有好事发生～",
    "今天会遇到谁呢？好期待！",
    "读书吧，小伙伴在等你～",
    "书页之间藏着小惊喜！",
    "多读一点，图鉴就亮一格～",
    "安静的读书时光最珍贵啦～",
    "坚持一下，奇迹就在下一页！",
}

--------------------------------------------------------------------
-- 小工具
--------------------------------------------------------------------

local function fmtDuration(secs)
    local m = math.floor((secs or 0) / 60)
    if m < 60 then
        return string.format("%d 分钟", m)
    end
    local h = math.floor(m / 60)
    if h < 24 then
        return string.format("%d 小时 %d 分钟", h, m % 60)
    end
    return string.format("%d 天 %d 小时", math.floor(h / 24), h % 24)
end

local function monTypesText(mon)
    return table.concat(mon.types, " / ")
end

-- "2026-10-24" -> "2026年10月24日"（旧格式原样返回）
local function fmtDateCN(s)
    if not s or s == "" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if y then
        return string.format("%s年%d月%d日", y, tonumber(m), tonumber(d))
    end
    return s
end

-- 书名过长截断，避免详情行溢出卡片
local function shortBook(name, maxlen)
    if not name or name == "" then return nil end
    maxlen = maxlen or 14
    if #name <= maxlen * 3 then  -- 中文按 UTF-8 字节数粗略判断
        return name
    end
    -- 按字符截断（UTF-8 安全）
    local out, count = {}, 0
    local i = 1
    while i <= #name and count < maxlen do
        local b = name:byte(i)
        local len = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        out[#out + 1] = name:sub(i, i + len - 1)
        i = i + len
        count = count + 1
    end
    return table.concat(out) .. "…"
end

local function spritePath(plugin, mon, kind, use_shiny)
    -- kind: "big" | "small" | "sil" | "sil_small" | "shiny" | "shiny_small"
    -- 闪光个体用官方 shiny 配色立绘（颜色和普通个体明显不同），
    -- 素材缺失时自动回退到普通配色，保证不会白屏。
    if use_shiny then
        local shiny_sub = {
            big = "/sprites/shiny/",
            small = "/sprites/shiny/small/",
        }
        local sp = plugin.path .. shiny_sub[kind] .. string.format("%04d.png", mon.id)
        if lfs.attributes(sp, "mode") == "file" then
            return sp
        end
    end
    local sub = {
        big = "/sprites/",
        small = "/sprites/small/",
        sil = "/sprites/sil/",
        sil_small = "/sprites/sil/small/",
    }
    return plugin.path .. sub[kind] .. string.format("%04d.png", mon.id)
end

local function makeText(text, face, bold, color)
    return TextWidget:new{
        text = text,
        face = Font:getFace(face or "xx_smallinfofont"),
        bold = bold or false,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
end

--------------------------------------------------------------------
-- 可爱风：圆体字体 / 装饰图标 / 胶囊进度条
--------------------------------------------------------------------

-- 设备 fonts 目录（koreader/fonts）里的圆体，缺失时自动退回内置字体
local CUTE_FONT = "PokemonCute.ttf"
local cute_font_ok = false
do
    local ok, face = pcall(Font.getFace, Font, CUTE_FONT, 20)
    cute_font_ok = ok and face ~= nil
end

local function cuteFace(orig_size)
    if cute_font_ok then
        local ok, face = pcall(Font.getFace, Font, CUTE_FONT, orig_size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", orig_size)
end

local function makeCuteText(text, orig_size, bold, color)
    return TextWidget:new{
        text = text,
        face = cuteFace(orig_size or 18),
        bold = bold or false,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
    }
end

local function decoPath(plugin, name)
    return plugin.path .. "/deco/" .. name
end

-- 自制平底按钮：尺寸完全由调用方决定，不依赖 ButtonTable 的上报。
-- 本机 KOReader 的 ButtonTable（FocusManager 版）上报高度与实际绘制不符，
-- 放在依赖测量的布局里会把按钮挤丢（捕获卡"收下"、主面板"先去读书啦"都栽过）
local function makeFlatButton(text_str, cb, w, h, opts)
    opts = opts or {}
    local btn = InputContainer:new{ dimen = Geom:new{ w = w, h = h } }
    if Device:isTouchDevice() then
        btn.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = btn.dimen },
        }
    end
    btn.onTap = function() cb() return true end
    btn.onHold = function() return true end
    btn[1] = CenterContainer:new{
        dimen = btn.dimen,
        FrameContainer:new{
            padding = Screen:scaleBySize(4),
            margin = 0,
            bordersize = Screen:scaleBySize(opts.bordersize or 2),
            radius = Screen:scaleBySize(12),
            color = opts.color or RGB.poke_red,
            background = Blitbuffer.COLOR_WHITE,
            makeCuteText(text_str, opts.font or 18, true,
                opts.fontcolor or opts.color or RGB.poke_red),
        },
    }
    return btn
end

-- 把 ButtonTable 风格的按钮表（多行、每行若干枚）换成自制按钮。
-- 本机 ButtonTable 既会谎报高度（按钮被挤出屏幕），也会让点击区域失效，
-- 所以凡是需要点的按钮一律走这里，不再用 ButtonTable。
local function makeButtonRows(btn_rows, total_w, opts)
    opts = opts or {}
    local gap = Screen:scaleBySize(8)
    local h = opts.height or Screen:scaleBySize(44)
    local out = VerticalGroup:new{ align = "center" }
    for ri, row_defs in ipairs(btn_rows) do
        local n = #row_defs
        if n > 0 then
            local bw = math.floor((total_w - (n - 1) * gap) / n)
            local row = HorizontalGroup:new{ align = "center" }
            for ci, def in ipairs(row_defs) do
                if ci > 1 then
                    table.insert(row, HorizontalSpan:new{ width = gap })
                end
                table.insert(row, makeFlatButton(def.text, def.callback, bw, h, {
                    color = def.color or opts.color,
                    font = def.font or opts.font or 18,
                    bordersize = def.bordersize or opts.bordersize,
                }))
            end
            table.insert(out, row)
            if ri < #btn_rows then
                table.insert(out, VerticalSpan:new{ width = gap })
            end
        end
    end
    return out
end

--------------------------------------------------------------------
-- 文字折行 / 全屏刷新小工具
--------------------------------------------------------------------

-- UTF-8 逐字符迭代（一个汉字/字母为一个单位，不会拆坏中文）
local function utf8Chars(s)
    return s:gmatch("[\1-\127\192-\255][\128-\191]*")
end

-- 实测一段文字的像素宽度（临时建控件测量后立即释放）
local function measureTextW(text, face, bold)
    local w = TextWidget:new{
        text = text, face = face, bold = bold or false,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local ok, sz = pcall(w.getSize, w)
    pcall(w.free, w)
    if ok and sz then return sz.w end
    return #text * 16
end

-- 超宽自动折行：返回行数组
local function wrapTextLines(text, max_w, face, bold)
    if not text or text == "" then return { "" } end
    local lines, cur = {}, ""
    for ch in utf8Chars(text) do
        if cur ~= "" and measureTextW(cur .. ch, face, bold) > max_w then
            lines[#lines + 1] = cur
            cur = ch
        else
            cur = cur .. ch
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

-- 折行 + 居中排成 VerticalGroup：弹窗内长句专用，杜绝文字超出边框
local function makeWrappedText(text, face, bold, color, max_w)
    local vg = VerticalGroup:new{ align = "center" }
    for _, ln in ipairs(wrapTextLines(text, max_w, face, bold)) do
        table.insert(vg, TextWidget:new{
            text = ln, face = face, bold = bold or false,
            fgcolor = color or Blitbuffer.COLOR_BLACK,
        })
    end
    return vg
end

-- 弹窗正文专用排版：先按换行和 "★" 拆成独立条目行，再对超宽条目折行
-- （整段按宽度硬折行会让每行都顶满左右两边，视觉上永远是左对齐，
--   居中根本看不出来 —— 实机多轮反馈就是这个原因）
local function splitCenteredLines(text, max_w, face, bold)
    local items = {}
    for para in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local buf = ""
        for ch in utf8Chars(para) do
            if ch == "★" and buf ~= "" then
                items[#items + 1] = buf
                buf = ch
            else
                buf = buf .. ch
            end
        end
        if buf ~= "" then items[#items + 1] = buf end
    end
    local lines = {}
    for _, it in ipairs(items) do
        for _, sub in ipairs(wrapTextLines(it, max_w, face, bold)) do
            lines[#lines + 1] = sub
        end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end

-- 全屏重绘前顺手重建一次已打开的菜单（若真有菜单开着）：
-- 「糖果罐（● 110）」买完还是 110、「我的图鉴（16/1025）」抓完还是 16。
-- updateItems() 不带参数会保留当前页和所处子菜单，不会把用户踢回首页。
-- 现在菜单点完就关、不再常驻，这里是兜底，正常路径走不到。
local function refreshOpenMenu()
    pcall(function()
        local stack = UIManager._window_stack or UIManager._windowstack or {}
        for _, entry in ipairs(stack) do
            local wgt = entry and (entry.widget or entry) or nil
            -- item_table 是 TouchMenu 的特征字段，避免误伤别的 widget
            if wgt and wgt.updateItems and wgt.item_table then
                wgt:updateItems()
            end
        end
    end)
end

-- 关闭自定义弹窗后强制全屏刷新：清残影，
-- 也避免局部刷新区域算偏导致「看起来卡死」
local function fullRefreshScreen()
    -- 先重建菜单项文本，再整屏重绘
    refreshOpenMenu()
    local ok = pcall(function()
        if UIManager.forceReflash then
            UIManager:forceReflash()
        else
            for _, wgt in ipairs(UIManager._windowstack or {}) do
                UIManager:setDirty(wgt, "full")
            end
        end
    end)
    if not ok then
        pcall(function() UIManager:setDirty(nil, "full") end)
    end
end

-- 把内容组放进卡片可用宽度内水平居中：
-- FrameContainer 会把比卡片窄的内容贴左排，
-- 这正是「弹窗看起来不居中 / 内容偏一边」的元凶
local function centerRowsInFrame(rows, inner_w)
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = rows:getSize().h },
        rows,
    }
end

-- 圆角胶囊进度条（比系统 ProgressWidget 圆润，eink 下也干净）
local PillBar = Widget:extend{
    width = nil,
    height = nil,
    percentage = 0,
    bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
    fillcolor = Blitbuffer.COLOR_GRAY_5,
    radius = nil,
    ticks = false,   -- 每 10% 画一道细刻度（精致感）
}

function PillBar:getSize()
    if not self.dimen then
        self.dimen = Geom:new{ w = self.width, h = self.height }
    end
    return self.dimen
end

function PillBar:paintTo(bb, x, y)
    local d = self:getSize()
    local r = self.radius or math.floor(d.h / 2)
    bb:paintRoundedRect(x, y, d.w, d.h, self.bgcolor, r)
    local pct = math.min(math.max(self.percentage or 0, 0), 1)
    local fw = math.floor(d.w * pct)
    if fw > 0 then
        fw = math.max(fw, d.h)  -- 至少画出一个圆点
        bb:paintRoundedRect(x, y, fw, d.h, self.fillcolor, r)
    end
    -- 细刻度：每 10% 一道白色竖线，叠在填充之上
    if self.ticks then
        local tick_color = Blitbuffer.COLOR_WHITE
        for i = 1, 9 do
            local tx = x + math.floor(d.w * i / 10)
            bb:paintRect(tx, y + math.floor(d.h * 0.25),
                math.max(1, Screen:scaleBySize(1)), math.floor(d.h * 0.5), tick_color)
        end
    end
end

--------------------------------------------------------------------
-- 可触摸拉杆（自定义每日目标用）
--------------------------------------------------------------------

local GoalSlider = InputContainer:extend{
    width = nil,
    min = 5,
    max = 120,
    step = 5,
    value = 30,
    on_value_change = nil,   -- 数值变化时回调，由调用方负责重绘
}

function GoalSlider:init()
    self.track_h = Screen:scaleBySize(12)
    self.knob_r = Screen:scaleBySize(11)
    self.pad = self.knob_r + Screen:scaleBySize(2)
    self.dimen = Geom:new{
        w = self.width,
        h = self.track_h + self.pad * 2,
    }
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
        self.ges_events.Pan = {
            GestureRange:new{ ges = "pan", range = self.dimen },
        }
        self.ges_events.PanRelease = {
            GestureRange:new{ ges = "pan_release", range = self.dimen },
        }
    end
end

function GoalSlider:getSize()
    return self.dimen
end

function GoalSlider:posToValue(pos_x)
    -- 首次绘制前 dimen.x 为空，直接忽略这次点击（防止个别机型报错卡死）
    if not self.dimen or not self.dimen.x then return self.value end
    local usable = self.dimen.w - 2 * self.pad
    if usable <= 0 then return self.value end
    local pct = (pos_x - self.dimen.x - self.pad) / usable
    pct = math.min(math.max(pct, 0), 1)
    local raw = self.min + pct * (self.max - self.min)
    local v = self.min + math.floor((raw - self.min) / self.step + 0.5) * self.step
    return math.min(math.max(v, self.min), self.max)
end

function GoalSlider:setValue(v)
    v = math.min(math.max(v, self.min), self.max)
    if v ~= self.value then
        self.value = v
        if self.on_value_change then self.on_value_change(v) end
    end
end

function GoalSlider:onTap(_, ges)
    self:setValue(self:posToValue(ges.pos.x))
    return true
end

function GoalSlider:onPan(_, ges)
    self:setValue(self:posToValue(ges.pos.x))
    return true
end

function GoalSlider:onPanRelease()
    return true
end

function GoalSlider:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local track_y = y + self.pad
    local h = self.track_h
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, track_y, self.dimen.w, h, Blitbuffer.COLOR_LIGHT_GRAY, r)
    local pct = (self.value - self.min) / (self.max - self.min)
    local knob_x = x + self.pad + math.floor((self.dimen.w - 2 * self.pad) * pct)
    local fill_w = knob_x - x
    if fill_w > r then
        bb:paintRoundedRect(x, track_y, fill_w, h, RGB.poke_red, r)
    end
    local cy = track_y + math.floor(h / 2)
    bb:paintCircle(knob_x, cy, self.knob_r, RGB.poke_red)
    bb:paintCircle(knob_x, cy, self.knob_r - Screen:scaleBySize(2), Blitbuffer.COLOR_WHITE)
    -- 把手中心再来一个红色小圆点，更像精灵球的按钮
    bb:paintCircle(knob_x, cy, Screen:scaleBySize(3), RGB.poke_red)
end

--------------------------------------------------------------------
-- 图鉴格子的单个宝可梦
--------------------------------------------------------------------

local DexCell = InputContainer:extend{
    width = nil,
    height = nil,
    mon = nil,
    info = nil,      -- 捕获信息，nil 表示未捕获
    plugin = nil,
    image_size = nil,
    callback = nil,
}

function DexCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    local caught = self.info ~= nil
    local pad = Screen:scaleBySize(3)
    local bs = caught and Screen:scaleBySize(2) or Screen:scaleBySize(1)
    local is_shiny_cell = caught and self.info.shiny or false
    local img = ImageWidget:new{
        file = spritePath(self.plugin, self.mon, caught and "small" or "sil_small",
            is_shiny_cell),
        width = self.image_size,
        height = self.image_size,
        scale_factor = 0,
        alpha = true,
    }

    -- 性能：圆点/星徽全部用文字符号（● ○ ◆）代替 FrameContainer 圆角框
    -- 和小图 ImageWidget。一页 30 格能少掉 200+ 个控件，翻页明显更跟手。
    local dot_s = Screen:scaleBySize(7)

    -- 编号行：No.xxxx（闪光金色 ◆）+ 属性色点 + 闪光星徽
    local no_text = string.format("%04d", self.mon.id)
    local no_color = Blitbuffer.COLOR_GRAY
    local num_row = HorizontalGroup:new{ align = "center" }
    if is_shiny_cell then
        table.insert(num_row, makeText("◆", "xx_smallinfofont", true, RGB.gold))
        table.insert(num_row, HorizontalSpan:new{ width = Screen:scaleBySize(2) })
        no_color = RGB.gold
    end
    table.insert(num_row, makeText(no_text, "xx_smallinfofont", false, no_color))
    if caught then
        table.insert(num_row, HorizontalSpan:new{ width = Screen:scaleBySize(3) })
        for ti, tname in ipairs(self.mon.types) do
            if ti > 2 then break end
            local tc = TYPE_COLORS[tname]
            table.insert(num_row, HorizontalSpan:new{ width = Screen:scaleBySize(1) })
            table.insert(num_row, makeText("●", "xx_smallinfofont",
                false, tc and tc[1] or Blitbuffer.COLOR_GRAY))
        end
    end

    -- 名字行：名字 + 相遇次数徽记（×N，≥2 次才显示）
    local name_text = caught and self.mon.name or "？？？"
    local name_color = caught and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    local count_n = caught and (self.info.count or 1) or 0
    if count_n >= 2 then
        name_text = name_text .. string.format(" ×%d", count_n)
    end
    local name_row = HorizontalGroup:new{
        align = "center",
        makeCuteText(name_text, 17, false, name_color),
    }

    -- 进化进度行（固定高度保持所有格子对齐）：
    -- 还能进化且未进化的，显示 ●●○ 式进度；其余用同字号空格占位，
    -- 保证有进化进度和没进化进度的格子文字区高度完全一致
    local evo_row = HorizontalGroup:new{ align = "center" }
    if caught and not self.info.evo and EVO_NEXT[self.mon.id] then
        local have = math.min(count_n, EVO_STEP)
        for i = 1, EVO_STEP do
            if i > 1 then
                table.insert(evo_row, HorizontalSpan:new{ width = Screen:scaleBySize(1) })
            end
            table.insert(evo_row, makeText(i <= have and "●" or "○", "xx_smallinfofont",
                false, i <= have and RGB.water_blue or Blitbuffer.COLOR_LIGHT_GRAY))
        end
    else
        table.insert(evo_row, makeText(" ", "xx_smallinfofont",
            false, Blitbuffer.COLOR_WHITE))
    end

    -- 圆角"贴纸"卡片：已捕获描边更深，未捕获浅到几乎隐形；闪光个体金框
    -- 每一行都套 CenterContainer 按内容区宽度强制水平居中——
    -- 不再依赖 VerticalGroup 里"最宽的那行"来对齐（实机截图证明不可靠）
    local content_w = self.width - 2 * pad - 2 * bs
    local function centerRow(row, h)
        return CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = h },
            row,
        }
    end
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = pad,
        margin = 0,
        bordersize = bs,
        radius = Screen:scaleBySize(10),
        color = is_shiny_cell and RGB.gold
            or (caught and Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_LIGHT_GRAY),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            centerRow(img, self.image_size),
            VerticalSpan:new{ width = Screen:scaleBySize(1) },
            centerRow(num_row, num_row:getSize().h),
            centerRow(name_row, name_row:getSize().h),
            centerRow(evo_row, evo_row:getSize().h),
        },
    }
end

function DexCell:onTap()
    if self.callback then
        self.callback(self.mon)
    end
    return true
end

--------------------------------------------------------------------
-- 宝可梦详情 / 捕获弹窗
--------------------------------------------------------------------
-- 主面板常驻用的两个前向声明：主面板开着时，从它上面点开的子面板 / 捕获卡
-- 关掉后要回到主面板（旧版每个按钮都先 UIManager:close(self) 把自己关了，
-- 于是每次都得重新从菜单一路点回来）。HOME_PANEL 记录当前那一个实例。
-- 声明必须放在 MonDialog 之前：捕获卡关闭时也要刷新垫在下面的主面板，
-- 否则买完额外捕获回主面板，糖果和图鉴还停在捕获前的数字。
local HOME_PANEL
local refreshHomePanel

local MonDialog = InputContainer:extend{
    mon = nil,
    info = nil,
    plugin = nil,
    banner = nil,
    is_duplicate = false,
    is_shiny = false,
}

function MonDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    -- 逃生通道：点击卡片外关闭 / 滑动任意方向关闭 / 摇晃阶段点击跳过动画
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = full },
        }
        self.ges_events.SwipeClose = {
            GestureRange:new{ ges = "swipe", range = full },
        }
    end

    self.phase = self.banner and 0 or 1   -- 0: 精灵球摇晃中  1: 揭晓
    self.anim_step = 0
    self._anim_seq = 0
    self.closed = false
    self.frame_w = math.min(math.floor(sw * 0.88), Screen:scaleBySize(470))
    self.pad = Screen:scaleBySize(14)
    self:rebuild()
    if self.phase == 0 then
        self:_scheduleAnim()
    end
end

local BALL_FRAMES = {
    "ball_mid.png", "ball_l.png", "ball_mid.png",
    "ball_r.png", "ball_mid.png", "ball_l.png", "ball_r.png",
}

function MonDialog:_decoIcon(name, size)
    return ImageWidget:new{
        file = decoPath(self.plugin, name),
        width = Screen:scaleBySize(size),
        height = Screen:scaleBySize(size),
        scale_factor = 0,
        alpha = true,
    }
end

function MonDialog:_freeContent()
    if self[1] then
        pcall(function() self[1]:free(true) end)
        self[1] = nil
    end
end

function MonDialog:rebuild()
    self:_freeContent()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- 每次重建都重取屏幕尺寸（旋转/窗口变化后也能正确居中）
    self.dimen = Geom:new{ w = sw, h = sh }
    local mon = self.mon
    local caught = self.info ~= nil
    -- 已进化：卡片展示进化形态（图鉴格子仍显示基础形态）
    local dm = mon
    if self.info and self.info.evo and DEX_BY_ID[self.info.evo] then
        dm = DEX_BY_ID[self.info.evo]
    end
    -- 分支进化待选择：在捕获卡上亲自点选形态
    local pending = self.info and self.info.pending_evo or nil
    local frame_w = self.frame_w
    local pad = self.pad
    local rows = VerticalGroup:new{ align = "center" }
    local show_shiny = (self.is_shiny or (self.info and self.info.shiny)) and true or false

    if self.phase == 0 then
        -- 阶段一：精灵球左右摇晃，制造期待感
        local ball_size = Screen:scaleBySize(130)
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        table.insert(rows, ImageWidget:new{
            file = decoPath(self.plugin, BALL_FRAMES[self.anim_step % #BALL_FRAMES + 1]),
            width = ball_size,
            height = ball_size,
            scale_factor = 0,
            alpha = true,
        })
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(rows, makeCuteText(
            self.is_duplicate and "熟悉的身影出现了…" or string.format("野生的%s出现了！", mon.name),
            21, true))
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(rows, makeText("……", "smallinfofont", false, Blitbuffer.COLOR_GRAY))
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    else
        -- 阶段二：揭晓
        local img_size = math.min(frame_w - 2 * pad - Screen:scaleBySize(30),
            math.floor(sh * 0.33))

        local banner_text = pending and "它似乎在寻找进化的方向……" or self.banner
        if banner_text then
            table.insert(rows, HorizontalGroup:new{
                align = "center",
                self:_decoIcon("sparkle.png", 15),
                HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                self:_decoIcon("heart.png", 18),
                HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                self:_decoIcon("sparkle.png", 15),
            })
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })
            table.insert(rows, makeWrappedText(banner_text, cuteFace(21), true,
                pending and RGB.grape or (show_shiny and RGB.gold or nil),
                frame_w - 2 * pad - Screen:scaleBySize(6)))
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        elseif not caught then
            table.insert(rows, self:_decoIcon("paw.png", 20))
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        end

        -- 闪光个体直接用官方 shiny 配色立绘，颜色和普通个体明显不同
        if show_shiny then
            table.insert(rows, HorizontalGroup:new{
                align = "center",
                self:_decoIcon("sparkle.png", 26),
                ImageWidget:new{
                    file = spritePath(self.plugin, dm, "big", true),
                    width = img_size,
                    height = img_size,
                    scale_factor = 0,
                    alpha = true,
                },
                self:_decoIcon("sparkle.png", 26),
            })
        else
            table.insert(rows, ImageWidget:new{
                file = spritePath(self.plugin, dm, caught and "big" or "sil"),
                width = img_size,
                height = img_size,
                scale_factor = 0,
                alpha = true,
            })
        end
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })

        table.insert(rows, makeCuteText(string.format("No.%04d　%s", dm.id, dm.name), 20, true))
        if dm ~= mon then
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
            table.insert(rows, makeText(string.format("由 %s 进化而来", mon.name),
                "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5))
        end
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })

        -- 闪光个体的专属小行
        if show_shiny then
            table.insert(rows, HorizontalGroup:new{
                align = "center",
                self:_decoIcon("sparkle.png", 13),
                HorizontalSpan:new{ width = Screen:scaleBySize(5) },
                makeCuteText("闪闪发光的珍贵个体！", 16, false, RGB.gold),
                HorizontalSpan:new{ width = Screen:scaleBySize(5) },
                self:_decoIcon("sparkle.png", 13),
            })
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })
        end

        -- 彩色属性徽章（彩屏 Kaleido 3 上显示为标准属性色圆角小标签）
        local chip_group = HorizontalGroup:new{ align = "center" }
        for ti, tname in ipairs(dm.types) do
            if ti > 1 then
                table.insert(chip_group, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
            end
            local tc = TYPE_COLORS[tname] or { Blitbuffer.COLOR_GRAY_5, Blitbuffer.COLOR_WHITE }
            table.insert(chip_group, FrameContainer:new{
                padding = Screen:scaleBySize(2),
                margin = 0,
                bordersize = 0,
                radius = Screen:scaleBySize(6),
                background = tc[1],
                makeText(tname, "xx_smallinfofont", false, tc[2]),
            })
        end
        table.insert(rows, chip_group)
        -- 稀有度按档位上色：传说金 / 稀有蓝 / 少见绿 / 常见灰
        local RARITY_RGB = {
            legendary = RGB.gold,
            rare = RGB.water_blue,
            uncommon = RGB.leaf_green,
        }
        local rarity_row = HorizontalGroup:new{ align = "center" }
        table.insert(rarity_row, makeText("稀有度：", "xx_smallinfofont"))
        table.insert(rarity_row, makeText(RARITY_LABEL[dm.rarity] or "常见",
            "xx_smallinfofont", true, RARITY_RGB[dm.rarity] or Blitbuffer.COLOR_GRAY))
        table.insert(rarity_row, makeText(string.format("　·　第 %d 世代（%s）",
            dm.gen, GEN_LABEL[dm.gen] or "?"), "xx_smallinfofont"))
        table.insert(rows, rarity_row)

        -- 分支进化选择：点一下亲自决定它的方向（伊布 8 分支两列四行也放得下）
        if pending then
            local btn_rows = {}
            local row_btns = {}
            for _, kid in ipairs(pending) do
                local km = DEX_BY_ID[kid]
                if km then
                    row_btns[#row_btns + 1] = {
                        text = string.format("%s（%s）", km.name, km.types[1] or "?"),
                        callback = function()
                            self.info.evo = kid
                            self.info.pending_evo = nil
                            -- 玩法行为接入等级：选择进化 +EVO_XP（仅真实存档，预览不结算）
                            if self.plugin.caught[mon.id] == self.info then
                                self.plugin.catch_xp
                                    = (self.plugin.catch_xp or 0) + EVO_XP
                                self.plugin:_bumpDayCount("evo")  -- 委托「让 1 只宝可梦进化」
                                self.plugin:_checkLevelUp(0)
                            end
                            self.plugin:save()
                            self.banner = string.format("进化了！%s 进化成了 %s！",
                                mon.name, km.name)
                            self:rebuild()
                        end,
                    }
                    if #row_btns == 2 then
                        btn_rows[#btn_rows + 1] = row_btns
                        row_btns = {}
                    end
                end
            end
            if #row_btns > 0 then
                btn_rows[#btn_rows + 1] = row_btns
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
            table.insert(rows, makeButtonRows(btn_rows, frame_w - 2 * pad))
        end

        if caught then
            local date_txt = fmtDateCN(self.info.date) or self.info.date or "—"
            local txt
            if self.info.book and self.info.book ~= "" then
                txt = string.format("%s 读《%s》时初次相遇",
                    date_txt, shortBook(self.info.book))
            else
                txt = string.format("捕获于 %s", date_txt)
            end
            if (self.info.count or 1) > 1 then
                txt = txt .. string.format("　·　已相遇 %d 次", self.info.count)
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })
            -- 长句自动折行（日期+书名可能很长，绝不许超出卡片边框）
            table.insert(rows, makeWrappedText(txt,
                Font:getFace("xx_smallinfofont"), false, Blitbuffer.COLOR_GRAY_5,
                frame_w - 2 * pad - Screen:scaleBySize(6)))
        else
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })
            table.insert(rows, makeWrappedText("还没遇见过它，继续读书就有缘分～",
                cuteFace(16), false, Blitbuffer.COLOR_GRAY_5,
                frame_w - 2 * pad - Screen:scaleBySize(6)))
        end

        -- 图鉴进度（仅捕获弹窗）
        if self.banner then
            local caught_n = self.plugin:countCaught()
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
            table.insert(rows, PillBar:new{
                width = frame_w - 2 * pad - Screen:scaleBySize(4),
                height = Screen:scaleBySize(9),
                percentage = caught_n / TOTAL,
                fillcolor = show_shiny and RGB.gold or RGB.poke_red,
            })
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            table.insert(rows, makeText(string.format("图鉴 %d / %d · 完成 %.1f%%",
                caught_n, TOTAL, caught_n / TOTAL * 100), "xx_smallinfofont", false,
                Blitbuffer.COLOR_GRAY_5))
        end

        -- 按钮：用自制按钮，尺寸可控，不会再被挤丢
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        local btn_w = math.floor((frame_w - 2 * pad - Screen:scaleBySize(12)) / 2)
        local btn_h = Screen:scaleBySize(44)
        if self.banner then
            local row = HorizontalGroup:new{ align = "center" }
            table.insert(row, makeFlatButton("查看图鉴", function()
                self:onClose()
                self.plugin:openPokedex()
            end, btn_w, btn_h, { color = RGB.water_blue }))
            table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(12) })
            table.insert(row, makeFlatButton("收下啦～", function()
                self:onClose()
            end, btn_w, btn_h))
            table.insert(rows, row)
        else
            table.insert(rows, makeFlatButton("关闭", function()
                self:onClose()
            end, frame_w - 2 * pad, btn_h))
        end
    end

    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = show_shiny and RGB.gold
            or (self.banner and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_GRAY_5),
        background = Blitbuffer.COLOR_WHITE,
        centerRowsInFrame(rows, frame_w - 2 * pad),
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        frame,
    }
    -- 记录卡片在屏幕上的实际位置（居中），供「点卡片外关闭」判断
    local fsize = frame:getSize()
    self.frame_dimen = Geom:new{
        x = math.floor((sw - fsize.w) / 2),
        y = math.floor((sh - fsize.h) / 2),
        w = fsize.w,
        h = fsize.h,
    }
    UIManager:setDirty(self, "ui")
end

function MonDialog:onShow()
    -- 弹窗出现时丢弃已在输入队列里的手势（比如触发奖励的那次翻页点击），防止误触
    Input:inhibitInputUntil(true)
end

function MonDialog:onTapClose(arg, ges)
    if self.phase == 0 then
        -- 摇晃阶段：点任意处跳过动画，直接揭晓
        self:_skipAnim()
        return true
    end
    -- 揭晓阶段：点卡片外面关闭（卡片内交给按钮处理）
    if not self.frame_dimen or not ges.pos
            or ges.pos:notIntersectWith(self.frame_dimen) then
        self:onClose()
    end
    return true
end

function MonDialog:onSwipeClose(arg, ges)
    if self.phase == 0 then
        self:_skipAnim()
    else
        self:onClose()
    end
    return true
end

function MonDialog:_skipAnim()
    if self.phase ~= 0 then return end
    self._anim_seq = self._anim_seq + 1   -- 终止摇晃动画链
    self.phase = 1
    self.banner = self.is_duplicate and "是熟悉的老朋友呀～" or "恭喜！图鉴 +1"
    self:rebuild()
end

function MonDialog:_scheduleAnim()
    self._anim_seq = self._anim_seq + 1
    local seq = self._anim_seq
    local function step()
        if self.closed or seq ~= self._anim_seq then return end
        local ok, err = pcall(function()
            self.anim_step = self.anim_step + 1
            if self.anim_step >= #BALL_FRAMES then
                self.phase = 1
                self.banner = self.is_duplicate and "是熟悉的老朋友呀～" or "恭喜！图鉴 +1"
                self:rebuild()
            else
                self:rebuild()
                UIManager:scheduleIn(0.32, step)
            end
        end)
        if not ok then
            -- 动画出错也必须揭晓，绝不能把用户卡在摇晃页
            logger.err("pokemon: ball anim failed:", err)
            self.phase = 1
            self.banner = self.is_duplicate and "是熟悉的老朋友呀～" or "恭喜！图鉴 +1"
            self:rebuild()
        end
    end
    UIManager:scheduleIn(0.32, step)
    -- 保险丝：万一动画链意外中断，4 秒后强制揭晓
    UIManager:scheduleIn(4, function()
        if not self.closed and self.phase == 0 then
            self:_skipAnim()
        end
    end)
end

function MonDialog:onClose()
    self.closed = true
    self._anim_seq = self._anim_seq + 1
    -- 捕获会改糖果 / 图鉴 / 好感 / 委托进度：主面板若垫在下面，先按新数据重建
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 全屏白底信息弹窗（替代 InfoMessage）
--------------------------------------------------------------------
-- InfoMessage 是半透明浮窗：浮在书页上时白底刷不实，
-- 实机会透出正文残影。改为整屏白底 + 居中卡片，从根源杜绝。

local PokemonInfoView = InputContainer:extend{
    title = nil,
    text = nil,
    timeout = nil,      -- 秒，nil 表示不自动关闭
    _closed = false,
}

function PokemonInfoView:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(16)
    local frame_w = math.min(math.floor(sw * 0.88), Screen:scaleBySize(560))
    local inner_w = frame_w - 2 * pad

    local rows = VerticalGroup:new{ align = "center" }
    if self.title then
        -- 标题强制按卡片宽度居中（不依赖 VerticalGroup 自身对齐）
        local tt = makeCuteText(self.title, 22, true, RGB.poke_red)
        local th = tt:getSize().h
        table.insert(rows, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = th },
            tt,
        })
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    end
    -- 正文按条目拆行 → 每行包 CenterContainer 强制居中，
    -- 这样每条记录都以卡片中线为轴，视觉上真正居中（不是顶满左右两边）
    local face = Font:getFace("smallinfofont")
    local text_vg = VerticalGroup:new{ align = "center" }
    for _, ln in ipairs(splitCenteredLines(self.text or "", inner_w, face, false)) do
        local tw = TextWidget:new{
            text = ln, face = face, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local lh = tw:getSize().h
        table.insert(text_vg, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = lh },
            tw,
        })
    end
    table.insert(rows, text_vg)
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(rows, makeButtonRows({ {
        { text = "知道啦", callback = function() self:onClose() end },
    } }, inner_w))

    -- 整屏白底 + 固定宽度卡片（旧版实机验证过的结构，见 PokemonPanelView 注释）
    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = RGB.poke_red,
        background = Blitbuffer.COLOR_WHITE,
        rows,
    }
    local fsize = frame:getSize()
    self.frame_dimen = Geom:new{
        x = math.floor((sw - fsize.w) / 2),
        y = math.floor((sh - fsize.h) / 2),
        w = fsize.w, h = fsize.h,
    }
    self[1] = FrameContainer:new{
        width = sw,
        height = sh,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = self.dimen,
            frame,
        },
    }
    if self.timeout then
        UIManager:scheduleIn(self.timeout, function()
            if not self._closed then self:onClose() end
        end)
    end
    -- 开窗后补一次全刷，彻底清掉书页痕迹
    UIManager:scheduleIn(0.35, fullRefreshScreen)
end

function PokemonInfoView:onTapClose(arg, ges)
    self:onClose()
    return true
end

function PokemonInfoView:onClose()
    if self._closed then return true end
    self._closed = true
    -- 下面垫着主面板时先把它的数字重建好，再关自己，这样重绘一次就是新数据
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 阶段奖励弹窗（里程碑 / 地区图鉴完成）
--------------------------------------------------------------------

-- 通用：记录弹窗卡片在屏幕上的实际位置（居中），供「点卡片外关闭」判断
local function recordFrameDimen(dialog, frame, sw, sh)
    local fsize = frame:getSize()
    dialog.frame_dimen = Geom:new{
        x = math.floor((sw - fsize.w) / 2),
        y = math.floor((sh - fsize.h) / 2),
        w = fsize.w,
        h = fsize.h,
    }
end

-- 通用兜底：点弹窗卡片外面 = 关闭。
-- KOReader 事件先给子控件（按钮优先处理），没人处理才到这里的 onTapClose，
-- 所以不会影响卡片内按钮的点击。
local function addTapOutsideClose(dialog)
    if not Device:isTouchDevice() then return end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    dialog.ges_events.TapClose = {
        GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } },
    }
    dialog.onTapClose = function(d, _arg, ges)
        local fd = d.frame_dimen
        if not fd or not ges.pos or ges.pos:notIntersectWith(fd) then
            d:onClose()
        end
        return true   -- 吞掉事件，防止穿透到阅读界面
    end
end

local AchievementDialog = InputContainer:extend{
    plugin = nil,
    item = nil,   -- { type = "count", n = 100 } 或 { type = "gen", gen = 1 }
}

function AchievementDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    addTapOutsideClose(self)
    self:rebuild()
end

function AchievementDialog:rebuild()
    local item = self.item
    -- 每次重建都重取屏幕尺寸，保证居中不跑偏
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    local title, line2, medal_file, title_rgb
    if item.type == "gen" then
        title = "地区图鉴完成！"
        line2 = string.format("第 %d 世代（%s）的 %d 只全部集齐！",
            item.gen, GEN_LABEL[item.gen] or "?", GEN_TOTAL[item.gen] or 0)
        medal_file = "medal_gen.png"
        title_rgb = RGB.water_blue
    elseif item.type == "streak" then
        title = "连续阅读达成！"
        line2 = string.format("已经连续 %d 天完成每日目标啦～", item.n)
        medal_file = "medal_streak.png"
        title_rgb = RGB.orange
    elseif item.type == "combo" then
        title = "捕手连击！"
        line2 = string.format("连续 %d 次捕获都是新面孔！\n这份好运和坚持，太了不起啦～", item.n)
        medal_file = "medal_level.png"
        title_rgb = RGB.grape
    elseif item.type == "level" then
        title = "训练家等级提升！"
        line2 = string.format("Lv.%d %s\n再接再厉，向下一个等级出发～",
            item.level, levelTitle(item.level))
        medal_file = "medal_level.png"
        title_rgb = RGB.grape
    else
        title = "里程碑达成！"
        line2 = string.format("已经收集了 %d 只小伙伴啦～", item.n)
        medal_file = "medal_count.png"
        title_rgb = RGB.gold
    end

    local caught_n = self.plugin:countCaught()
    local frame_w = math.min(math.floor(Screen:getWidth() * 0.82), Screen:scaleBySize(430))
    local pad = Screen:scaleBySize(14)
    local rows = VerticalGroup:new{ align = "center" }

    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(rows, ImageWidget:new{
        file = decoPath(self.plugin, medal_file),
        width = Screen:scaleBySize(84),
        height = Screen:scaleBySize(84),
        scale_factor = 0,
        alpha = true,
    })
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(rows, makeCuteText(title, 22, true, title_rgb))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(rows, makeCuteText(line2, 17, false))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    table.insert(rows, PillBar:new{
        width = frame_w - 2 * pad - Screen:scaleBySize(4),
        height = Screen:scaleBySize(9),
        percentage = caught_n / TOTAL,
        fillcolor = title_rgb,
    })
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(rows, makeText(string.format("图鉴 %d / %d · 完成 %.1f%%",
        caught_n, TOTAL, caught_n / TOTAL * 100), "xx_smallinfofont", false,
        Blitbuffer.COLOR_GRAY_5))

    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(rows, makeButtonRows({ {
        { text = "太棒了！", callback = function() UIManager:close(self) end },
    } }, frame_w - 2 * pad))

    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = Blitbuffer.COLOR_GRAY_4,
        background = Blitbuffer.COLOR_WHITE,
        centerRowsInFrame(rows, frame_w - 2 * pad),
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        frame,
    }
    recordFrameDimen(self, frame, Screen:getWidth(), Screen:getHeight())
    UIManager:setDirty(self, "ui")
end

function AchievementDialog:onClose()
    -- 主面板若垫在下面，先按新数据重建，回去就能看到最新数字
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 我的奖章：彩色奖章陈列墙
--------------------------------------------------------------------

local MedalsDialog = InputContainer:extend{
    plugin = nil,
    preview_all = false,   -- 调试预览：全部按已获得的彩色样子显示
}

function MedalsDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    addTapOutsideClose(self)
    self:rebuild()
end

function MedalsDialog:rebuild()
    local p = self.plugin
    -- 每次重建都重取屏幕尺寸，保证居中不跑偏
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    local frame_w = math.min(math.floor(Screen:getWidth() * 0.90), Screen:scaleBySize(540))
    local pad = Screen:scaleBySize(14)
    -- 自适应奖章图标：小屏放不下 6 行时自动缩小
    local icon = Screen:scaleBySize(42)
    local rows_n = math.ceil((#MILESTONES + #STREAK_MILESTONES + #COMBO_MILESTONES + 9) / 4)
    local function rowH()
        return icon + Screen:scaleBySize(2) + Screen:scaleBySize(18) + Screen:scaleBySize(8)
    end
    while rows_n * rowH() + Screen:scaleBySize(150) > Screen:getHeight()
            and icon > Screen:scaleBySize(22) do
        icon = icon - Screen:scaleBySize(2)
    end
    local gap = Screen:scaleBySize(10)
    local cols = 4

    -- 三类奖章：金色=收集里程碑 / 橙色=连续达标 / 蓝色=世代图鉴
    local items = {}
    for _i, m in ipairs(MILESTONES) do
        items[#items + 1] = { key = "m_" .. m, label = m .. " 只",
            file = "medal_count.png", color = RGB.gold }
    end
    for _i, m in ipairs(STREAK_MILESTONES) do
        items[#items + 1] = { key = "s_" .. m, label = m .. " 天",
            file = "medal_streak.png", color = RGB.orange }
    end
    for _i, m in ipairs(COMBO_MILESTONES) do
        items[#items + 1] = { key = "c_" .. m, label = m .. " 连",
            file = "medal_level.png", color = RGB.grape }
    end
    for gen = 1, 9 do
        items[#items + 1] = { key = "g_" .. gen, label = "第" .. gen .. "代",
            file = "medal_gen.png", color = RGB.water_blue }
    end

    local rows = VerticalGroup:new{ align = "center" }
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    local earned_n = self.preview_all and #items or p:countMedals()
    table.insert(rows, makeCuteText(string.format("我的奖章 %d / %d%s",
        earned_n, #items, self.preview_all and "（预览）" or ""),
        21, true, RGB.poke_red))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
    table.insert(rows, makeText("金色收集 · 橙色连续 · 紫色连击 · 蓝色图鉴", "xx_smallinfofont", false,
        Blitbuffer.COLOR_GRAY_5))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(12) })

    for start = 1, #items, cols do
        local row = HorizontalGroup:new{ align = "top" }
        for k = 0, cols - 1 do
            if k > 0 then
                table.insert(row, HorizontalSpan:new{ width = gap })
            end
            local it = items[start + k]
            if it then
                local earned = self.preview_all
                    or (p.milestones[it.key] and true or false)
                table.insert(row, VerticalGroup:new{
                    align = "center",
                    ImageWidget:new{
                        file = decoPath(p, earned and it.file or "medal_locked.png"),
                        width = icon,
                        height = icon,
                        scale_factor = 0,
                        alpha = true,
                    },
                    VerticalSpan:new{ width = Screen:scaleBySize(2) },
                    makeCuteText(it.label, 13, false,
                        earned and it.color or Blitbuffer.COLOR_GRAY_7),
                })
            else
                table.insert(row, HorizontalSpan:new{ width = icon })
            end
        end
        table.insert(rows, row)
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end

    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(rows, makeButtonRows({ {
        { text = "收好啦", callback = function() UIManager:close(self) end },
    } }, frame_w - 2 * pad))

    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = Blitbuffer.COLOR_GRAY_4,
        background = Blitbuffer.COLOR_WHITE,
        centerRowsInFrame(rows, frame_w - 2 * pad),
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        frame,
    }
    recordFrameDimen(self, frame, Screen:getWidth(), Screen:getHeight())
    UIManager:setDirty(self, "ui")
end

function MedalsDialog:onClose()
    -- 主面板若垫在下面，先按新数据重建，回去就能看到最新数字
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 每日目标自定义弹窗（拉杆）
--------------------------------------------------------------------

local GoalDialog = InputContainer:extend{
    plugin = nil,
}

function GoalDialog:init()
    local sw = Screen:getWidth()
    self.dimen = Geom:new{ w = sw, h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self.frame_w = math.min(math.floor(sw * 0.86), Screen:scaleBySize(460))
    self.pad = Screen:scaleBySize(14)
    self.value = math.min(math.max(math.floor(self.plugin.goal / 60), 5), 120)
    addTapOutsideClose(self)
    self:rebuild()
end

function GoalDialog:rebuild()
    local frame_w = self.frame_w
    local pad = self.pad
    -- 每次重建都重取屏幕尺寸，保证居中不跑偏
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    local inner_w = frame_w - 2 * pad
    local rows = VerticalGroup:new{ align = "center" }

    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(rows, makeCuteText("每日阅读目标", 21, true))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
    table.insert(rows, makeText("拖动圆点或直接点轨道，调好点保存", "xx_smallinfofont", false,
        Blitbuffer.COLOR_GRAY_5))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    -- 当前值（固定高度，更新时不跳版），精灵球红更醒目
    self.value_text = makeCuteText(string.format("%d 分钟", self.value), 24, true, RGB.poke_red)
    table.insert(rows, CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(36) },
        self.value_text,
    })
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })

    self.slider = GoalSlider:new{
        width = inner_w - Screen:scaleBySize(8),
        min = 5, max = 120, step = 5,
        value = self.value,
        on_value_change = function(v)
            self.value = v
            self.value_text:setText(string.format("%d 分钟", v))
            UIManager:setDirty(self, "ui")
        end,
    }
    table.insert(rows, self.slider)
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    -- 常用预设快捷按钮
    local presets = HorizontalGroup:new{ align = "center" }
    for i, m in ipairs({ 15, 20, 30, 45, 60 }) do
        if i > 1 then
            table.insert(presets, HorizontalSpan:new{ width = Screen:scaleBySize(5) })
        end
        table.insert(presets, Button:new{
            text = tostring(m),
            text_font_face = "xx_smallinfofont",
            bordersize = Screen:scaleBySize(1),
            radius = Screen:scaleBySize(9),
            padding = Screen:scaleBySize(3),
            callback = function() self.slider:setValue(m) end,
            show_parent = self,
        })
    end
    table.insert(rows, presets)
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    table.insert(rows, makeButtonRows({
        { { text = "取消", callback = function() self:onClose() end } },
        { { text = "保存", color = RGB.water_blue, callback = function()
            self.plugin.goal = self.value * 60
            self.plugin:save()
            self:onClose()
            UIManager:show(InfoMessage:new{
                text = string.format("好哒！以后每天读满 %d 分钟就会有小惊喜～", self.value),
                timeout = 4,
            })
        end } },
    }, inner_w))

    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = Blitbuffer.COLOR_GRAY_5,
        background = Blitbuffer.COLOR_WHITE,
        centerRowsInFrame(rows, inner_w),
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, frame }
    recordFrameDimen(self, frame, Screen:getWidth(), Screen:getHeight())
    UIManager:setDirty(self, "ui")
end

function GoalDialog:onClose()
    -- 点弹窗外/返回键关闭时，如果改了数值还没保存，追问一下，防止白调
    if self.value * 60 ~= self.plugin.goal then
        local v = self.value
        UIManager:show(ConfirmBox:new{
            text = string.format("新的目标 %d 分钟还没保存，要保存吗？", v),
            ok_text = "保存",
            cancel_text = "不保存",
            ok_callback = function()
                self.plugin.goal = v * 60
                self.plugin:save()
                -- 目标存下来后主面板的"每日目标"和底部提示都变了，一并刷新
                if refreshHomePanel then refreshHomePanel() end
            end,
        })
    end
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 阅读周报弹窗（最近 7 天柱状图）
--------------------------------------------------------------------

-- 纯绘制的柱状图：data = { { label, mins } ... }
local WeeklyBars = Widget:extend{
    width = nil,
    height = nil,
    data = nil,
}

function WeeklyBars:getSize()
    if not self.dimen then
        self.dimen = Geom:new{ w = self.width, h = self.height }
    end
    return self.dimen
end

function WeeklyBars:paintTo(bb, x, y)
    local n = self.data and #self.data or 0
    if n == 0 then return end
    local gap = Screen:scaleBySize(7)
    local bar_w = math.floor((self.width - (n - 1) * gap) / n)
    local max_mins = 1
    for _i, item in ipairs(self.data) do
        max_mins = math.max(max_mins, item.mins)
    end
    local radius = Screen:scaleBySize(3)
    for i, item in ipairs(self.data) do
        local bx = x + (i - 1) * (bar_w + gap)
        local bh = math.max(Screen:scaleBySize(3),
            math.floor(self.height * item.mins / max_mins))
        -- 彩色柱：今天=精灵球红；达标=绿；未达标=蓝
        local color
        if item.today then
            color = RGB.poke_red
        elseif item.goal_mins and item.mins >= item.goal_mins then
            color = RGB.leaf_green
        else
            color = RGB.water_blue
        end
        bb:paintRoundedRect(bx, y + self.height - bh, bar_w, bh, color, radius)
    end
end

local WeeklyDialog = InputContainer:extend{
    plugin = nil,
}

function WeeklyDialog:init()
    local sw = Screen:getWidth()
    self.dimen = Geom:new{ w = sw, h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self.frame_w = math.min(math.floor(sw * 0.86), Screen:scaleBySize(470))
    self.pad = Screen:scaleBySize(14)
    addTapOutsideClose(self)
    self:rebuild()
end

function WeeklyDialog:rebuild()
    local frame_w = self.frame_w
    local pad = self.pad
    -- 每次重建都重取屏幕尺寸，保证居中不跑偏
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    local inner_w = frame_w - 2 * pad
    local chart_w = inner_w - Screen:scaleBySize(12)
    local chart_h = Screen:scaleBySize(88)

    -- 最近 7 天数据
    local goal_mins = math.floor(self.plugin.goal / 60)
    local data = {}
    local week_total = 0
    local week_met = 0
    for i = 6, 0, -1 do
        local t = self.plugin:_now() - i * 86400
        local mins = math.floor((self.plugin.daily[os.date("%Y-%m-%d", t)] or 0) / 60)
        local wd = tonumber(os.date("%w", t))
        local label = ({ "日", "一", "二", "三", "四", "五", "六" })[wd + 1]
        if i == 0 then label = "今天" end
        data[#data + 1] = { label = label, mins = mins, today = (i == 0),
            goal_mins = goal_mins }
        week_total = week_total + mins
        if mins >= goal_mins then week_met = week_met + 1 end
    end

    local rows = VerticalGroup:new{ align = "center" }
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(rows, makeCuteText("阅读周报", 21, true))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    table.insert(rows, WeeklyBars:new{
        width = chart_w,
        height = chart_h,
        data = data,
    })
    -- 柱子下方的日期标签（与柱子等宽对齐）
    local gap = Screen:scaleBySize(7)
    local bar_w = math.floor((chart_w - (#data - 1) * gap) / #data)
    local labels = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(data) do
        if i > 1 then
            table.insert(labels, HorizontalSpan:new{ width = gap })
        end
        table.insert(labels, CenterContainer:new{
            dimen = Geom:new{ w = bar_w, h = Screen:scaleBySize(18) },
            makeText(item.label, "xx_smallinfofont", item.today or false),
        })
    end
    table.insert(rows, labels)
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(5) })

    -- 彩色图例
    local legend = HorizontalGroup:new{ align = "center" }
    local function legendDot(color, text)
        table.insert(legend, makeText("●", "xx_smallinfofont", false, color))
        table.insert(legend, HorizontalSpan:new{ width = Screen:scaleBySize(2) })
        table.insert(legend, makeText(text, "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5))
        table.insert(legend, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
    end
    legendDot(RGB.leaf_green, "达标")
    legendDot(RGB.water_blue, "未达标")
    legendDot(RGB.poke_red, "今天")
    table.insert(rows, legend)
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })

    local today_mins = data[#data].mins
    local today_line
    if self.plugin.award_date == self.plugin:_today() then
        today_line = string.format("今天读了 %d 分钟，伙伴已经到手啦 ★", today_mins)
    elseif today_mins >= math.floor(self.plugin.goal / 60) then
        today_line = string.format("今天读了 %d 分钟，达标啦！", today_mins)
    else
        today_line = string.format("今天读了 %d 分钟，还差 %d 分钟达标",
            today_mins, math.max(math.floor(self.plugin.goal / 60) - today_mins, 0))
    end
    table.insert(rows, makeWrappedText(today_line, cuteFace(17), false, nil,
        inner_w - Screen:scaleBySize(4)))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(3) })
    table.insert(rows, makeWrappedText(string.format("本周达标 %d 天　·　共读 %d 小时 %d 分钟　·　连续 %d 天",
        week_met, math.floor(week_total / 60), week_total % 60, self.plugin.streak_count or 0),
        Font:getFace("xx_smallinfofont"), false, Blitbuffer.COLOR_GRAY_5,
        inner_w - Screen:scaleBySize(4)))
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    table.insert(rows, makeButtonRows({ {
        { text = "调整目标", callback = function()
            UIManager:close(self)
            UIManager:show(GoalDialog:new{ plugin = self.plugin })
        end },
        { text = "关闭", callback = function() UIManager:close(self) end },
    } }, inner_w))

    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad,
        margin = 0,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(14),
        color = Blitbuffer.COLOR_GRAY_5,
        background = Blitbuffer.COLOR_WHITE,
        centerRowsInFrame(rows, inner_w),
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, frame }
    recordFrameDimen(self, frame, Screen:getWidth(), Screen:getHeight())
    UIManager:setDirty(self, "ui")
end

function WeeklyDialog:onClose()
    -- 主面板若垫在下面，先按新数据重建，回去就能看到最新数字
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 图鉴主界面
--------------------------------------------------------------------

local PokedexView = InputContainer:extend{
    plugin = nil,
    filter = "all",   -- all | caught | uncaught
    gen = 0,          -- 0 = 全部世代
    page = 1,
    cols = 4,
    rows = 4,
}

function PokedexView:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.NextPage = { { Input.group.PgFwd } }
        self.key_events.PrevPage = { { Input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
        -- 边缘点击翻页：这台机器上滑动事件进不来（原因待日志定位），
        -- 但点击是可靠的 —— 点屏幕左侧 1/5 = 上一页，右侧 1/5 = 下一页
        self.ges_events.EdgeTap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
        -- 双保险：某些固件/补丁环境下 ges_events 收不到 swipe，
        -- 再走 KOReader 官方推荐的 touch zone 通道（本控件只在栈顶时才会被触发）
        pcall(function()
            self:registerTouchZones({
                {
                    id = "pokemon_dex_swipe",
                    ges = "swipe",
                    screen_zone = {
                        ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                    },
                    handler = function(ges)
                        logger.info("Pokemon: zone swipe dir=", tostring(ges and ges.direction))
                        return self:onSwipe(nil, ges)
                    end,
                },
            })
        end)
    end
    self:rebuild()
    -- 全屏打开时也补一次全刷：翻页栏/进度区偶发残影
    UIManager:scheduleIn(0.35, fullRefreshScreen)
end

function PokedexView:getFilteredList()
    -- 缓存筛选结果：翻页时不重复遍历 1025 只全图鉴
    local key = tostring(self.gen) .. ":" .. tostring(self.filter)
    if self._list_key == key and self._list then
        return self._list
    end
    local list = {}
    local caught = self.plugin.caught
    for _i, mon in ipairs(DEX) do
        if self.gen == 0 or mon.gen == self.gen then
            local is_caught = caught[mon.id] ~= nil
            if self.filter == "all"
                or (self.filter == "caught" and is_caught)
                or (self.filter == "uncaught" and not is_caught) then
                list[#list + 1] = mon
            end
        end
    end
    self._list_key = key
    self._list = list
    return list
end

function PokedexView:getPageCount(list)
    local per_page = self.cols * self.rows
    return math.max(1, math.ceil(#list / per_page))
end

function PokedexView:gotoPage(page)
    local list = self:getFilteredList()
    local pages = self:getPageCount(list)
    page = math.min(math.max(1, page), pages)
    if page == self.page then
        return
    end
    self.page = page
    self:rebuild()
end

function PokedexView:setGen(gen)
    if gen < 0 then gen = 9 end
    if gen > 9 then gen = 0 end
    if gen == self.gen then return end
    self.gen = gen
    self.page = 1
    self:rebuild()
end

function PokedexView:cycleFilter()
    local order = { "all", "caught", "uncaught" }
    local idx = 1
    for i, v in ipairs(order) do
        if v == self.filter then idx = i end
    end
    self.filter = order[idx % #order + 1]
    self.page = 1
    self:rebuild()
end

function PokedexView:filterLabel()
    return ({ all = "全部", caught = "已收集", uncaught = "未收集" })[self.filter]
end

function PokedexView:rebuild()
    local caught_n = self.plugin:countCaught()
    local list = self:getFilteredList()
    local pages = self:getPageCount(list)
    self.page = math.min(math.max(1, self.page), pages)

    local outer = Screen:scaleBySize(8)
    local gap = Screen:scaleBySize(4)

    local title_text
    if self.shiny_mode then
        title_text = string.format("闪光图鉴 ◆　%d / %d · %s",
            self.plugin:countShiny(), TOTAL, BUILD_TAG)
    else
        title_text = string.format("宝可梦图鉴　%d / %d · %s",
            caught_n, TOTAL, BUILD_TAG)
    end
    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = title_text,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- 今日阅读进度小卡片（可爱心形 + 胶囊进度条）
    local today = self.plugin:_today()
    local today_secs = self.plugin.daily[today] or 0
    local goal = self.plugin.goal or 1800
    local today_msg
    if self.plugin.award_date == today then
        today_msg = "今天的伙伴已经到手啦 ★"
    elseif today_secs <= 0 then
        -- 按小时轮换的鼓励语，读着不腻
        local qi = math.floor(os.time() / 3600) % #TODAY_QUOTES + 1
        today_msg = TODAY_QUOTES[qi]
    else
        today_msg = string.format("再读 %s 就能遇见新伙伴～",
            fmtDuration(math.max(goal - today_secs, 0)))
    end
    local card_w = self.dimen.w - 2 * outer
    local today_card = FrameContainer:new{
        width = card_w,
        padding = Screen:scaleBySize(6),
        margin = 0,
        bordersize = Screen:scaleBySize(1),
        radius = Screen:scaleBySize(12),
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            ImageWidget:new{
                file = decoPath(self.plugin, "heart.png"),
                width = Screen:scaleBySize(16),
                height = Screen:scaleBySize(16),
                scale_factor = 0,
                alpha = true,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            VerticalGroup:new{
                align = "left",
                makeCuteText(today_msg, 16, false),
                VerticalSpan:new{ width = Screen:scaleBySize(3) },
                PillBar:new{
                    width = card_w - Screen:scaleBySize(130),
                    height = Screen:scaleBySize(7),
                    percentage = math.min(today_secs / goal, 1),
                    fillcolor = RGB.poke_red,
                    ticks = true,
                },
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            makeText(today_secs > 0 and fmtDuration(today_secs) or "尚未开卷",
                "xx_smallinfofont", true, Blitbuffer.COLOR_GRAY_5),
        },
    }

    -- 世代 + 筛选：胶囊式选择器
    local gen_text = self.gen == 0 and "全世代" or string.format("第%d世代 · %s",
        self.gen, GEN_LABEL[self.gen] or "?")
    local gen_n = 0
    if self.gen ~= 0 then
        for _i, m in ipairs(DEX) do
            if m.gen == self.gen then gen_n = gen_n + 1 end
        end
        gen_text = gen_text .. string.format(" %d只", gen_n)
    end
    -- 世代标签垫一个圆角浅底，做成胶囊
    local gen_pill = FrameContainer:new{
        padding = Screen:scaleBySize(2),
        margin = 0,
        bordersize = 0,
        radius = Screen:scaleBySize(10),
        background = Blitbuffer.COLOR_WHITE,
        makeText(gen_text, "smallinfofont", true),
    }
    local header = HorizontalGroup:new{
        align = "center",
        Button:new{
            icon = "chevron.left",
            bordersize = 0,
            callback = function() self:setGen(self.gen - 1) end,
            show_parent = self,
        },
        gen_pill,
        Button:new{
            icon = "chevron.right",
            bordersize = 0,
            callback = function() self:setGen(self.gen + 1) end,
            show_parent = self,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        Button:new{
            text = self:filterLabel(),
            text_font_face = "xx_smallinfofont",
            bordersize = Screen:scaleBySize(1),
            radius = Screen:scaleBySize(8),
            padding = Screen:scaleBySize(4),
            callback = function() self:cycleFilter() end,
            show_parent = self,
        },
    }

    -- 进度条（圆角胶囊）
    local shiny_n = self.plugin:countShiny()
    local progress_pct, bar_color, sub_fmt
    if self.shiny_mode then
        progress_pct = shiny_n / TOTAL
        bar_color = RGB.gold
        sub_fmt = "当前筛选 %d 只　·　闪光完成度 %.1f%%　·　闪光率 1/" .. SHINY_RATE
    else
        progress_pct = caught_n / TOTAL
        bar_color = RGB.leaf_green
        sub_fmt = "当前筛选 %d 只　·　完成度 %.1f%%"
    end
    local pct_text = string.format("%.1f%%", progress_pct * 100)
    local bar_w = self.dimen.w - 2 * outer - Screen:scaleBySize(64)
    local progress = VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            align = "center",
            PillBar:new{
                width = bar_w,
                height = Screen:scaleBySize(8),
                percentage = progress_pct,
                fillcolor = bar_color,
                ticks = true,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            makeText(pct_text, "xx_smallinfofont", true,
                self.shiny_mode and RGB.gold or RGB.leaf_green),
        },
        VerticalSpan:new{ width = Screen:scaleBySize(3) },
        makeText(string.format(sub_fmt, #list, progress_pct * 100),
            "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5),
    }

    -- 页脚：首/上 页码 下/末 完全对称，保证居中
    local page_info = HorizontalGroup:new{
        align = "center",
        Button:new{
            icon = "chevron.first",
            bordersize = 0,
            callback = function() self:gotoPage(1) end,
            show_parent = self,
        },
        Button:new{
            icon = "chevron.left",
            bordersize = 0,
            callback = function() self:gotoPage(self.page - 1) end,
            show_parent = self,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        makeText(string.format("%d / %d", self.page, pages), "xx_smallinfofont", true),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        Button:new{
            icon = "chevron.right",
            bordersize = 0,
            callback = function() self:gotoPage(self.page + 1) end,
            show_parent = self,
        },
        Button:new{
            icon = "chevron.last",
            bordersize = 0,
            callback = function() self:gotoPage(pages) end,
            show_parent = self,
        },
    }

    -- 网格尺寸
    local title_h = self.title_bar:getHeight()
    local today_h = today_card:getSize().h + Screen:scaleBySize(4)
    local header_h = header:getSize().h + Screen:scaleBySize(4)
    local progress_h = progress:getSize().h + Screen:scaleBySize(4)
    local footer_h = page_info:getSize().h + Screen:scaleBySize(4)
    local avail_h = self.dimen.h - title_h - today_h - header_h - progress_h - footer_h - 2 * outer
    local cell_w = math.floor((self.dimen.w - 2 * outer - (self.cols - 1) * gap) / self.cols)
    local cell_h = math.floor((avail_h - (self.rows - 1) * gap) / self.rows)
    cell_h = math.min(cell_h, cell_w + Screen:scaleBySize(40))
    cell_h = math.max(cell_h, Screen:scaleBySize(80))
    cell_w = math.max(cell_w, Screen:scaleBySize(80))
    -- 文字行高实测反推立绘尺寸：固定预留（52/70px）在不同机型上不可靠，
    -- 预留不足时立绘会从卡片上下溢出（实机已复现）。直接量出三行文字真实高度。
    local pad_c = Screen:scaleBySize(3)
    local bs_c = Screen:scaleBySize(2) -- 按已捕获（边框最粗）预留，保证所有格子都放得下
    local face_small = Font:getFace("xx_smallinfofont")
    local probe = TextWidget:new{ text = "0000●●", face = face_small }
    local h_num = probe:getSize().h
    probe:free()
    probe = TextWidget:new{ text = "拉普拉斯 ×12", face = cuteFace(17) }
    local h_name = probe:getSize().h
    probe:free()
    probe = TextWidget:new{ text = "●", face = face_small }
    local h_evo = probe:getSize().h
    probe:free()
    local caption_h = Screen:scaleBySize(1) + h_num + h_name + h_evo
    local chrome_c = 2 * pad_c + 2 * bs_c
    local image_size = math.min(cell_w - chrome_c, cell_h - chrome_c - caption_h)
    image_size = math.max(image_size, Screen:scaleBySize(16))

    local grid = VerticalGroup:new{ align = "center" }
    local per_page = self.cols * self.rows
    local start_idx = (self.page - 1) * per_page + 1
    for r = 0, self.rows - 1 do
        local row = HorizontalGroup:new{ align = "center" }
        for c = 0, self.cols - 1 do
            local idx = start_idx + r * self.cols + c
            local mon = list[idx]
            if c > 0 then
                table.insert(row, HorizontalSpan:new{ width = gap })
            end
            if mon then
                table.insert(row, DexCell:new{
                    width = cell_w,
                    height = cell_h,
                    image_size = image_size,
                    mon = mon,
                    info = self.plugin.caught[mon.id],
                    plugin = self.plugin,
                    callback = function(tapped)
                        if self.shiny_mode then
                            self.plugin:showShinyDetail(tapped)
                        else
                            self.plugin:showDetail(tapped)
                        end
                    end,
                })
            else
                -- 空位也占格子：保证所有页的网格几何完全一致
                table.insert(row, HorizontalSpan:new{ width = cell_w })
            end
        end
        table.insert(grid, row)
        if r < self.rows - 1 then
            table.insert(grid, VerticalSpan:new{ width = gap })
        end
    end

    local content = VerticalGroup:new{
        align = "left",
        self.title_bar,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = today_h },
            today_card,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = header_h },
            header,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = progress_h },
            progress,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = avail_h },
            -- 网格垫一层浅灰圆角底板，卡片浮在上面更有层次
            FrameContainer:new{
                padding = Screen:scaleBySize(4),
                margin = 0,
                bordersize = 0,
                radius = Screen:scaleBySize(12),
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                grid,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = footer_h },
            page_info,
        },
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    UIManager:setDirty(self, "ui")
end

function PokedexView:_pageTo(page)
    -- 防抖：touch zone 和 ges_events 两条通道偶尔会对同一手势各触发一次，
    -- 1 秒内只接受一次翻页
    local now = os.time()
    if self._last_page_ts and now - self._last_page_ts < 1 then
        return
    end
    self._last_page_ts = now
    local before = self.page
    self:gotoPage(page)
    if self.page == before then
        -- 滑/点了但没页可翻：给个反馈，也证明手势通道是通的
        UIManager:show(InfoMessage:new{
            text = page > before and "已经是最后一页啦～" or "已经是第一页啦～",
            timeout = 1,
        })
    end
end

function PokedexView:onGesture(ev)
    -- 诊断日志：看手势到底有没有到达本控件（crash.log 可查）
    pcall(function()
        logger.info("Pokemon: dex onGesture ges=", tostring(ev and ev.ges),
            " dir=", tostring(ev and ev.direction))
    end)
    return InputContainer.onGesture(self, ev)
end

function PokedexView:onSwipe(_, ges)
    local dir = ges and ges.direction
    logger.info("Pokemon: dex swipe =", tostring(dir))
    -- 关键发现：这台机器的方向名是罗盘命名（west/east），
    -- 不是标准 KOReader 的 left/right —— 这就是滑动"没反应"的真正原因
    if dir == "west" or dir == "left" then
        self:_pageTo(self.page + 1)
        return true
    elseif dir == "east" or dir == "right" then
        self:_pageTo(self.page - 1)
        return true
    end
    return false
end

function PokedexView:onEdgeTap(_, ges)
    -- 边缘点击翻页：左侧 1/5 上一页，右侧 1/5 下一页；
    -- 卡片/按钮的点击由子控件优先处理，不会受影响
    local pos = ges and ges.pos
    if not pos then return false end
    local w = self.dimen.w
    if pos.x < w * 0.2 then
        self:_pageTo(self.page - 1)
        return true
    elseif pos.x > w * 0.8 then
        self:_pageTo(self.page + 1)
        return true
    end
    return false
end

function PokedexView:onNextPage()
    self:gotoPage(self.page + 1)
    return true
end

function PokedexView:onPrevPage()
    self:gotoPage(self.page - 1)
    return true
end

function PokedexView:onClose()
    -- 主面板若垫在下面，先按新数据重建，回去就能看到最新数字
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 闪光图鉴（独立入口，复用图鉴网格）
-- 状态：◆金色框=已遇闪光 / 白框彩色=已收集未闪光 / 剪影=未捕获
--------------------------------------------------------------------

local ShinyDexView = PokedexView:extend{
    shiny_mode = true,
    filter = "all",   -- all | shiny | no_shiny
}

function ShinyDexView:getFilteredList()
    local list = {}
    local caught = self.plugin.caught
    for _i, mon in ipairs(DEX) do
        if self.gen == 0 or mon.gen == self.gen then
            local info = caught[mon.id]
            local ok = true
            if self.filter == "shiny" then
                ok = info ~= nil and info.shiny or false
            elseif self.filter == "no_shiny" then
                ok = info ~= nil and not info.shiny
            end
            if ok then list[#list + 1] = mon end
        end
    end
    return list
end

function ShinyDexView:cycleFilter()
    local order = { "all", "shiny", "no_shiny" }
    local idx = 1
    for i, v in ipairs(order) do
        if v == self.filter then idx = i end
    end
    self.filter = order[idx % #order + 1]
    self.page = 1
    self:rebuild()
end

function ShinyDexView:filterLabel()
    return ({ all = "全部", shiny = "◆已有闪光", no_shiny = "尚无闪光" })[self.filter]
end

--------------------------------------------------------------------
-- 宝可梦主面板：替代原生菜单的可爱大按钮导航
--------------------------------------------------------------------

-- ====================================================================
-- v3 新增玩法：糖果 / 道具 / 伙伴好感 / 每日委托 / 阅读徽章
-- ====================================================================
local CANDY_CATCH   = 2      -- 捕获得糖
local CANDY_DUP     = 5      -- 重复捕获得糖
local CANDY_BOOK    = 20     -- 读完一本书
local BOOK_XP       = 300    -- 读完一本书的 XP
local AFF_HEARTS    = { 1800, 7200, 21600, 54000, 108000 } -- 30min / 2h / 6h / 15h / 30h
local AFF_BOND_DAYS = 7      -- 连伴满 7 天，好感涨速 ×1.2
-- 糖果罐货架。定价逻辑：糖果实际收入约 30/天，所以出口必须"能吃掉几十颗"，
-- 否则中后期糖果只是一个没有意义的数字（30 分钟/天到集齐约攒 3 万）。
-- 两条"必新"渠道刻意不同价：蛋是慢速廉价通道，额外捕获是即时高价通道。
local ITEM_DEFS = {
    { key = "inc",    name = "熏香",     cost = 20,  desc = "下一次捕获必出没见过的面孔" },
    { key = "hatch",  name = "孵化加速", cost = 100, desc = "蛋的孵化进度 +1 天，满 3 天孵出一只必新的宝可梦" },
    { key = "catch",  name = "额外捕获", cost = 300, desc = "立刻再抓一次，必出没见过的面孔" },
    { key = "rename", name = "改名卡",   cost = 10,  desc = "给伙伴改一个喜欢的名字" },
}
-- 额外捕获：当天第 1/2/3 次的价格，隔天归零。
-- 3 次 = 2100 糖/天封顶，防止囤糖的人一天把图鉴刷穿。
local SHOP_CATCH_PRICES = { 300, 600, 1200 }
-- 孵化加速：3 次 = 300 糖 = 一只必新 + 150 XP，与额外捕获首次同价，
-- 但必须跨 9 天才能凑出一只，所以不会变成"必新自动售货机"。
-- 之前是 15 糖且不限购（45 糖一只必新），模拟显示集齐时间会从 878 天砸到 503 天。
local HATCH_BUY_CD  = 3 * 86400   -- 每次购买后的冷却（秒）
-- 阅读徽章：门槛是「累计阅读小时」，与捕获运气无关
-- 每天 30 分钟 -> 第 10/20/40/70/110/160/260/390/580/800 天
-- 每天 2 小时  -> 第 3/5/10/18/28/40/65/98/145/200 天
-- 末枚对齐到 400h：按 30 分钟/天约 800 天，正好贴住图鉴集齐（约 790–870 天），
-- 不再是"徽章早早全亮、图鉴还要再跑 270 天"。
local BADGES = {
    { hours = 5,   name = "关都" },
    { hours = 10,  name = "城都" },
    { hours = 20,  name = "丰缘" },
    { hours = 35,  name = "神奥" },
    { hours = 55,  name = "合众" },
    { hours = 80,  name = "卡洛斯" },
    { hours = 130, name = "阿罗拉" },
    { hours = 195, name = "伽勒尔" },
    { hours = 290, name = "洗翠" },
    { hours = 400, name = "帕底亚" },
}

-- 委托池：全部挂在"本来就会做的事"上。
-- 原来只有 4 条却每天抽 3 条，等于天天重复，现在扩到 10 条（每天抽 3 条），
-- 组合数从 4 种变成 120 种，一周内基本不会重样。
-- 奖励按"期望 30 糖果/天"配平：旧版 4 选 3 的期望正好是 30，糖果经济模型
-- （candy_sim 的 quest=30）就是照这个数调平的，这里不能悄悄抬高，
-- 否则集齐天数会被糖果通胀打回去。纯经验项不占这份预算。
local QUEST_POOL = {
    { id = "read15",  text = "读满 15 分钟",          goal = 900,  unit = "分钟", xp = 30 },
    { id = "read30",  text = "读满 30 分钟",          goal = 1800, unit = "分钟", candy = 10, xp = 25 },
    { id = "read45",  text = "读满 45 分钟",          goal = 2700, unit = "分钟", candy = 12, xp = 30 },
    { id = "read60",  text = "读满 1 小时",            goal = 3600, unit = "分钟", candy = 15, xp = 35 },
    { id = "newbook", text = "打开一本没读过的书",     goal = 1,    unit = "本",   candy = 15 },
    { id = "finish",  text = "读完 1 本书",            goal = 1,    unit = "本",   candy = 20 },
    { id = "night",   text = "22 点后读 10 分钟",      goal = 600,  unit = "分钟", xp = 20 },
    { id = "morning", text = "早上 8 点前读 10 分钟",  goal = 600,  unit = "分钟", xp = 20 },
    { id = "dup",     text = "再遇见 1 次老朋友",      goal = 1,    unit = "次",   candy = 8 },
    { id = "evo",     text = "让 1 只宝可梦进化",      goal = 1,    unit = "次",   candy = 18 },
}

-- 委托按"类型组"抽：时间类一天只会出一条。
-- 否则「读满 15/30/45 分钟」三条同时抽中，读一次 45 分钟领三份奖励，
-- 等于凭空多出几十糖果。组内随机、组间各取一条，既防叠算又保证每天不重样。
local QUEST_FAMILY = {
    time  = { "read15", "read30", "read45", "read60" },
    book  = { "newbook", "finish" },
    clock = { "night", "morning" },
    act   = { "dup", "evo" },
}

-- 独立的小随机源：按日期洗牌，但绝不调用 math.randomseed。
-- 那个函数会把全局随机序列一起重置，而捕获稀有度、闪光判定都用 math.random：
-- 一旦被日期种子接管，同一天里重启 KOReader 就能复现同一串捕获结果。
-- 这里用 Park-Miller 线性同余，自带状态，跟全局随机互不干扰。
local function seededRng(seed)
    local s = math.floor(seed) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    s = (s * 16807) % 2147483647          -- 先迭代一次，弱化相邻种子的相关性
    return function(n)
        if n <= 1 then return 1 end
        s = (s * 16807) % 2147483647
        local r = math.floor(s / 2147483647 * n) + 1
        return math.min(r, n)
    end
end

-- 周常：每周固定一条，比日常重、奖励也重，用来给"这周有没有白读"一个答案。
-- 进度全部由已有数据推算（本周 daily / books_done / caught.date），不额外记状态。
-- 周常：每周固定一条，比日常重。奖励走"道具 + 经验"而不是糖果——
-- 糖果总量是调平过的（余额长期 50~220），每周再多给一百多会直接通胀；
-- 道具的零售价不低，但只是消耗品，不会把糖果曲线顶上去。
local WEEKLY_POOL = {
    { id = "w_read4h", text = "本周累计读满 4 小时", goal = 4 * 3600, unit = "分钟",
      xp = 150, item = "hatch", n = 1 },
    { id = "w_book2",  text = "本周读完 2 本书",     goal = 2,        unit = "本",
      xp = 120, item = "inc",   n = 2 },
    { id = "w_new10",  text = "本周新收集 10 只",    goal = 10,       unit = "只",
      xp = 150, item = "hatch", n = 1 },
    { id = "w_days5",  text = "本周有 5 天读满目标", goal = 5,        unit = "天",
      xp = 120, item = "inc",   n = 2 },
}

-- 新视图前向声明（定义在文件后部，HomePanel 运行时才使用）
local PokemonPanelView, PartnerPickerView

local HomePanel = InputContainer:extend{
    plugin = nil,
}

function HomePanel:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    HOME_PANEL = self
    -- 带实体返回键的机器（老 Kindle / Kobo）上，没有这条就只能靠下滑或底部按钮，
    -- 万一下滑手势没生效就会被困在主面板里。
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end
    self:rebuild()
    -- 打开后强制一次全刷：局部刷新在书页上开浮窗容易留残影
    UIManager:scheduleIn(0.35, fullRefreshScreen)
end

function HomePanel:rebuild()
    local p = self.plugin
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    local frame_w = math.min(math.floor(sw * 0.92), Screen:scaleBySize(620))
    local pad = Screen:scaleBySize(16)

    local caught_n = p:countCaught()
    local L = p:currentLevel()
    local partner = p:partnerMon()
    local q_done, q_total = p:questProgressCount()
    local badge_n = p:badgeCount()

    -- 两条细进度：把"还差多少"变成具体数字，不然只剩图鉴一条进度条，
    -- 徽章和等级对玩家来说完全不可预期。
    local hrs = p:readHours()
    local nb_i, nb, nb_need = p:nextBadge()
    local badge_pct, badge_txt
    if nb then
        local prev_h = (nb_i > 1) and BADGES[nb_i - 1].hours or 0
        badge_pct = (hrs - prev_h) / math.max(1, nb.hours - prev_h)
        badge_txt = string.format("还差 %.1f 小时", nb_need)
    else
        badge_pct, badge_txt = 1, "已全点亮"
    end
    local xp_now = p:totalXP()
    local lv_pct, lv_txt
    if L >= MAX_LEVEL then
        lv_pct, lv_txt = 1, "已满级"
    else
        local xp_cur, xp_nxt = xpForLevel(L), xpForLevel(L + 1)
        lv_pct = (xp_now - xp_cur) / math.max(1, xp_nxt - xp_cur)
        lv_txt = string.format("还差 %d XP", math.max(0, xp_nxt - xp_now))
    end

    local today = p:_today()
    local today_secs = p.daily[today] or 0
    local foot_line
    if p.award_date == today then
        foot_line = "今天的目标已经完成，蛋也在孵化中～"
    elseif today_secs <= 0 then
        foot_line = "翻开书，冒险就开始啦！"
    else
        foot_line = string.format("再读 %s 就能遇见新伙伴～",
            fmtDuration(math.max((p.goal or 1800) - today_secs, 0)))
    end

    local defs = {
        { icon = "ball_mid.png",     label = "我的图鉴",   cb = function() p:openPokedex() end },
        { icon = "star.png",         label = "闪光图鉴 ◆", cb = function() p:openShinyDex() end },
        { icon = "heart.png",        label = "换伙伴",     cb = function() p:openPartnerPicker() end },
        { icon = "ball_l.png",       label = "糖果罐",     cb = function() p:openCandyJar() end },
        { icon = "paw.png",          label = "每日委托",   cb = function() p:openQuests() end },
        { icon = "medal_count.png",  label = "阅读徽章",   cb = function() p:openBadges() end },
        -- 奖章 / 训练家状态 / 相遇记录 / 阅读周报 四格并成一格「训练家档案」：
        -- 12 格已经接近屏高极限，合并后省下 3 格给后续玩法。四个老面板仍从档案页进入。
        { icon = "medal.png",        label = "训练家档案", cb = function() p:openProfile() end },
        { icon = "ball_mid.png",     label = "每日目标",   cb = function() p:showGoalDialog() end },
        { icon = "star.png",         label = "玩法说明",   cb = function()
            UIManager:show(PokemonInfoView:new{
                title = "玩法说明",
                text = string.format(
                    "每天累计阅读满 %d 分钟，就会有一只宝可梦跳出来和你回家～\n\n"
                    .. "每次捕获有 1/%d 的概率遇到闪闪发光的珍贵闪光个体（◆）；连着 %d 次没遇到，下一次必定闪光。\n\n"
                    .. "同一只相遇 3 次会进化；每天读满目标还会孵蛋。\n\n"
                    .. "读完一本书会送保底稀有、糖果和熏香。糖果可以换道具。\n\n"
                    .. "伙伴陪你越久好感越高，好感会送糖果、提升闪光率。好感 ♥4 起，每天第一次捕获必定遇到没见过的面孔。\n\n"
                    .. "阅读徽章只看累计阅读时长（关都 5 小时一路到帕底亚 400 小时，共十枚），每点亮一枚都有奖励。\n\n"
                    .. RIGHTS_NOTICE,
                    math.floor((p.goal or 1800) / 60), SHINY_RATE, SHINY_PITY),
            })
        end },
    }
    -- 调试版专属：主面板直接给一个入口，不用去子菜单里翻
    if DEBUG_MODE then
        defs[#defs + 1] = { icon = "burst.png", label = "调试工具", cb = function()
            p:openDebugPanel()
        end }
    end

    -- k = 尺寸系数。按钮最多的一版（13 个）实测会超出屏幕高度，
    -- 底部的关闭按钮一被裁掉，全屏面板就再也关不掉了。
    -- 所以先按 1.0 构建，量实际高度，超高就整体缩小重建，最多收敛 3 次。
    local function build_rows(k)
        local cell_h  = math.max(math.floor(Screen:scaleBySize(62) * k), Screen:scaleBySize(34))
        local cell_wd = math.max(math.floor(19 * k), 13)  -- 字号是 pt，不能过 scaleBySize
        local icon_s  = math.floor(Screen:scaleBySize(26) * k)
        local sprite  = math.floor(Screen:scaleBySize(120) * k)
        local gap     = math.floor(Screen:scaleBySize(12) * k)
        local cols = 2

        local grid = VerticalGroup:new{ align = "center" }
        for r = 0, math.ceil(#defs / cols) - 1 do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 0, cols - 1 do
                local idx = r * cols + c + 1
                if c > 0 then
                    table.insert(row, HorizontalSpan:new{ width = gap })
                end
                local def = defs[idx]
                if def then
                    local cell_w = math.floor((frame_w - 2 * pad - (cols - 1) * gap) / cols)
                    local btn_dimen = Geom:new{ w = cell_w, h = cell_h }
                    local btn = InputContainer:new{ dimen = btn_dimen }
                    if Device:isTouchDevice() then
                        btn.ges_events.Tap = {
                            GestureRange:new{ ges = "tap", range = btn_dimen },
                        }
                    end
                    btn.onTap = function()
                        -- 主面板不关自己：留在栈里垫在子面板下面，
                        -- 子面板一关就自然回到这里（这就是"主面板常驻"）
                        def.cb()
                        return true
                    end
                    btn.onHold = function()
                        return true
                    end
                    local pad_i   = Screen:scaleBySize(6)
                    local icon_gap = Screen:scaleBySize(10)
                    local inner_w = cell_w - 2 * pad_i
                    local label_h = math.max(cell_h - 2 * pad_i, icon_s)
                    btn[1] = FrameContainer:new{
                        width = cell_w,
                        height = cell_h,
                        padding = pad_i,
                        margin = 0,
                        bordersize = Screen:scaleBySize(1),
                        radius = Screen:scaleBySize(12),
                        color = Blitbuffer.COLOR_GRAY_6,
                        background = Blitbuffer.COLOR_WHITE,
                        -- 内容必须贴左。FrameContainer 默认把内容整块居中，
                        -- 那样每格图标起点会随标签字数浮动，整列看着参差不齐。
                        LeftContainer:new{
                            dimen = Geom:new{ w = inner_w, h = label_h },
                            HorizontalGroup:new{
                                align = "center",
                                -- 图标占一个固定宽度的盒子并在盒内居中，文字紧随其后：
                                -- 于是同列所有图标的左缘一致、所有文字的左缘一致
                                CenterContainer:new{
                                    dimen = Geom:new{ w = icon_s, h = label_h },
                                    ImageWidget:new{
                                        file = decoPath(p, def.icon),
                                        width = icon_s,
                                        height = icon_s,
                                        scale_factor = 0,
                                        alpha = true,
                                    },
                                },
                                HorizontalSpan:new{ width = icon_gap },
                                makeCuteText(def.label, cell_wd, false),
                            },
                        },
                    }
                    table.insert(row, btn)
                else
                    table.insert(row, HorizontalSpan:new{ width = cell_w })
                end
            end
            table.insert(grid, row)
            if r < math.ceil(#defs / cols) - 1 then
                table.insert(grid, VerticalSpan:new{ width = gap })
            end
        end

        -- 头部：伙伴立绘 + 标题 + 等级/图鉴进度
        local partner_vg = VerticalGroup:new{ align = "center" }
        if partner then
            local pinfo = p.caught[partner.id]
            local aff_secs = p:affectionSecs(partner.id)
            local h = p:hearts(partner.id)
            table.insert(partner_vg, ImageWidget:new{
                file = spritePath(p, partner, "small", pinfo and pinfo.shiny),
                width = sprite,
                height = sprite,
                scale_factor = 0,
                alpha = true,
            })
            table.insert(partner_vg, makeCuteText(p:partnerName(partner),
                math.max(math.floor(19 * k), 14), true))
            table.insert(partner_vg, makeText(
                string.format("好感 %s　·　陪伴 %s%s",
                    string.rep("♥", h) .. string.rep("♡", 5 - h), fmtDuration(aff_secs),
                    p:titleText() and ("　·　" .. p:titleText()) or ""),
                "smallinfofont", false, Blitbuffer.COLOR_GRAY_4))
        end
        -- 一条细进度：左标签 + 中间进度条 + 右侧"还差多少"
        local bar_w = frame_w - 2 * pad
        local function progressRow(label, pct, right_txt, color)
            local lw = math.floor(bar_w * 0.13)
            local rw = math.floor(bar_w * 0.26)
            local bh = math.max(math.floor(Screen:scaleBySize(7) * k), Screen:scaleBySize(4))
            local bw = math.max(bar_w - lw - rw - Screen:scaleBySize(12),
                Screen:scaleBySize(40))
            -- 文字高度必须大于条形高度，否则 CenterContainer 按 bh 上报尺寸、
            -- 实际文字却高出几个像素，行高被算矮，字会压到下一行上。
            local ltw = makeText(label, "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5)
            local rtw = makeText(right_txt, "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_4)
            local th = math.max(bh, ltw:getSize().h, rtw:getSize().h)
            return HorizontalGroup:new{
                align = "center",
                CenterContainer:new{ dimen = Geom:new{ w = lw, h = th }, ltw },
                PillBar:new{ width = bw, height = bh, percentage = pct, fillcolor = color },
                CenterContainer:new{ dimen = Geom:new{ w = rw, h = th }, rtw },
            }
        end

        local header = VerticalGroup:new{
            align = "center",
            partner_vg,
            VerticalSpan:new{ width = math.max(math.floor(10 * k), 4) },
            makeText(string.format("Lv.%d %s　·　图鉴 %d / %d · %s",
                L, levelTitle(L), caught_n, TOTAL, BUILD_TAG), "xx_smallinfofont", false,
                Blitbuffer.COLOR_GRAY_5),
            VerticalSpan:new{ width = math.max(math.floor(4 * k), 1) },
            makeText(string.format("糖果 ● %d　·　委托 %d / %d　·　徽章 %d / %d",
                p.candies or 0, q_done, q_total, badge_n, #BADGES), "xx_smallinfofont", false,
                Blitbuffer.COLOR_GRAY_5),
            VerticalSpan:new{ width = math.max(math.floor(6 * k), 1) },
            PillBar:new{
                width = frame_w - 2 * pad,
                height = Screen:scaleBySize(8),
                percentage = caught_n / TOTAL,
                fillcolor = RGB.leaf_green,
                ticks = true,
            },
            VerticalSpan:new{ width = math.max(math.floor(5 * k), 2) },
            progressRow("徽章", badge_pct, badge_txt, RGB.water_blue),
            VerticalSpan:new{ width = math.max(math.floor(3 * k), 1) },
            progressRow("等级", lv_pct, lv_txt, RGB.poke_red),
        }

        return VerticalGroup:new{
            align = "center",
            header,
            VerticalSpan:new{ width = math.max(math.floor(12 * k), 4) },
            grid,
            VerticalSpan:new{ width = math.max(math.floor(10 * k), 4) },
            makeCuteText(foot_line, math.max(math.floor(17 * k), 13), false,
                Blitbuffer.COLOR_GRAY_5),
            VerticalSpan:new{ width = math.max(math.floor(8 * k), 3) },
            makeFlatButton("先去读书啦", function() self:onClose() end,
                frame_w - 2 * pad, math.max(math.floor(Screen:scaleBySize(46) * k),
                    Screen:scaleBySize(30))),
        }
    end

    -- 可用高度 = 屏幕 - 上下安全边距 - 外框自身的 padding 和边框（漏扣会让
    -- 收缩循环误判"放得下"，实际画出来超出屏幕）
    local bs = Screen:scaleBySize(2)
    local avail = sh - Screen:scaleBySize(24) - 2 * (pad + bs)
    local k, rows = 1.0, nil
    for _ = 1, 3 do
        rows = build_rows(k)
        local h = rows:getSize().h
        if h <= avail then break end
        k = math.max(k * (avail / h), 0.7)
        if DEBUG_MODE then
            logger.warn(string.format(
                "[pokemon] HomePanel 高度 %.0f > 可用 %.0f，缩小到 k=%.2f 重建", h, avail, k))
        end
    end

    -- 全屏白底垫在最下面：浮在书页上时不再透出正文，也不会留残影
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = self.dimen,
            FrameContainer:new{
                width = frame_w,
                padding = pad,
                margin = 0,
                bordersize = Screen:scaleBySize(2),
                radius = Screen:scaleBySize(16),
                color = RGB.poke_red,
                background = Blitbuffer.COLOR_WHITE,
                rows,
            },
        },
    }
    UIManager:setDirty(self, "ui")
end

-- 关闭兜底：从屏幕上往下滑（下拉手势）也能关，防止按钮万一又被裁掉时被困住
function HomePanel:onSwipe(arg, ges)
    if ges.direction == "south" then
        return self:onClose()
    end
end

function HomePanel:onClose()
    if HOME_PANEL == self then HOME_PANEL = nil end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

-- 子面板关闭前调用：把还垫在下面的主面板重建一遍（糖果/图鉴/委托数字都可能变了）
-- 主面板不在时什么都不做，从阅读菜单直接打开子面板的路径不受影响。
refreshHomePanel = function()
    local hp = HOME_PANEL
    if not hp then return end
    pcall(function()
        hp:rebuild()
        UIManager:setDirty(hp, "ui")
    end)
end

-- 打开主面板的唯一入口：已经开着就只刷新，不再 new 一个。
-- 直接 show(HomePanel:new{}) 会叠出第二层：关掉新的露出旧的，得连关两次
-- 才回得到书页（换伙伴、阅读菜单、调试预览三个入口原来都是这样）。
local function showHomePanel(p)
    if HOME_PANEL then
        pcall(function()
            HOME_PANEL:rebuild()
            UIManager:setDirty(HOME_PANEL, "ui")
        end)
        return
    end
    UIManager:show(HomePanel:new{ plugin = p })
end

--------------------------------------------------------------------
-- 插件主体
--------------------------------------------------------------------

local Pokemon = WidgetContainer:extend{
    name = "pokemon",
    is_doc_only = false,
    tick_interval = 20,          -- 计时粒度（秒）
    default_goal = 30 * 60,      -- 默认每日目标
    _seq = 0,
}

-- 顶部菜单标签自装：把 pokemon 小节写进 KOReader 的用户级菜单顺序文件。
-- 原理：ReaderMenu 建菜单时调用 MenuSorter:mergeAndSort("reader", item_table, order)，
-- 该函数会先读 <settings>/reader_menu_order.lua，读到就用它覆盖系统 order。
-- 所以插件自己写这份文件就能挂上顶部标签：不改系统文件，升级 KOReader 也不会丢。
-- 每次启动校验一次：系统菜单增删项后自动跟进；内容没变则不写盘（省闪存）。
function Pokemon:_ensureMenuOrder()
    local settings_dir = DataStorage:getSettingsDir()
    local user_path = settings_dir .. "/reader_menu_order.lua"
    local sys_path = DataStorage:getDataDir()
        .. "/frontend/ui/elements/reader_menu_order.lua"

    local function load_order(path)
        local fn = loadfile(path)
        if not fn then return nil end
        local ok, t = pcall(fn)
        if ok and type(t) == "table" then return t end
        return nil
    end

    local function read_file(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end

    -- 用户关掉了顶部标签：删掉插件自己写的那一份，菜单回到 KOReader 默认顺序
    if self.settings:readSetting("menu_tab", true) == false then
        local old = read_file(user_path)
        if old and old:find("宝可梦图鉴", 1, true) then
            os.remove(user_path)
        end
        self._menu_tab = false
        return
    end

    local order = load_order(sys_path)
    if not order then
        -- 安卓等前端不打在磁盘上的安装：改走 KOReader 的模块搜索路径
        -- （readermenu 本身就是 require("ui/elements/reader_menu_order") 拿的）
        local ok_sys, sys_tbl = pcall(require, "ui/elements/reader_menu_order")
        if ok_sys and type(sys_tbl) == "table" then
            order = {}
            for k, v in pairs(sys_tbl) do order[k] = v end
            logger.info("Pokemon: 系统菜单顺序经 require 取得")
        end
    end
    if not order then
        -- 最后兜底：内置 v2022.01 默认顶部结构。mergeAndSort 按 key 覆盖，
        -- 用户文件只含 KOMenu:menu_buttons + pokemon 两个 key 也能正确合并
        order = {
            ["KOMenu:menu_buttons"] = {
                "navi", "typeset", "setting", "tools",
                "search", "filemanager", "main",
            },
        }
        logger.warn("Pokemon: 系统菜单顺序不可读，使用内置默认顶部结构")
    end
    local user = load_order(user_path)
    -- 合并方向与 MenuSorter 一致：用户文件覆盖系统文件
    if order and user then
        for k, v in pairs(user) do order[k] = v end
    end
    order = order or user

    local buttons = order["KOMenu:menu_buttons"]
    if type(buttons) ~= "table" then
        buttons = {}
        order["KOMenu:menu_buttons"] = buttons
    end
    local has = false
    for _i, id in ipairs(buttons) do
        if id == "pokemon" then has = true break end
    end
    if not has then
        -- 插在「主菜单」（汉堡菜单）之前，其余按钮位置一律不动
        local pos = #buttons + 1
        for i, id in ipairs(buttons) do
            if id == "main" then pos = i break end
        end
        table.insert(buttons, pos, "pokemon")
    end

    local SECTIONS = {
        "pokemon_home", "pokemon_dex", "pokemon_shiny", "pokemon_partner",
        "pokemon_candy", "pokemon_quest", "pokemon_gym",
        "----------------------------",
        "pokemon_medals", "pokemon_stats", "pokemon_recent", "pokemon_weekly",
        "----------------------------",
        "pokemon_goal", "pokemon_save", "pokemon_help",
    }
    order.pokemon = SECTIONS

    -- 序列化 order（纯数据表：字符串键 + 字符串数组）
    local function q(s)
        return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
            if c == "\\" then return "\\\\"
            elseif c == '"' then return '\\"'
            elseif c == "\n" then return "\\n"
            elseif c == "\r" then return "\\r"
            elseif c == "\0" then return "\\0"
            else return string.format("\\%03d", string.byte(c)) end
        end) .. '"'
    end
    local function ser(v, ind)
        local t = type(v)
        if t == "string" then return q(v) end
        if t == "number" or t == "boolean" then return tostring(v) end
        if t ~= "table" then return "nil" end
        local pad = string.rep("    ", ind)
        local pad2 = string.rep("    ", ind + 1)
        local out = {}
        local n = #v
        for i = 1, n do
            out[#out + 1] = pad2 .. ser(v[i], ind + 1) .. ","
        end
        local keys = {}
        for k in pairs(v) do
            local is_arr = type(k) == "number" and k >= 1 and k <= n
                and k == math.floor(k)
            if not is_arr then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _i, k in ipairs(keys) do
            local key
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key = k
            else
                key = "[" .. ser(k, ind + 1) .. "]"
            end
            out[#out + 1] = pad2 .. key .. " = " .. ser(v[k], ind + 1) .. ","
        end
        if #out == 0 then return "{}" end
        return "{\n" .. table.concat(out, "\n") .. "\n" .. pad .. "}"
    end

    local body = "-- 本文件由「宝可梦图鉴」插件自动生成：把精灵球标签挂到阅读菜单顶部。\n"
        .. "-- 在插件里关掉顶部标签后本文件会被删除，菜单恢复 KOReader 默认顺序。\n"
        .. "return " .. ser(order, 0) .. "\n"

    if read_file(user_path) ~= body then
        local f = io.open(user_path, "w")
        if f then
            f:write(body)
            f:close()
            logger.info("Pokemon: 已写入菜单顺序文件 " .. user_path)
        else
            logger.warn("Pokemon: 菜单顺序文件写入失败，顶部标签降级")
            self._menu_tab = false
            return
        end
    end
    self._menu_tab = true

    -- 双保险（2026-10-27 PA6 实机定位）：有些 KOReader 构建根本不合并
    -- <settings>/reader_menu_order.lua —— 模块加载后 menu_buttons 仍是内置默认表，
    -- pokemon 小节也不存在，上面这份文件在那类机器上就是「写进没人读的文件」。
    -- 这类机器只能改内存里的模块表：readermenu 之后 require 到的就是同一张表
    -- 对象，改完立刻生效；不落盘、不碰系统安装目录。
    -- 支持读文件的机型上面已经生效，这里 has 判断为真，不会重复插入。
    local ok_mod, mod = pcall(require, "ui/elements/reader_menu_order")
    if ok_mod and type(mod) == "table" then
        local list = mod["KOMenu:menu_buttons"]
        if type(list) == "table" then
            local has_mod = false
            for _i, id in ipairs(list) do
                if id == "pokemon" then has_mod = true break end
            end
            if not has_mod then
                local pos_mod = #list + 1
                for i, id in ipairs(list) do
                    if id == "main" then pos_mod = i break end
                end
                table.insert(list, pos_mod, "pokemon")
            end
        end
        if type(mod.pokemon) ~= "table" then
            mod.pokemon = SECTIONS
        end
        logger.info("Pokemon: 顶部标签内存注入完成")
    else
        logger.warn("Pokemon: ui/elements/reader_menu_order 不可读，仅依赖菜单顺序文件")
    end

    logger.info("Pokemon: 顶部标签就绪")
end

function Pokemon:init()
    Pokemon._seq = Pokemon._seq + 1
    self._seq = Pokemon._seq

    -- 自装顶部标签图标：把精灵球 SVG 复制到 KOReader 用户图标目录
    -- 注意：DataStorage:getDataDir().."/icons" 是 IconWidget 搜索路径的
    -- 第一优先目录，必须每次启动都覆写——否则第一次装进去的旧图标
    -- 会永远霸占这个位置（实机已踩坑：图标换色不生效）
    pcall(function()
        local icon_dir = DataStorage:getDataDir() .. "/icons"
        local icon_file = icon_dir .. "/appbar.pokemon.svg"
        if lfs.attributes(icon_dir, "mode") ~= "directory" then
            lfs.mkdir(icon_dir)
        end
        local src = io.open(self.path .. "/appbar.pokemon.svg", "rb")
        if src then
            local data = src:read("*a")
            src:close()
            local dst = io.open(icon_file, "wb")
            if dst then
                dst:write(data)
                dst:close()
            end
        end
        logger.info("Pokemon: 图标自装完成 mode=" ..
            tostring(lfs.attributes(icon_file, "mode")) ..
            " resources=" .. tostring(lfs.attributes("resources/icons/mdlight/appbar.pokemon.svg", "mode")))
    end)

    self.settings_path = DataStorage:getSettingsDir() .. "/pokemon.lua"
    self.settings = LuaSettings:open(self.settings_path)
    self.caught = self.settings:readSetting("caught", {})
    self.daily = self.settings:readSetting("daily", {})
    self.total_secs = self.settings:readSetting("total_secs", 0)
    self.award_date = self.settings:readSetting("award_date", "")
    self.first_catch_date = self.settings:readSetting("first_catch_date", "")
    self.streak_count = self.settings:readSetting("streak_count", 0)
    self.streak_last = self.settings:readSetting("streak_last", "")
    self.combo = self.settings:readSetting("combo", 0)
    self.egg_progress = self.settings:readSetting("egg_progress", 0)
    self.egg_hatched = self.settings:readSetting("egg_hatched", 0)
    self.milestones = self.settings:readSetting("milestones", {})
    self.catch_xp = self.settings:readSetting("catch_xp", 0)
    self.level_seen = self.settings:readSetting("level_seen", 1)
    self.goal = self.settings:readSetting("daily_goal", self.default_goal)
    -- v3 新增状态
    self.candies = self.settings:readSetting("candies", 0)
    -- 糖果是"消耗型"数值，保存时必须按时间戳判断谁更新，
    -- 不能像捕获数那样取较大值——否则花掉的糖果每次存档都会被旧值顶回来
    self.candies_ts = self.settings:readSetting("candies_ts", 0)
    self.items = self.settings:readSetting("items", {})
    self.hatch_ts = self.settings:readSetting("hatch_ts", 0)
    self.catch_buy = self.settings:readSetting("catch_buy", {})
    self.shop_meta_ts = self.settings:readSetting("shop_meta_ts", 0)
    self.partner_id = self.settings:readSetting("partner_id", nil)
    self.affection = self.settings:readSetting("affection", {})
    self.books_done = self.settings:readSetting("books_done", {})
    self.books_all = self.settings:readSetting("books_all", {})
    self.quests = self.settings:readSetting("quests", {})
    self.badges = self.settings:readSetting("badges", {})
    self.night_secs = self.settings:readSetting("night_secs", {})
    self.morning_secs = self.settings:readSetting("morning_secs", {})
    self.day_counts = self.settings:readSetting("day_counts", {})
    self.weekly_claimed = self.settings:readSetting("weekly_claimed", "")
    self.shiny_pity = self.settings:readSetting("shiny_pity", 0)
    self.shiny_pity_ts = self.settings:readSetting("shiny_pity_ts", 0)
    self.partner_day = self.settings:readSetting("partner_day", "")
    self.partner_streak = self.settings:readSetting("partner_streak", 0)
    self.nicknames = self.settings:readSetting("nicknames", {})
    self.bak_date = self.settings:readSetting("bak_date", "")
    -- 时钟防呆：高水位时间戳只增不减；当前时钟比它早超容差 → 冻结
    local saved_max_ts = self.settings:readSetting("max_seen_ts", 0)
    local now_ts = os.time()
    self.max_ts = (saved_max_ts > now_ts) and saved_max_ts or now_ts
    self.clock_bad = (self.max_ts - now_ts) > CLOCK_BACK_TOLERANCE
    if self.clock_bad then
        self.frozen_ts = self.max_ts
        self.frozen_today = os.date("%Y-%m-%d", self.max_ts)
        logger.warn("Pokemon: 时钟回退检出 now=", now_ts, " max=", self.max_ts,
            " 冻结到 ", self.frozen_today)
    else
        self.frozen_ts = nil
        self.frozen_today = nil
    end
    self.last_save_ts = os.time()
    self.last_tick = nil
    self.suspended = false
    self.pending_award = nil
    self.pending_milestones = nil
    self.pokedex_view = nil

    -- 必须在 registerToMainMenu 之前跑：addToMainMenu 要据此决定
    -- 是注册顶部标签（pokemon / pokemon_* 一族），还是走「工具 → 更多工具」降级入口
    pcall(function() self:_ensureMenuOrder() end)

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- 存档自检：延后几秒，等界面起来再问，免得和启动过程抢屏幕
    if not self._bak_checked then
        self._bak_checked = true
        UIManager:scheduleIn(6, function()
            pcall(function() self:_bakCheck() end)
        end)
    end
    self:_scheduleTick()
end

--------------------------------------------------------------------
-- 计时
--------------------------------------------------------------------

function Pokemon:_scheduleTick()
    local seq = self._seq
    UIManager:scheduleIn(self.tick_interval, function()
        if seq ~= Pokemon._seq then
            return  -- 旧实例的定时链，作废
        end
        local ok, err = pcall(function() self:_tick() end)
        if not ok then
            logger.warn("pokemon: tick failed:", err)
        end
        self:_scheduleTick()
    end)
end

-- 「今天」统一入口：正常时走设备时钟；冻结时沿用高水位日期，
-- 所有按天结算（阅读分桶/奖励/委托/连击/伙伴天数）都必须走这里，
-- 直接调 os.date("%Y-%m-%d") 会在时钟回退时重复发奖。
function Pokemon:_today()
    return self.frozen_today or os.date("%Y-%m-%d")
end

-- 对应的时间戳版：冻结时返回高水位，供「昨天」和自然周计算使用
function Pokemon:_now()
    return self.frozen_ts or os.time()
end

function Pokemon:_tick()
    local now = time.now()
    local last = self.last_tick
    self.last_tick = now
    if not last then return end
    -- 注意：time.now() 返回的是 fts 定点时间（微秒刻度），不是秒！
    -- 差值必须用 time.to_s() 换算成秒，否则永远被当成异常间隔丢弃
    local delta_s = time.to_s(now - last)
    -- 休眠/挂起后时间会跳跃，异常间隔不计入
    if delta_s <= 0 or delta_s > self.tick_interval * 3 then return end
    if self.suspended then return end
    if not self.ui or not self.ui.document then return end
    self:_addTime(delta_s)
    -- 读完一本书检测：每 20 秒查一次进度（读的是内存里的 doc_settings，开销可忽略）
    self:_checkBookFinished()
end

function Pokemon:_addTime(delta)
    local today = self:_today()
    self.daily[today] = (self.daily[today] or 0) + delta
    self.total_secs = (self.total_secs or 0) + delta
    self:_trimDaily()
    -- 伙伴好感：陪伴时长累积（连伴满 7 天 ×1.2）
    self:_addAffection(delta)
    -- 夜间阅读统计（委托用）：22:00 ~ 次日 04:00
    local hour = tonumber(os.date("%H")) or 12
    if hour >= 22 or hour < 4 then
        self.night_secs[today] = (self.night_secs[today] or 0) + delta
    end
    -- 早起阅读统计（委托用）：00:00 ~ 08:00（含凌晨那一段，熬夜和早起都算）
    if hour < 8 then
        self.morning_secs = self.morning_secs or {}
        self.morning_secs[today] = (self.morning_secs[today] or 0) + delta
    end
    -- 记录读过的书（委托「打开一本没读过的书」）：books_all 的首次时间就是进度来源
    local path = self:_currentBookPath()
    if path and not self.books_all[path] then
        self.books_all[path] = os.time()
    end
    self:_questTick()
    -- 阅读徽章：累计时长到线就点亮
    self:_badgeCheck()
    if self.award_date ~= today and (self.daily[today] or 0) >= self.goal then
        self:_award(today)
    else
        -- 阅读分钟数增长也可能让等级提升
        self:_checkLevelUp(0)
    end
    if os.time() - self.last_save_ts > 120 then
        self:save()
    end
end

function Pokemon:_trimDaily()
    local cutoff = os.date("%Y-%m-%d", os.time() - 60 * 86400)
    for day in pairs(self.daily) do
        if day < cutoff then
            self.daily[day] = nil
        end
    end
end

--------------------------------------------------------------------
-- 捕获
--------------------------------------------------------------------

function Pokemon:countCaught()
    local n = 0
    for id in pairs(self.caught) do
        if DEX_BY_ID[id] then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------
-- 训练家等级：XP = 累计阅读分钟数 + 捕获 XP
--------------------------------------------------------------------

local CATCH_XP = { common = 10, uncommon = 20, rare = 50, legendary = 100 }

function Pokemon:totalXP()
    return math.floor((self.total_secs or 0) / 60) + (self.catch_xp or 0)
end

function Pokemon:currentLevel()
    local xp = self:totalXP()
    local L = 1
    while L < MAX_LEVEL and xp >= xpForLevel(L + 1) do
        L = L + 1
    end
    return L
end

function Pokemon:_checkLevelUp(offset)
    local L = self:currentLevel()
    if L > (self.level_seen or 1) then
        self.level_seen = L
        local item = { type = "level", level = L }
        if self.suspended then
            self.pending_milestones = self.pending_milestones or {}
            table.insert(self.pending_milestones, item)
        else
            -- 排在里程碑卡后面弹，避免叠屏
            self:_queueMilestonePopups({ item }, 1.5 + (offset or 0) * 2.4)
        end
        -- 每 5 级送一次额外捕获（同蛋孵化机制，不占当天名额）
        if L % 5 == 0 then
            local function try_bonus(retries)
                if self.suspended then
                    if retries > 0 then
                        UIManager:scheduleIn(8, function() try_bonus(retries - 1) end)
                    end
                    return
                end
                self:_award(self:_today(), false, "bonus")
            end
            UIManager:scheduleIn(9, function() try_bonus(12) end)
        end
    end
end

function Pokemon:_pickRandom(force_new)
    local new_pool, new_w = {}, 0
    local dup_pool = {}
    for _i, mon in ipairs(DEX) do
        local info = self.caught[mon.id]
        if info then
            -- 老朋友池：按相遇次数加权，越是旧相识越有缘分再遇
            dup_pool[#dup_pool + 1] = { mon = mon, w = info.count or 1 }
        else
            local w = RARITY_WEIGHT[mon.rarity] or 20
            new_pool[#new_pool + 1] = { mon = mon, w = w }
            new_w = new_w + w
        end
    end
    math.randomseed(os.time() + math.floor((time.now() % 1000) * 1000))
    -- 新池捕空 → 必是老朋友；普通捕获有 DUP_RATE 概率走老朋友池（蛋孵化除外）
    local want_dup = #new_pool == 0
        or (#dup_pool > 0 and not force_new and math.random() < DUP_RATE)
    if want_dup then
        local total = 0
        for _i, it in ipairs(dup_pool) do total = total + it.w end
        local r = math.random() * total
        for _i, it in ipairs(dup_pool) do
            r = r - it.w
            if r <= 0 then
                return it.mon, true
            end
        end
        return dup_pool[#dup_pool].mon, true
    end
    local r = math.random() * new_w
    for _i, item in ipairs(new_pool) do
        r = r - item.w
        if r <= 0 then
            return item.mon, false
        end
    end
    return new_pool[#new_pool].mon, false
end

-- 当前正在读的书名：元数据标题优先，没有就用文件名（捕获详情/闪光预览共用）
function Pokemon:_currentBookTitle()
    local ok, r = pcall(function()
        if self.ui and self.ui.document and self.ui.document.file then
            local props = self.ui.doc_props
            if props and props.title and props.title ~= "" then
                return props.title
            end
            local f = self.ui.document.file or ""
            local name = f:match("([^/\\]+)$") or f
            return (name:gsub("%.%w+$", ""))
        end
    end)
    if ok and r and r ~= "" then return r end
    return nil
end

-- 调试用：统计各素材目录的 PNG 数量，抽查标志性闪光图是否在位
function Pokemon:_checkAssets()
    local dirs = {
        { "普通立绘·大图", "/sprites/" },
        { "普通立绘·小图", "/sprites/small/" },
        { "闪光立绘·大图", "/sprites/shiny/" },
        { "闪光立绘·小图", "/sprites/shiny/small/" },
        { "剪影·大图", "/sprites/sil/" },
        { "剪影·小图", "/sprites/sil/small/" },
        { "装饰素材", "/deco/" },
    }
    local lines = {}
    local missing_dir = 0
    for _i, d in ipairs(dirs) do
        local p = self.path .. d[2]
        local n = 0
        local ok = pcall(function()
            for f in lfs.dir(p) do
                if f:match("%.png$") then n = n + 1 end
            end
        end)
        if ok then
            lines[#lines + 1] = string.format("%s：%d 张", d[1], n)
        else
            lines[#lines + 1] = string.format("%s：目录缺失！", d[1])
            missing_dir = missing_dir + 1
        end
    end
    lines[#lines + 1] = ""
    local spot = { 6, 25, 149, 251, 1025 }
    local miss = {}
    for _, id in ipairs(spot) do
        local sp = self.path .. string.format("/sprites/shiny/%04d.png", id)
        if lfs.attributes(sp, "mode") ~= "file" then
            miss[#miss + 1] = "#" .. id
        end
    end
    if #miss > 0 then
        lines[#lines + 1] = "标志性闪光图缺失：" .. table.concat(miss, " ")
    else
        lines[#lines + 1] = "标志性闪光图抽查：全部在位 OK"
    end
    lines[#lines + 1] = string.format("图鉴条目：%d 只", TOTAL)
    if missing_dir > 0 then
        lines[#lines + 1] = "结论：有目录缺失，请检查拷贝！"
    else
        lines[#lines + 1] = "结论：素材完整，可以放心玩～"
    end
    return table.concat(lines, "\n")
end

function Pokemon:_award(today, is_debug, src)
    -- 蛋孵出的必是新面孔，普通捕获有 DUP_RATE 概率再遇老朋友
    local mon, is_dup
    local partner_guard = false
    local incense_used = false
    if src == "book" then
        -- 读完一本书：保底稀有
        mon, is_dup = self:_pickLegendaryNew()
        if not mon then mon, is_dup = self:_pickRandom(true) end
    else
        local force_new = (src == "egg") or (src == "shop")
        -- 熏香：消耗一个，下一次捕获必出新面孔
        if not is_debug and src == nil and (self.items.inc or 0) > 0 then
            self.items.inc = self.items.inc - 1
            force_new = true
            incense_used = true
        end
        -- 好感 ♥4 奖励：当天第一次捕获必不重复。
        -- 一天只有一次机会，25% 的"老朋友"是纯粹的损耗，
        -- 让陪伴够久的伙伴帮你把这一次用在没见过的面孔上。
        if not force_new and (self.first_catch_date or "") ~= today
            and self:hearts(self:partnerId()) >= 4 then
            force_new = true
            partner_guard = true
        end
        mon, is_dup = self:_pickRandom(force_new)
    end
    if not mon then return end
    -- 捕捉详情：记录相遇时正在读的书（标题优先，无元数据则用文件名）
    local book = self:_currentBookTitle()
    -- 闪光判定：极小概率遇到闪闪发光的特殊个体（好感 ♥3/♥5 会小幅提升）
    -- 保底：连续 SHINY_PITY 次没出，这一次必出。计数器每次捕获 +1，出闪即清零。
    self.shiny_pity = (tonumber(self.shiny_pity) or 0) + 1
    self.shiny_pity_ts = os.time()
    local is_shiny = self.shiny_pity >= SHINY_PITY
        or math.random(1, self:shinyRate()) == 1
    if is_shiny then self.shiny_pity = 0 end
    local info = self.caught[mon.id]
    local just_evolved
    if info then
        info.count = (info.count or 1) + 1
        info.ts = os.time()
        if is_shiny then info.shiny = true end
    else
        -- 新捕获：必须把 info 回赋，否则后面 info.evo 会索引 nil 直接崩掉 KOReader
        info = { date = today, ts = os.time(), count = 1,
            shiny = is_shiny, book = book }
        self.caught[mon.id] = info
    end
    -- 进化：同一只相遇满 EVO_STEP 次；单分支直接进化，多分支等玩家亲自选
    if not info.evo and (info.count or 1) >= EVO_STEP and EVO_NEXT[mon.id] then
        local kids = EVO_NEXT[mon.id]
        if #kids == 1 then
            info.evo = kids[1]
            just_evolved = kids[1]
        else
            info.pending_evo = kids
        end
    end
    -- 玩法行为接入等级：自动进化 +EVO_XP（分支自选的在选择时结算）
    if just_evolved and not is_debug then
        self.catch_xp = (self.catch_xp or 0) + EVO_XP
        self:_bumpDayCount("evo")         -- 委托「让 1 只宝可梦进化」
    end
    local egg_hatched_now
    if not is_debug then
        -- 今天已经捕获过（无论来源），♥4 的"首次必新"每天只给一次。
        -- 花糖果买的额外捕获本身必新，不该占用这个名额，否则先买再读的人
        -- 会发现当天那次免费捕获又可能撞老朋友。
        if src ~= "shop" then self.first_catch_date = today end
        if not src then
            self.award_date = today
            self:_updateStreak(today)
            -- 孵蛋：达标日进度 +1，攒满孵化（奖励一次额外捕获，不占当天名额）
            self.egg_progress = (self.egg_progress or 0) + 1
            if self.egg_progress >= EGG_DAYS then
                self.egg_progress = 0
                self.egg_hatched = (self.egg_hatched or 0) + 1
                egg_hatched_now = true
                self.catch_xp = (self.catch_xp or 0) + EGG_XP
            end
        end
        -- 捕手连击：连续捕新，再遇老朋友即断连
        if is_dup then
            self.combo = 0
            self:_bumpDayCount("dup")     -- 委托「再遇见 1 次老朋友」
        else
            self.combo = (self.combo or 0) + 1
        end
        -- 捕获 XP：按稀有度给分，闪光加成，重复减半
        local xp = CATCH_XP[mon.rarity] or 10
        if is_shiny then xp = xp + 50 end
        if is_dup then xp = math.floor(xp / 2) end
        self.catch_xp = (self.catch_xp or 0) + xp
        -- 糖果：捕获 +2，重复 +5；好感 ♥2 起每次再 +1
        local candy = is_dup and CANDY_DUP or CANDY_CATCH
        if self:hearts(self:partnerId()) >= 2 then candy = candy + 1 end
        self.candies = (self.candies or 0) + candy
    end
    self:save()
    local milestones = self:_collectMilestones()
    self:_checkLevelUp(#milestones)
    -- 捕获卡横幅：闪光 > 进化 > 蛋孵化 > 常规
    local banner
    if is_shiny then
        banner = "闪光！遇到了闪闪发光的它！"
    elseif just_evolved then
        banner = string.format("进化了！%s 进化成了 %s！",
            mon.name, (DEX_BY_ID[just_evolved] or mon).name)
    elseif src == "egg" then
        banner = "蛋孵化啦！是它钻了出来！"
    elseif src == "bonus" then
        banner = "等级奖励！额外送你一次捕获！"
    elseif src == "shop" then
        banner = "糖果换来的捕获！新的面孔出现了"
    elseif src == "book" then
        banner = "读完一本书！这只稀有伙伴被你的坚持吸引来了"
    elseif incense_used then
        banner = "熏香的香气引来了新的面孔！"
    elseif partner_guard then
        banner = "伙伴帮你守住了新面孔，这次不会白跑～"
    elseif is_dup then
        banner = "是熟悉的老朋友呀～"
    else
        banner = "恭喜！图鉴 +1"
    end
    if self.suspended then
        self.pending_award = { mon = mon, is_dup = is_dup, is_shiny = is_shiny,
            banner = banner }
        if #milestones > 0 then
            self.pending_milestones = self.pending_milestones or {}
            for _i, m in ipairs(milestones) do
                table.insert(self.pending_milestones, m)
            end
        end
        return
    end
    self:showAward(mon, is_dup, is_shiny, banner)
    self:_queueMilestonePopups(milestones)
    -- 蛋孵化：稍后送出额外捕获（阅读界面挂起时等它回来再孵）
    if egg_hatched_now then
        local function try_hatch(retries)
            if self.suspended then
                if retries > 0 then
                    UIManager:scheduleIn(8, function() try_hatch(retries - 1) end)
                end
                return
            end
            self:_award(self:_today(), false, "egg")
        end
        UIManager:scheduleIn(6.5, function() try_hatch(12) end)
    end
end

-- 安全包装：捕获流程中任何未预期错误只记日志 + 轻提示，
-- 绝不能像之前那样（info 为 nil）把整个 KOReader 崩掉。
local _award_raw = Pokemon._award
function Pokemon:_award(today, is_debug, src)
    local ok, err = pcall(_award_raw, self, today, is_debug, src)
    if not ok then
        logger.err("pokemon: award failed:", err)
        pcall(function()
            UIManager:show(InfoMessage:new{
                text = "捕获过程出了点小差错，已安全跳过。\n（详情见 crash.log）",
                timeout = 4,
            })
        end)
    end
end

--------------------------------------------------------------------
-- 阶段性奖励
--------------------------------------------------------------------

function Pokemon:_genComplete(gen)
    for _i, mon in ipairs(DEX) do
        if mon.gen == gen and not self.caught[mon.id] then
            return false
        end
    end
    return true
end

-- 检查并标记新达成的里程碑 / 世代图鉴 / 连续达标，返回待弹出列表
function Pokemon:_collectMilestones()
    local n = self:countCaught()
    local pending = {}
    for _i, m in ipairs(MILESTONES) do
        if n >= m and not self.milestones["m_" .. m] then
            self.milestones["m_" .. m] = true
            pending[#pending + 1] = { type = "count", n = m }
        end
    end
    for _i, m in ipairs(STREAK_MILESTONES) do
        if (self.streak_count or 0) >= m and not self.milestones["s_" .. m] then
            self.milestones["s_" .. m] = true
            pending[#pending + 1] = { type = "streak", n = m }
        end
    end
    for _i, m in ipairs(COMBO_MILESTONES) do
        if (self.combo or 0) >= m and not self.milestones["c_" .. m] then
            self.milestones["c_" .. m] = true
            -- 玩法行为接入等级：连击达成 +COMBO_XP
            self.catch_xp = (self.catch_xp or 0) + COMBO_XP
            pending[#pending + 1] = { type = "combo", n = m }
        end
    end
    for gen = 1, 9 do
        if not self.milestones["g_" .. gen] and self:_genComplete(gen) then
            self.milestones["g_" .. gen] = true
            pending[#pending + 1] = { type = "gen", gen = gen }
        end
    end
    if #pending > 0 then
        self:save()
    end
    return pending
end

-- 成就卡逐个延迟弹出，避免和捕获卡叠在一起
function Pokemon:_queueMilestonePopups(list, base)
    if not list or #list == 0 then return end
    base = base or 1.5
    for i, item in ipairs(list) do
        UIManager:scheduleIn(base + (i - 1) * 2.4, function()
            if self.suspended then return end
            UIManager:show(AchievementDialog:new{ plugin = self, item = item })
        end)
    end
end

function Pokemon:_updateStreak(today)
    local yesterday = os.date("%Y-%m-%d", self:_now() - 86400)
    if self.streak_last == today then
        -- 同一天重复触发，保持不变
    elseif self.streak_last == yesterday then
        self.streak_count = (self.streak_count or 0) + 1
        self.streak_last = today
    else
        self.streak_count = 1
        self.streak_last = today
    end
end

function Pokemon:showAward(mon, is_dup, is_shiny, banner)
    local ok, err = pcall(function()
        UIManager:show(MonDialog:new{
            plugin = self,
            mon = mon,
            info = self.caught[mon.id],
            banner = banner or (is_shiny and "闪光！遇到了闪闪发光的它！"
                or (is_dup and "是熟悉的老朋友呀～" or "恭喜！图鉴 +1")),
            is_duplicate = is_dup,
            is_shiny = is_shiny or false,
        })
    end)
    if not ok then
        logger.warn("pokemon: show award failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format("捕获了 %s！", mon.name),
            timeout = 4,
        })
    end
end

function Pokemon:showDetail(mon)
    UIManager:show(MonDialog:new{
        plugin = self,
        mon = mon,
        info = self.caught[mon.id],
    })
end

--------------------------------------------------------------------
-- 存档备份与恢复
-- 存档只有 4KB 左右，滚动保留三份、每天最多写一次，开销可以忽略。
-- KOReader 自带的 .old 只保留一代，出问题后再保存一次就被坏数据覆盖，
-- 所以这里补一个"三天滚动 + 手动备份"的保险。
--------------------------------------------------------------------
local BAK_COUNT = 3

function Pokemon:bakPath(i)
    return DataStorage:getSettingsDir() .. string.format("/pokemon_bak%d.lua", i)
end

local function copyFile(src, dst)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if not data or #data < 16 then return false end
    local o = io.open(dst, "wb")
    if not o then return false end
    o:write(data)
    o:close()
    return true
end

-- 读一份备份的信息；文件不存在或解析不出内容（损坏）都返回 nil
function Pokemon:_bakInfo(path)
    if not path then return nil end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local ok, info = pcall(function()
        local st = LuaSettings:open(path)
        if not st then return nil end
        local caught = st:readSetting("caught", {})
        local n = 0
        for _ in pairs(caught or {}) do n = n + 1 end
        return {
            path = path,
            mtime = attr.modification or 0,
            caught = n,
            total = st:readSetting("total_secs", 0) or 0,
            candies = st:readSetting("candies", 0) or 0,
        }
    end)
    if not ok or not info then return nil end
    -- 空壳文件（0 只、0 秒）当成坏的，不拿它覆盖任何东西
    if info.caught == 0 and info.total == 0 then return nil end
    return info
end

-- 滚动备份：bak3←bak2←bak1←当前存档
function Pokemon:_bakRotate(force)
    local today = self:_today()
    if not force and self.bak_date == today then return false end
    if lfs.attributes(self.settings_path, "mode") ~= "file" then return false end
    os.remove(self:bakPath(BAK_COUNT))
    for i = BAK_COUNT - 1, 1, -1 do
        local from = self:bakPath(i)
        if lfs.attributes(from, "mode") == "file" then
            os.rename(from, self:bakPath(i + 1))
        end
    end
    local ok = copyFile(self.settings_path, self:bakPath(1))
    if ok then self.bak_date = today end
    if DEBUG_MODE then
        logger.warn(string.format("[pokemon] 备份%s %s → bak1", force and "（手动）" or "", today))
    end
    return ok
end

-- 启动时自检：图鉴只数比最近的备份少一半以上，判定为异常并询问
function Pokemon:_bakCheck()
    local cur = self:countCaught()
    for i = 1, BAK_COUNT do
        local bi = self:_bakInfo(self:bakPath(i))
        if bi and bi.caught >= 10 and cur < bi.caught * 0.5 then
            local when = os.date("%m 月 %d 日", bi.mtime)
            UIManager:show(PokemonPanelView:new{
                title = "存档好像出问题了",
                subtitle = string.format(
                    "当前图鉴 %d 只，%s 的备份有 %d 只。\n如果这不是你想要的，可以从备份恢复。",
                    cur, when, bi.caught),
                build = function(v, inner_w)
                    return makeButtonRows({
                        { { text = "从备份恢复", color = RGB.poke_red,
                            callback = function() v:onClose(); self:restoreFromBackup(i) end } },
                        { { text = "先不恢复", callback = function() v:onClose() end } },
                    }, inner_w)
                end,
            })
            return true
        end
    end
    return false
end

function Pokemon:restoreFromBackup(i)
    local bi = self:_bakInfo(self:bakPath(i))
    if not bi then
        UIManager:show(InfoMessage:new{ text = "这份备份读不出来，换一份试试。", timeout = 3 })
        return
    end
    UIManager:show(PokemonPanelView:new{
        title = "恢复存档",
        subtitle = string.format("%s · 图鉴 %d 只 · 糖果 %d\n恢复后当前进度会被这份备份覆盖",
            os.date("%m 月 %d 日 %H:%M", bi.mtime), bi.caught, bi.candies),
        build = function(v, inner_w)
            return makeButtonRows({
                { { text = "确认恢复", color = RGB.poke_red, callback = function()
                    -- 覆盖前先把现在这份留个底，万一恢复错了还能回来
                    copyFile(self.settings_path,
                        DataStorage:getSettingsDir() .. "/pokemon_before_restore.lua")
                    if copyFile(self:bakPath(i), self.settings_path) then
                        v:onClose()
                        UIManager:show(InfoMessage:new{
                            text = "已恢复，正在重启 KOReader…", timeout = 2 })
                        UIManager:scheduleIn(2, function()
                            local ok = pcall(function() UIManager:restartKOReader() end)
                            if not ok then
                                UIManager:show(InfoMessage:new{
                                    text = "请手动退出 KOReader 再打开，恢复才会生效",
                                    timeout = 6 })
                            end
                        end)
                    else
                        v:onClose()
                        UIManager:show(InfoMessage:new{ text = "恢复失败：写不进存档", timeout = 4 })
                    end
                end } },
                { { text = "再想想", callback = function() v:onClose() end } },
            }, inner_w)
        end,
    })
end

function Pokemon:openSaveManager()
    local cur = self:countCaught()
    UIManager:show(PokemonPanelView:new{
        title = "存档管理",
        subtitle = string.format("每天自动备份一份，保留 %d 份\n当前图鉴 %d 只", BAK_COUNT, cur),
        build = function(v, inner_w)
            local rows = VerticalGroup:new{ align = "center" }
            local items = {}
            for i = 1, BAK_COUNT do
                local bi = self:_bakInfo(self:bakPath(i))
                if bi then
                    items[#items + 1] = {
                        { text = string.format("备份%d %s · 图鉴%d",
                            i, os.date("%m-%d %H:%M", bi.mtime), bi.caught),
                          callback = function()
                              v:onClose()
                              self:restoreFromBackup(i)
                          end },
                    }
                end
            end
            if #items == 0 then
                table.insert(rows, makeText("还没有备份，点下面的按钮立刻存一份",
                    "smallinfofont", false, Blitbuffer.COLOR_GRAY_5))
            else
                table.insert(rows, makeButtonRows(items, inner_w))
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
            table.insert(rows, makeButtonRows({ {
                { text = "立即备份", color = RGB.water_blue, callback = function()
                    self:save()
                    local ok = self:_bakRotate(true)
                    v:onClose()
                    UIManager:show(InfoMessage:new{
                        text = ok and "已经存好一份了" or "备份失败，检查一下存储空间",
                        timeout = 3 })
                end },
            } }, inner_w))
            return rows
        end,
    })
end

--------------------------------------------------------------------
-- 保存
--------------------------------------------------------------------

function Pokemon:save()
    -- 与其他实例（文件管理器 / 阅读界面）安全合并，避免旧数据覆盖新捕获
    local disk = LuaSettings:open(self.settings_path)
    local disk_caught = disk:readSetting("caught", {})
    for id, info in pairs(disk_caught) do
        local mine = self.caught[id]
        if not mine or (info.ts or 0) > (mine.ts or 0) then
            self.caught[id] = info
        elseif info.count and mine.count and info.count > mine.count then
            mine.count = info.count
        end
    end
    local disk_daily = disk:readSetting("daily", {})
    for day, secs in pairs(disk_daily) do
        if (self.daily[day] or 0) < secs then
            self.daily[day] = secs
        end
    end
    self.total_secs = math.max(self.total_secs or 0, disk:readSetting("total_secs", 0) or 0)
    self.catch_xp = math.max(self.catch_xp or 0, disk:readSetting("catch_xp", 0) or 0)
    self.level_seen = math.max(self.level_seen or 1, disk:readSetting("level_seen", 1) or 1)
    local disk_award = disk:readSetting("award_date", "")
    if disk_award > (self.award_date or "") then
        self.award_date = disk_award
    end

    self.settings:saveSetting("caught", self.caught)
    self.settings:saveSetting("daily", self.daily)
    self.settings:saveSetting("total_secs", self.total_secs)
    self.settings:saveSetting("award_date", self.award_date)
    self.settings:saveSetting("first_catch_date", self.first_catch_date or "")
    self.settings:saveSetting("streak_count", self.streak_count)
    self.settings:saveSetting("streak_last", self.streak_last)
    self.settings:saveSetting("combo", self.combo)
    self.settings:saveSetting("egg_progress", self.egg_progress)
    self.settings:saveSetting("egg_hatched", self.egg_hatched)
    self.settings:saveSetting("milestones", self.milestones)
    self.settings:saveSetting("catch_xp", self.catch_xp)
    self.settings:saveSetting("level_seen", self.level_seen)
    self.settings:saveSetting("daily_goal", self.goal)
    -- v3 新增状态（数值类取较大值，避免多实例互相覆盖）
    -- 糖果例外：它是消耗型，只能按"谁最后改动"来合并。
    -- 之前这里写成 max()，导致买道具扣掉的糖果在 save() 里被磁盘旧值还原，
    -- 表现为"点了兑换，糖果一个都不少"。
    local disk_candies = disk:readSetting("candies", 0) or 0
    local disk_candies_ts = disk:readSetting("candies_ts", 0) or 0
    if disk_candies_ts > (self.candies_ts or 0) then
        -- 另一个实例（文件管理器/阅读界面）刚改过，以磁盘为准
        self.candies = disk_candies
        self.candies_ts = disk_candies_ts
    end
    local disk_aff = disk:readSetting("affection", {}) or {}
    for id, secs in pairs(disk_aff) do
        if (self.affection[id] or 0) < secs then self.affection[id] = secs end
    end
    -- 冷却与当天购买次数：合并规则不能用"取较大值"——
    -- 大于判断会把调试面板的"重置冷却"（hatch_ts=0）当场还原成旧时间戳，
    -- 表现为点了重置、再买还是提示"还要等 71 小时"。
    -- 改成看"商店状态最后修改时间"：谁最后改的听谁的。
    local disk_shop_ts = disk:readSetting("shop_meta_ts", 0) or 0
    if disk_shop_ts > (self.shop_meta_ts or 0) then
        -- 另一实例（文件管理器/阅读界面）刚改过，以磁盘为准
        self.hatch_ts = disk:readSetting("hatch_ts", 0) or 0
        local db = disk:readSetting("catch_buy", {})
        self.catch_buy = (type(db) == "table") and db or {}
        self.shop_meta_ts = disk_shop_ts
    end
    self.settings:saveSetting("candies", self.candies or 0)
    self.settings:saveSetting("candies_ts", self.candies_ts or 0)
    self.settings:saveSetting("items", self.items or {})
    self.settings:saveSetting("hatch_ts", self.hatch_ts or 0)
    self.settings:saveSetting("catch_buy", self.catch_buy or {})
    self.settings:saveSetting("shop_meta_ts", self.shop_meta_ts or 0)
    -- 闪光保底计数：出闪会把它清零，所以不能用"取较大值"合并
    -- （会把本地刚清零的 0 又还原成磁盘上的 199，下一次捕获立刻又"保底"）。
    -- 和商店状态一样，按最后修改时间判断谁更新。
    local disk_pity_ts = disk:readSetting("shiny_pity_ts", 0) or 0
    if disk_pity_ts > (self.shiny_pity_ts or 0) then
        self.shiny_pity = disk:readSetting("shiny_pity", 0) or 0
        self.shiny_pity_ts = disk_pity_ts
    end
    self.settings:saveSetting("shiny_pity", self.shiny_pity or 0)
    self.settings:saveSetting("shiny_pity_ts", self.shiny_pity_ts or 0)
    self.settings:saveSetting("partner_id", self.partner_id)
    self.settings:saveSetting("affection", self.affection or {})
    self.settings:saveSetting("books_done", self.books_done or {})
    self.settings:saveSetting("books_all", self.books_all or {})
    self.settings:saveSetting("quests", self.quests or {})
    self.settings:saveSetting("badges", self.badges or {})
    self.settings:saveSetting("night_secs", self.night_secs or {})
    self.settings:saveSetting("morning_secs", self.morning_secs or {})
    self.settings:saveSetting("day_counts", self.day_counts or {})
    self.settings:saveSetting("weekly_claimed", self.weekly_claimed or "")
    self.settings:saveSetting("partner_day", self.partner_day or "")
    self.settings:saveSetting("partner_streak", self.partner_streak or 0)
    self.settings:saveSetting("nicknames", self.nicknames or {})
    -- 当天第一次保存前，把磁盘上那份（= 昨天结束时的状态）留成 bak1，
    -- 必须在 flush 之前做，否则备到的是刚写进去的新数据
    self:_bakRotate()
    self.settings:saveSetting("bak_date", self.bak_date or "")
    -- 时钟防呆：先更新高水位再落盘（必须在 flush 之前，跟着存档一起写）
    self.max_ts = math.max(self.max_ts or 0, os.time())
    self.settings:saveSetting("max_seen_ts", self.max_ts)
    self.settings:flush()
    self.last_save_ts = os.time()
end

--------------------------------------------------------------------
-- 事件
--------------------------------------------------------------------

function Pokemon:onReaderReady()
    self.last_tick = time.now()
    -- 时钟防呆：检出回退就提示一次（常见原因：设备彻底亏电后 RTC 重置）
    if self.clock_bad then
        UIManager:scheduleIn(2.5, function()
            if self.suspended then return end
            UIManager:show(InfoMessage:new{
                text = "设备时钟异常：当前时间早于上次记录（可能因电量耗尽重置）。\n已临时冻结每日结算，奖励不会重复发放，阅读进度照常累积。\n联网校时或在系统设置里校准时间后重启 KOReader 即可恢复。",
                timeout = 8,
            })
        end)
    end
end

function Pokemon:onCloseDocument()
    Pokemon._seq = Pokemon._seq + 1  -- 让当前定时链失效
    self:save()
end

function Pokemon:onSuspend()
    self.suspended = true
    self:save()
end

function Pokemon:onResume()
    self.suspended = false
    self.last_tick = time.now()
    if self.pending_award then
        local p = self.pending_award
        self.pending_award = nil
        self:showAward(p.mon, p.is_dup, p.is_shiny, p.banner)
    end
    if self.pending_milestones then
        local ms = self.pending_milestones
        self.pending_milestones = nil
        self:_queueMilestonePopups(ms)
    end
end

function Pokemon:onFlushSettings()
    self:save()
end

function Pokemon:onDispatcherRegisterActions()
    Dispatcher:registerAction("pokemon_show_pokedex", {
        category = "none",
        event = "ShowPokemonPokedex",
        title = "宝可梦图鉴",
        general = true,
    })
end

function Pokemon:onShowPokemonPokedex()
    self:openPokedex()
    return true
end

--------------------------------------------------------------------
-- 界面入口
--------------------------------------------------------------------

function Pokemon:openPokedex()
    self.pokedex_view = PokedexView:new{ plugin = self }
    UIManager:show(self.pokedex_view)
end

function Pokemon:openShinyDex()
    self.shiny_view = ShinyDexView:new{ plugin = self }
    UIManager:show(self.shiny_view)
end

function Pokemon:countShiny()
    local n = 0
    for _id, info in pairs(self.caught) do
        if info.shiny then n = n + 1 end
    end
    return n
end

-- 闪光图鉴详情：个体闪光状态 + 闪光途径说明
function Pokemon:showShinyDetail(mon)
    local info = self.caught[mon.id]
    local state
    if info and info.shiny then
        state = string.format("◆ 已经遇到它的闪光个体！\n首次相遇：%s%s",
            fmtDateCN(info.date) or info.date or "—",
            (info.book and info.book ~= "")
                and ("\n当时在读《" .. shortBook(info.book, 14) .. "》") or "")
    elseif info then
        state = "普通个体已收集，还没遇到它的闪光版本～\n继续捕获就有机会！"
    else
        state = "还没捕获过它，先在读书达标时把它收进图鉴吧！"
    end
    UIManager:show(InfoMessage:new{
        text = string.format(
            "No.%04d　%s\n\n%s\n\n―――― 闪光途径 ――――\n每天读书达标就能捕获 1 只，\n有 1/4 的机会再遇老朋友，\n每次捕获（含再遇）都有 1/%d 的概率\n遇到闪闪发光的珍贵闪光个体。\n读得越多、捕得越多，闪光越多！",
            mon.id, mon.name, state, SHINY_RATE),
        timeout = 20,
    })
end

function Pokemon:showMedals()
    UIManager:show(MedalsDialog:new{ plugin = self })
end

function Pokemon:countMedals()
    local n = 0
    for _i, m in ipairs(MILESTONES) do
        if self.milestones["m_" .. m] then n = n + 1 end
    end
    for _i, m in ipairs(STREAK_MILESTONES) do
        if self.milestones["s_" .. m] then n = n + 1 end
    end
    for _i, m in ipairs(COMBO_MILESTONES) do
        if self.milestones["c_" .. m] then n = n + 1 end
    end
    for gen = 1, 9 do
        if self.milestones["g_" .. gen] then n = n + 1 end
    end
    return n
end

function Pokemon:showStats()
    local today = self:_today()
    local secs = self.daily[today] or 0
    local caught_n = self:countCaught()
    local L = self:currentLevel()
    local xp = self:totalXP()
    local xp_next = L < MAX_LEVEL and (xpForLevel(L + 1) - xp) or nil
    local lines = {
        string.format("★ 训练家：Lv.%d %s", L, levelTitle(L)),
        xp_next and string.format("　（距下一级还差 %d XP）", xp_next)
            or string.format("　（已达最高等级，太厉害了！）"),
        string.format("★ 今日阅读：%s", fmtDuration(secs)),
        string.format("★ 每日目标：%d 分钟%s", math.floor(self.goal / 60),
            self.award_date == today and "（伙伴已到手）" or ""),
        string.format("★ 连续达标：%d 天", self.streak_count or 0),
        string.format("★ 孵化中的蛋：%d / %d 天%s", self.egg_progress or 0, EGG_DAYS,
            (self.egg_hatched or 0) > 0
                and string.format("（已孵出 %d 只）", self.egg_hatched) or ""),
        string.format("★ 当前连击：%d 次连续捕新", self.combo or 0),
        string.format("★ 累计阅读：%s", fmtDuration(self.total_secs)),
        string.format("★ 图鉴进度：%d / %d（%.1f%%）", caught_n, TOTAL, caught_n / TOTAL * 100),
    }
    local tt = self:titleText()
    if tt then
        table.insert(lines, 2, string.format("★ 称号：%s", tt))
    end
    UIManager:show(PokemonInfoView:new{
        title = "训练家状态",
        text = table.concat(lines, "\n"),
    })
end

function Pokemon:showWeekly()
    UIManager:show(WeeklyDialog:new{ plugin = self })
end

function Pokemon:showGoalDialog()
    UIManager:show(GoalDialog:new{ plugin = self })
end

function Pokemon:showRecent()
    local list = {}
    for id, info in pairs(self.caught) do
        if DEX_BY_ID[id] then
            list[#list + 1] = { mon = DEX_BY_ID[id], info = info }
        end
    end
    table.sort(list, function(a, b)
        return (a.info.ts or 0) > (b.info.ts or 0)
    end)
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = "还没有遇见过小伙伴，今天读满目标时长试试～", timeout = 4 })
        return
    end
    local lines = {}
    for i = 1, math.min(8, #list) do
        local item = list[i]
        local when = item.info.date or "—"
        if item.info.book and item.info.book ~= "" then
            when = when .. " 读《" .. (shortBook(item.info.book, 8) or "?") .. "》"
        end
        lines[#lines + 1] = string.format("★ %d. No.%04d %s%s（%s）", i, item.mon.id,
            item.mon.name, item.info.shiny and " ◆闪光" or "", when)
    end
    UIManager:show(PokemonInfoView:new{
        title = "相遇记录",
        text = table.concat(lines, "\n"),
    })
end

function Pokemon:addToMainMenu(menu_items)
    -- 顶部菜单栏专属标签（精灵球图标）。
    -- 首选：插件在 init 里自己写好 <settings>/reader_menu_order.lua（_menu_tab 为真），
    --       装到任何一台机器上都直接有标签，不用手工改系统文件。
    -- 兜底：老版本手工改过系统 reader_menu_order.lua 的设备，内容里能搜到 "pokemon"。
    -- 都没有就优雅降级：只注册「工具 → 更多工具 → 宝可梦图鉴」，功能一点不少。
    local tab_patched = (self._menu_tab == true)
    if not tab_patched then
        pcall(function()
            -- 不同机型的工作目录不同（Kindle 是 koreader 根，Kobo 是 .adds/koreader），
            -- 所以相对路径和绝对路径都试一遍，避免误判导致标签不显示
            local paths = {
                DataStorage:getSettingsDir() .. "/reader_menu_order.lua",
                "frontend/ui/elements/reader_menu_order.lua",
                DataStorage:getDataDir() .. "/frontend/ui/elements/reader_menu_order.lua",
            }
            for _i, path in ipairs(paths) do
                local f = io.open(path, "r")
                if f then
                    local c = f:read("*a")
                    f:close()
                    if c and c:find('"pokemon"', 1, true) then
                        tab_patched = true
                        break
                    end
                end
            end
        end)
    end
    logger.info("Pokemon: addToMainMenu, 顶部标签补丁在位=", tostring(tab_patched))
    if tab_patched then
        -- tab 容器：图标 + 标题；内容由 reader_menu_order 的 pokemon 小节提供
        -- （menusorter 要求：顶层 tab 必须同时有 order 标签和 order 小节，缺小节会被静默丢弃）
        menu_items.pokemon = {
            icon = "appbar.pokemon",
            text = "宝可梦图鉴",
        }
        menu_items.pokemon_home    = { text = "打开主面板", callback = function()
            showHomePanel(self)
        end }
        menu_items.pokemon_dex     = { text_func = function()
            return string.format("我的图鉴（%d / %d）", self:countCaught(), TOTAL)
        end, callback = function() self:openPokedex() end }
        menu_items.pokemon_shiny   = { text_func = function()
            return string.format("闪光图鉴 ◆（%d / %d）", self:countShiny(), TOTAL)
        end, callback = function() self:openShinyDex() end }
        menu_items.pokemon_partner = { text = "更换伙伴", callback = function() self:openPartnerPicker() end }
        menu_items.pokemon_candy   = { text_func = function()
            return string.format("糖果罐（● %d）", self.candies or 0)
        end, callback = function() self:openCandyJar() end }
        menu_items.pokemon_quest   = { text = "每日委托", callback = function() self:openQuests() end }
        menu_items.pokemon_gym     = { text_func = function()
            return string.format("阅读徽章（%d / %d）", self:badgeCount(), #BADGES)
        end, callback = function() self:openBadges() end }
        menu_items.pokemon_medals  = { text = "我的奖章", callback = function() self:showMedals() end }
        menu_items.pokemon_stats   = { text = "训练家状态", callback = function() self:showStats() end }
        menu_items.pokemon_recent  = { text = "相遇记录", callback = function() self:showRecent() end }
        menu_items.pokemon_weekly  = { text = "阅读周报", callback = function() self:showWeekly() end }
        menu_items.pokemon_goal    = { text = "每日目标", callback = function() self:showGoalDialog() end }
        menu_items.pokemon_save    = { text = "存档管理", callback = function() self:openSaveManager() end }
        menu_items.pokemon_help    = { text = "玩法说明", callback = function()
            UIManager:show(PokemonInfoView:new{
                title = "玩法说明",
                text = string.format(
                    "每天累计阅读满 %d 分钟，就会有一只宝可梦跳出来和你回家～\n\n"
                    .. "每次捕获有 1/%d 的概率遇到闪闪发光的珍贵闪光个体（◆）；连着 %d 次没遇到，下一次必定闪光。\n\n"
                    .. "同一只相遇 3 次会进化；每天读满目标还会孵蛋。\n\n"
                    .. "读完一本书会送保底稀有、糖果和熏香。糖果可以换道具。\n\n"
                    .. "伙伴陪你越久好感越高，好感会送糖果、提升闪光率。好感 ♥4 起，每天第一次捕获必定遇到没见过的面孔。\n\n"
                    .. "阅读徽章只看累计阅读时长（关都 5 小时一路到帕底亚 400 小时，共十枚），每点亮一枚都有奖励。\n\n"
                    .. RIGHTS_NOTICE,
                    math.floor((self.goal or 1800) / 60), SHINY_RATE, SHINY_PITY),
            })
        end }
        -- 这里刻意不加 keep_menu_open。
        -- 试过让阅读菜单常驻（关掉面板回菜单），但菜单容器留在窗口栈上会和
        -- 全屏面板抢层级，实机上表现为"点了糖果罐没反应"。
        -- 「常驻」应该由主面板负责：从主面板进子面板，关掉自然回主面板。
    end
    menu_items.pokemon_pokedex = {
        text_func = function()
            return string.format("宝可梦图鉴（%d / %d）", self:countCaught(), TOTAL)
        end,
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:_buildMenuItems()
        end,
    }
end

function Pokemon:_buildMenuItems()
    local goal_min = math.floor(self.goal / 60)

    -- 这些项用 text_func：每次打开菜单都重新算，抓了新宝可梦、买了糖果都不会显示旧数字
    local function todayLabel()
        local t = self:_today()
        local s = self.daily[t] or 0
        if self.award_date == t then
            return string.format("今日已达标（%s）· 明天再来玩", fmtDuration(s))
        end
        return string.format("今日阅读 %s / %d 分钟", fmtDuration(s),
            math.floor(self.goal / 60))
    end

    local goal_items = {
        {
            text = "自定义（5～120 分钟）",
            callback = function() self:showGoalDialog() end,
            separator = true,
        },
    }
    for _i, minutes in ipairs({ 15, 20, 30, 45, 60 }) do
        goal_items[#goal_items + 1] = {
            text = string.format("%d 分钟", minutes),
            radio = true,
            checked_func = function() return self.goal == minutes * 60 end,
            callback = function()
                self.goal = minutes * 60
                self:save()
            end,
        }
    end

    local menu = {
        {
            text = "✨ 打开主面板（推荐）",
            callback = function()
                showHomePanel(self)
            end,
            separator = true,
        },
        {
            text = "―― 新玩法 ――",
            enabled = false,
        },
        {
            text_func = function()
                local done, total = self:questProgressCount()
                return string.format("每日委托（%d / %d 已完成）", done, total)
            end,
            callback = function() self:openQuests() end,
        },
        {
            text_func = function()
                return string.format("糖果罐（● %d）", self.candies or 0)
            end,
            callback = function() self:openCandyJar() end,
        },
        {
            text_func = function()
                return string.format("阅读徽章（%d / %d）", self:badgeCount(), #BADGES)
            end,
            callback = function() self:openBadges() end,
        },
        {
            text_func = function()
                local mon = self:partnerMon()
                local h = self:hearts()
                if not mon then return "更换伙伴（还没捕获宝可梦）" end
                return string.format("伙伴：%s　好感 %s", self:partnerName(mon),
                    string.rep("♥", h) .. string.rep("♡", 5 - h))
            end,
            callback = function() self:openPartnerPicker() end,
        },
        {
            text = "―― 图鉴与收集 ――",
            enabled = false,
        },
        {
            text = "打开图鉴",
            callback = function() self:openPokedex() end,
        },
        {
            text_func = function()
                return string.format("闪光图鉴 ◆（%d / %d）", self:countShiny(), TOTAL)
            end,
            callback = function() self:openShinyDex() end,
        },
        {
            text_func = function()
                return string.format("孵化中的蛋（%d / %d 天）",
                    self.egg_progress or 0, EGG_DAYS)
            end,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        "蛋的孵化进度：%d / %d 天%s\n\n每天读满目标时间，蛋就会前进一天；\n攒满 %d 天就会孵化，送你一只\n必定是新面孔的小伙伴！\n%s",
                        self.egg_progress or 0, EGG_DAYS,
                        (self.egg_hatched or 0) > 0
                            and string.format("（已孵出 %d 只）", self.egg_hatched) or "",
                        EGG_DAYS,
                        (self.egg_hatched or 0) > 0
                            and "下一颗也拜托你啦～" or "第一颗蛋马上就开始孵咯～"),
                    timeout = 10,
                })
            end,
        },
        {
            text_func = function()
                local lv = self:currentLevel()
                return string.format("训练家 Lv.%d · %s", lv, levelTitle(lv))
            end,
            callback = function() self:showStats() end,
        },
        {
            text_func = function() return todayLabel() end,
            callback = function() self:showWeekly() end,
        },
        {
            text_func = function()
                return string.format("连续达标 %d 天 · 累计 %s",
                    self.streak_count or 0, fmtDuration(self.total_secs))
            end,
            callback = function() self:showWeekly() end,
        },
        {
            text = "―― 收集与成长 ――",
            enabled = false,
        },
        {
            text = "最近捕获",
            callback = function() self:showRecent() end,
        },
        {
            text_func = function()
                return string.format("我的奖章 %d / %d",
                    self:countMedals(), #MILESTONES + #STREAK_MILESTONES + 9)
            end,
            callback = function() self:showMedals() end,
        },
        {
            text_func = function()
                return string.format("每日目标（现在 %d 分钟）",
                    math.floor(self.goal / 60))
            end,
            sub_item_table = goal_items,
        },
        {
            text = "―― 帮助 ――",
            enabled = false,
        },
        {
            text = "玩法说明",
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        "每天累计阅读满 %d 分钟（可在「每日目标」里自由调整），"
                        .. "就会有一只宝可梦跳出来和你回家～\n\n"
                        .. "越稀有越难遇见：常见 > 少见 > 稀有 > 传说。"
                        .. "每次还有 1/%d 的概率遇到闪闪发光的珍贵闪光个体（◆），集齐它们是终极梦想！\n\n"
                        .. "训练家等级：阅读 1 分钟 = 1 XP，捕获按稀有度 10～100 XP；"
                        .. "进化 +200、孵蛋 +150、连击达成 +100。称号从新人训练家一路升到地区冠军，最高 Lv.%d。\n\n"
                        .. "同一只相遇 3 次会进化（伊布等分支由你亲自选）；每天读满目标孵蛋攒 3 天送额外捕获；"
                        .. "连续捕新可冲 5/10/20/40 连击奖章。\n\n"
                        .. "阶段性奖励：收集满 %d 只、连续阅读 %d 天、或集齐某个世代的地区图鉴，"
                        .. "都会获得一枚奖章（共 %d 枚），在「我的奖章」里查看。\n\n"
                        .. "小提示：可在「手势管理」中把「宝可梦图鉴」绑定到手势，随时翻看。\n\n"
                        .. RIGHTS_NOTICE,
                        goal_min, SHINY_RATE, MAX_LEVEL, MILESTONES[1], STREAK_MILESTONES[1],
                        #MILESTONES + #STREAK_MILESTONES + #COMBO_MILESTONES + 9),
                    timeout = 14,
                })
            end,
        },
    }

    if DEBUG_MODE then
        for _i, item in ipairs(self:_debugActions()) do
            menu[#menu + 1] = item
        end
    end

    -- 同上：不要给这些项加 keep_menu_open —— 子菜单留在栈上会和全屏面板抢层级，
    -- 点下去会"没反应"。点完关菜单、开面板是 KOReader 的默认流程，最稳。

    return menu
end

-- 调试动作表：菜单（图鉴子菜单底部）与「调试工具」面板共用同一份
function Pokemon:_debugActions()
    return {
            {
                text = "调试：立即捕获一只",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = "调试用：马上随机捕获一只宝可梦（不消耗阅读进度）。\n正常玩法请靠每日阅读获得。",
                        ok_text = "捕获",
                        cancel_text = "取消",
                        ok_callback = function()
                            self:_award(self:_today(), true)
                        end,
                    })
                end,
            },
            {
                text = "调试：模拟读完一本书",
                callback = function()
                    local pool_n = 0
                    for _i, mon in ipairs(DEX) do
                        if (mon.rarity == "rare" or mon.rarity == "legendary")
                            and not self.caught[mon.id] then
                            pool_n = pool_n + 1
                        end
                    end
                    UIManager:show(ConfirmBox:new{
                        text = string.format(
                            "会按真实流程结算：\n+%d XP　+%d 糖果　+1 熏香\n然后从「稀有 + 传说」池抽一张捕获卡。\n\n当前池内可抽：%d 只\n（不记入累计读完本数，不占当天捕获名额）",
                            BOOK_XP, CANDY_BOOK, pool_n),
                        ok_text = "模拟",
                        cancel_text = "取消",
                        ok_callback = function()
                            self:_grantBookReward("（调试）一本读完的书", true)
                        end,
                    })
                end,
            },
            {
                text = "调试：素材完整性检查",
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self:_checkAssets(),
                        timeout = 30,
                    })
                end,
            },
            {
                text = "调试：屏幕信息（居中排查）",
                callback = function()
                    local dpi = "?"
                    pcall(function() dpi = tostring(Screen:getDPI()) end)
                    local scale = "?"
                    pcall(function() scale = tostring(Screen:scaleBySize(100)) end)
                    local rot = "?"
                    pcall(function()
                        rot = tostring(Screen.cur_rotation_mode or "?")
                    end)
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            "KOReader 认为的屏幕参数：\n\n宽度：%d\n高度：%d\nDPI：%s\nscaleBySize(100)：%s\n旋转模式：%s\n\n如果数字和实际屏幕对不上，\n说明 KOReader 被启动器窗口化运行。",
                            Screen:getWidth(), Screen:getHeight(), dpi, scale, rot),
                        timeout = 30,
                    })
                end,
            },
            {
                text = "调试：检查当前书本识别",
                callback = function()
                    local book = "（当前没有打开的书）"
                    pcall(function()
                        if self.ui and self.ui.document and self.ui.document.file then
                            local props = self.ui.doc_props
                            if props and props.title and props.title ~= "" then
                                book = props.title
                            else
                                local f = self.ui.document.file or ""
                                book = f:match("([^/\\]+)$") or f
                            end
                        end
                    end)
                    UIManager:show(InfoMessage:new{
                        text = "捕获详情将记录的书名：\n\n" .. book,
                        timeout = 12,
                    })
                end,
            },
            {
                text = "调试：预览蛋孵化捕获卡",
                callback = function()
                    local mon = DEX[math.random(1, #DEX)]
                    UIManager:show(MonDialog:new{
                        plugin = self,
                        mon = mon,
                        info = self.caught[mon.id] or { date = self:_today() },
                        banner = "蛋孵化啦！是它钻了出来！",
                    })
                end,
            },
            {
                text = "调试：进化试验场（单链自动进化）",
                callback = function()
                    -- 随机抽一条单分支进化链，用临时数据演示自动进化
                    local pool = {}
                    for id, kids in pairs(EVO_NEXT) do
                        if #kids == 1 then
                            pool[#pool + 1] = { id = id, evo = kids[1] }
                        end
                    end
                    if #pool == 0 then return end
                    math.randomseed(os.time())
                    local pick = pool[math.random(1, #pool)]
                    local mon = DEX_BY_ID[pick.id]
                    UIManager:show(MonDialog:new{
                        plugin = self,
                        mon = mon,
                        info = { date = self:_today(), count = 3,
                            evo = pick.evo },
                        banner = string.format("进化了！%s 进化成了 %s！",
                            mon.name, (DEX_BY_ID[pick.evo] or mon).name),
                    })
                end,
            },
            {
                text = "调试：进化试验场（分支自选）",
                callback = function()
                    -- 随机抽一条多分支链（伊布/蚊香蝌蚪这类），演示点选进化
                    local pool = {}
                    for id, kids in pairs(EVO_NEXT) do
                        if #kids > 1 then
                            pool[#pool + 1] = { id = id, kids = kids }
                        end
                    end
                    if #pool == 0 then return end
                    math.randomseed(os.time() + 7)
                    local pick = pool[math.random(1, #pool)]
                    local mon = DEX_BY_ID[pick.id]
                    UIManager:show(MonDialog:new{
                        plugin = self,
                        mon = mon,
                        info = { date = self:_today(), count = 3,
                            pending_evo = pick.kids },
                    })
                end,
            },
            {
                text = "调试：预览主面板",
                callback = function()
                    showHomePanel(self)
                end,
            },
            {
                text = "调试：预览糖果罐",
                callback = function() self:openCandyJar() end,
            },
            {
                text = "调试：预览每日委托",
                callback = function() self:openQuests() end,
            },
            {
                text = "调试：预览阅读徽章",
                callback = function() self:openBadges() end,
            },
            {
                text = "调试：预览伙伴选择器",
                callback = function() self:openPartnerPicker() end,
            },
            {
                text = "调试：临时好感 ♥4",
                callback = function() self:debugSetAffection(4) end,
            },
            {
                text = "调试：临时好感 ♥5",
                callback = function() self:debugSetAffection(5) end,
            },
            {
                text = "调试：取消临时好感",
                callback = function() self:debugSetAffection(nil) end,
            },
            {
                text = "调试：加 100 糖果",
                callback = function()
                    self:addCandy(100)
                    self:save()
                    UIManager:show(InfoMessage:new{ text = "糖果 +100", timeout = 2 })
                end,
            },
            {
                -- 测糖果出口用：额外捕获一次 300 起，100 颗点不出手感
                text = "调试：加 5000 糖果",
                callback = function()
                    self:addCandy(5000)
                    self:save()
                    UIManager:show(InfoMessage:new{
                        text = string.format("糖果 +5000（现在 ● %d）", self.candies or 0),
                        timeout = 2 })
                end,
            },
            {
                text = "调试：闪光保底推到临界",
                callback = function()
                    -- 设成 SHINY_PITY-1：下一次捕获必然触发保底，用来验证这条逻辑
                    self.shiny_pity = SHINY_PITY - 1
                    self.shiny_pity_ts = os.time()
                    self:save()
                    UIManager:show(InfoMessage:new{
                        text = string.format("闪光保底 %d / %d，下一次捕获必出闪光",
                            self.shiny_pity, SHINY_PITY),
                        timeout = 3 })
                end,
            },
            {
                text = "调试：重置今日购买（额外捕获/孵化冷却）",
                callback = function()
                    self.catch_buy = { date = self:_today(), n = 0 }
                    self.hatch_ts = 0
                    -- 必须刷新"商店最后修改时间"，否则 save() 合并时
                    -- 会因为磁盘上的旧时间戳更"新"而把上面的清零还原
                    self.shop_meta_ts = os.time()
                    self:save()
                    UIManager:show(InfoMessage:new{ text = "今日限购与冷却已清零", timeout = 2 })
                end,
            },
            {
                text = "调试：预览闪光捕获卡",
                callback = function()
                    local mon = DEX[math.random(1, #DEX)]
                    UIManager:show(MonDialog:new{
                        plugin = self,
                        mon = mon,
                        -- 预览卡也带上当前书名，和真实捕获卡展示一致
                        info = self.caught[mon.id]
                            or { date = self:_today(), book = self:_currentBookTitle() },
                        banner = "闪光！遇到了闪闪发光的它！",
                        is_shiny = true,
                    })
                end,
            },
            {
                text = "调试：预览一枚成就奖章",
                callback = function()
                    UIManager:show(AchievementDialog:new{
                        plugin = self,
                        item = { type = "count", n = MILESTONES[1] },
                    })
                end,
            },
            {
                text = "调试：预览奖章陈列墙",
                callback = function()
                    UIManager:show(MedalsDialog:new{ plugin = self, preview_all = true })
                end,
            },
            {
                text = "调试：预览训练家升级卡",
                callback = function()
                    UIManager:show(AchievementDialog:new{
                        plugin = self,
                        item = { type = "level", level = self:currentLevel() + 1 },
                    })
                end,
            },
    }
end

-- 调试工具面板：主面板点两下就能到，不用翻子菜单
function Pokemon:openDebugPanel()
    local actions = self:_debugActions()
    local panel
    panel = PokemonPanelView:new{
        title = "调试工具",
        subtitle = string.format("调试版专用 · 共 %d 项 · 正式版不会出现", #actions),
        build = function(_, inner_w)
            local rows = VerticalGroup:new{ align = "center" }
            local cols, gap = 2, Screen:scaleBySize(8)
            local cell_w = math.floor((inner_w - (cols - 1) * gap) / cols)
            local cell_h = Screen:scaleBySize(40)
            local function short(t)
                return (t:gsub("^调试：", ""))
            end
            for start = 1, #actions, cols do
                local row = HorizontalGroup:new{ align = "center" }
                for c = 0, cols - 1 do
                    if c > 0 then
                        table.insert(row, HorizontalSpan:new{ width = gap })
                    end
                    local a = actions[start + c]
                    if a then
                        table.insert(row, Button:new{
                            text = short(a.text),
                            width = cell_w, height = cell_h,
                            text_font_size = 15,
                            avoid_text_truncation = false,
                            callback = function()
                                -- 先关面板再动作：否则新面板会叠在调试列表上
                                if panel and not panel._closed then panel:onClose() end
                                UIManager:scheduleIn(0.2, function()
                                    local ok, err = pcall(a.callback)
                                    if not ok then
                                        logger.warn("pokemon: debug action failed:", err)
                                        UIManager:show(InfoMessage:new{
                                            text = "这个调试项出错了，见 crash.log", timeout = 3 })
                                    end
                                end)
                            end,
                        })
                    else
                        table.insert(row, HorizontalSpan:new{ width = cell_w })
                    end
                end
                table.insert(rows, row)
                table.insert(rows, VerticalSpan:new{ width = gap })
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            local tw = makeText("面板会自动关闭后再执行，避免叠层",
                "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5)
            table.insert(rows, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = tw:getSize().h }, tw,
            })
            return rows
        end,
    }
    UIManager:show(panel)
end


-- ====================================================================
-- v3 视图：通用信息面板（糖果罐 / 委托 / 阅读徽章共用外壳）
-- ====================================================================
PokemonPanelView = InputContainer:extend{
    title = nil,
    subtitle = nil,
    build = nil,        -- function(self, inner_w) -> VerticalGroup
    _closed = false,
}

function PokemonPanelView:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    local frame_w = math.min(math.floor(sw * 0.90), Screen:scaleBySize(620))
    local inner_w = frame_w - 2 * pad

    local rows = VerticalGroup:new{ align = "center" }
    if self.title then
        local tt = makeCuteText(self.title, 22, true, RGB.poke_red)
        table.insert(rows, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = tt:getSize().h }, tt,
        })
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    end
    if self.subtitle then
        local face = Font:getFace("xx_smallinfofont")
        for _, ln in ipairs(splitCenteredLines(self.subtitle, inner_w, face, false)) do
            local tw = TextWidget:new{ text = ln, face = face,
                fgcolor = Blitbuffer.COLOR_GRAY_5 }
            table.insert(rows, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = tw:getSize().h }, tw,
            })
        end
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end
    if self.build then
        local body = self.build(self, inner_w)
        if body then table.insert(rows, body) end
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end
    table.insert(rows, makeButtonRows({ {
        { text = "关闭", callback = function() self:onClose() end },
    } }, inner_w))

    -- 旧版实机验证过的结构：固定宽度卡片直接包 rows。
    -- 不要用 rows:getSize() 测量后再包 CenterContainer——
    -- 新机型（FocusManager 版 ButtonTable）上会把底部按钮挤丢
    -- 本机 FrameContainer:getSize() 不计入 width，边框按 width 画、
    -- 上报却按内容宽——子内容比 width 窄时边框会被父级推到右边（糖果罐畸变的根源）。
    -- 因此：边框宽度必须跟随 rows 的实测宽度，二者永远保持一致。
    local bs = Screen:scaleBySize(2)
    local rows_size = rows:getSize()
    local frame_w_real = math.max(frame_w, rows_size.w + 2 * (pad + bs))
    local frame = FrameContainer:new{
        width = frame_w_real,
        padding = pad, margin = 0,
        bordersize = bs,
        radius = Screen:scaleBySize(14),
        color = RGB.poke_red,
        background = Blitbuffer.COLOR_WHITE,
        rows,
    }
    if DEBUG_MODE then
        logger.warn(string.format(
            "pokemon: panel[%s] rows=%dx%d frame_w=%d frame_real=%d screen=%dx%d",
            tostring(self.title), rows_size.w, rows_size.h, frame_w, frame_w_real, sw, sh))
    end
    -- 记录卡片实际位置：点卡片外任意处关闭，绝不让用户被困在界面里
    local fsize = frame:getSize()
    self.frame_dimen = Geom:new{
        x = math.floor((sw - fsize.w) / 2),
        y = math.floor((sh - fsize.h) / 2),
        w = fsize.w, h = fsize.h,
    }
    self[1] = FrameContainer:new{
        width = sw, height = sh,
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = self.dimen, frame },
    }
    UIManager:scheduleIn(0.35, fullRefreshScreen)
end

function PokemonPanelView:onTapClose(arg, ges)
    if ges and ges.pos and self.frame_dimen
            and ges.pos:notIntersectWith(self.frame_dimen) then
        return self:onClose()
    end
    return true
end

function PokemonPanelView:onClose()
    if self._closed then return true end
    self._closed = true
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

--------------------------------------------------------------------
-- 伙伴选择器：只列已捕获，4×4 分页
--------------------------------------------------------------------
PartnerPickerView = InputContainer:extend{
    plugin = nil,
    page = 1,
    cols = 4,
    rows = 4,
    _closed = false,
}

function PartnerPickerView:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    self.list = {}
    for _, mon in ipairs(DEX) do
        if self.plugin.caught[mon.id] then
            self.list[#self.list + 1] = mon
        end
    end
    self:rebuild()
end

function PartnerPickerView:rebuild()
    local p = self.plugin
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    local frame_w = math.min(math.floor(sw * 0.92), Screen:scaleBySize(620))
    local gap = Screen:scaleBySize(10)
    local per_page = self.cols * self.rows
    local pages = math.max(1, math.ceil(#self.list / per_page))
    if self.page > pages then self.page = pages end
    local cell_w = math.floor((frame_w - 2 * pad - (self.cols - 1) * gap) / self.cols)
    local cell_h = math.floor(cell_w * 1.1)
    local img_s = math.min(cell_w - Screen:scaleBySize(16), cell_h - Screen:scaleBySize(34))
    img_s = math.max(img_s, Screen:scaleBySize(30))

    local grid = VerticalGroup:new{ align = "center" }
    local start = (self.page - 1) * per_page + 1
    for r = 0, self.rows - 1 do
        local row = HorizontalGroup:new{ align = "center" }
        for c = 0, self.cols - 1 do
            local mon = self.list[start + r * self.cols + c]
            if c > 0 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            if mon then
                local info = p.caught[mon.id]
                local dimen = Geom:new{ w = cell_w, h = cell_h }
                local cell = InputContainer:new{ dimen = dimen }
                if Device:isTouchDevice() then
                    cell.ges_events.Tap = { GestureRange:new{ ges = "tap", range = dimen } }
                end
                local is_current = (p:partnerId() == mon.id)
                cell.onTap = function()
                    p.partner_id = mon.id
                    p.partner_streak = 1
                    p.partner_day = p:_today()
                    p:save()
                    -- 关掉选择器：主面板若垫在下面会被重建（新伙伴已生效）
                    self:onClose()
                    -- 有主面板就只刷新，没有再新建。原来无条件 new 会叠出第二层，
                    -- 表现为"选完伙伴要连关两次才回到书页"。
                    showHomePanel(p)
                    return true
                end
                cell[1] = FrameContainer:new{
                    width = cell_w, height = cell_h,
                    padding = Screen:scaleBySize(4), margin = 0,
                    bordersize = Screen:scaleBySize(is_current and 2 or 1),
                    radius = Screen:scaleBySize(10),
                    color = is_current and RGB.poke_red or Blitbuffer.COLOR_GRAY_6,
                    background = Blitbuffer.COLOR_WHITE,
                    VerticalGroup:new{ align = "center",
                        ImageWidget:new{
                            file = spritePath(p, mon, "small", info and info.shiny),
                            width = img_s, height = img_s, scale_factor = 0, alpha = true,
                        },
                        makeCuteText(p:partnerName(mon), 16, false),
                    },
                }
                table.insert(row, cell)
            else
                table.insert(row, HorizontalSpan:new{ width = cell_w })
            end
        end
        table.insert(grid, row)
        if r < self.rows - 1 then
            table.insert(grid, VerticalSpan:new{ width = gap })
        end
    end

    local footer = HorizontalGroup:new{ align = "center",
        Button:new{ icon = "chevron.left", bordersize = 0,
            callback = function()
                if self.page > 1 then self.page = self.page - 1; self:rebuild() end
            end, show_parent = self },
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        makeText(string.format("%d / %d", self.page, pages), "xx_smallinfofont", true),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        Button:new{ icon = "chevron.right", bordersize = 0,
            callback = function()
                if self.page < pages then self.page = self.page + 1; self:rebuild() end
            end, show_parent = self },
    }

    local title = string.format("选择伙伴　%d 只可选", #self.list)
    local rows = VerticalGroup:new{ align = "center",
        makeCuteText(title, 22, true, RGB.poke_red),
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        makeText("点一只作为伙伴，之后它会陪着你读书", "xx_smallinfofont", false,
            Blitbuffer.COLOR_GRAY_5),
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        grid,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        footer,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        makeButtonRows({ {
            { text = "关闭", callback = function() self:onClose() end },
        } }, frame_w - 2 * pad),
    }
    -- 固定宽度卡片（旧版实机验证过的结构，见 PokemonPanelView 注释）
    local frame = FrameContainer:new{
        width = frame_w,
        padding = pad, margin = 0,
        bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(14),
        color = RGB.poke_red, background = Blitbuffer.COLOR_WHITE,
        rows,
    }
    local fsize = frame:getSize()
    self.frame_dimen = Geom:new{
        x = math.floor((sw - fsize.w) / 2),
        y = math.floor((sh - fsize.h) / 2),
        w = fsize.w, h = fsize.h,
    }
    self[1] = FrameContainer:new{
        width = sw, height = sh, padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = self.dimen, frame },
    }
    UIManager:setDirty(self, "ui")
end

function PartnerPickerView:onTapClose(arg, ges)
    if ges and ges.pos and self.frame_dimen
            and ges.pos:notIntersectWith(self.frame_dimen) then
        return self:onClose()
    end
    return true
end

function PartnerPickerView:onClose()
    self._closed = true
    if refreshHomePanel then refreshHomePanel() end
    UIManager:close(self)
    fullRefreshScreen()
    return true
end

-- ====================================================================
-- v3：伙伴 / 好感 / 糖果 / 委托 / 阅读徽章 / 读完一本书
-- ====================================================================

function Pokemon:_currentBookPath()
    local ok, p = pcall(function()
        if self.ui and self.ui.document then return self.ui.document.file end
    end)
    if ok and p then return p end
    return nil
end

function Pokemon:addCandy(n)
    self.candies = math.max(0, (self.candies or 0) + (n or 0))
    -- 打上时间戳，save() 才敢用"本地值"覆盖磁盘，而不是拿旧值回填
    self.candies_ts = os.time()
end

function Pokemon:partnerId()
    if self.partner_id and self.caught[self.partner_id] then return self.partner_id end
    local best_id, best_ts = nil, -1
    for cid, info in pairs(self.caught) do
        if DEX_BY_ID[cid] and (info.ts or 0) > best_ts then
            best_id, best_ts = cid, info.ts or 0
        end
    end
    return best_id
end

function Pokemon:partnerMon()
    local id = self:partnerId()
    return id and DEX_BY_ID[id] or nil
end

function Pokemon:partnerName(mon)
    local id = mon and mon.id or self:partnerId()
    local nick = id and self.nicknames and self.nicknames[id]
    if nick and nick ~= "" then return nick end
    return mon and mon.name or "?"
end

-- 陪伴秒数：调试期可被「临时好感」覆盖（只在内存里，不写存档）
function Pokemon:affectionSecs(id)
    id = id or self:partnerId()
    if not id then return 0 end
    local ov = self._aff_debug
    if ov and ov.id == id then return AFF_HEARTS[ov.level] or 0 end
    return self.affection[id] or 0
end

function Pokemon:hearts(id)
    id = id or self:partnerId()
    if not id then return 0 end
    local secs = self:affectionSecs(id)
    local h = 0
    for i = 1, #AFF_HEARTS do
        if secs >= AFF_HEARTS[i] then h = i end
    end
    return h
end

-- 调试用：把当前伙伴的好感临时拉到指定等级。
-- 只改内存里的 _aff_debug，不碰 self.affection，所以 save() 不会写进存档，
-- 重启 KOReader 后自然回到真实值。level 传 nil 表示取消覆盖。
function Pokemon:debugSetAffection(level)
    local id = self:partnerId()
    if level == nil then
        self._aff_debug = nil
        UIManager:show(InfoMessage:new{
            text = string.format("已取消临时好感，恢复真实值 ♥%d", self:hearts()),
            timeout = 3,
        })
        return
    end
    if not id then
        UIManager:show(InfoMessage:new{
            text = "还没有伙伴。\n先用下面几项里的「预览伙伴选择器」收下一只。",
            timeout = 3,
        })
        return
    end
    level = math.max(1, math.min(#AFF_HEARTS, math.floor(level)))
    self._aff_debug = { id = id, level = level }
    local mon = DEX_BY_ID[id]
    local next_secs = AFF_HEARTS[level + 1]
    UIManager:show(InfoMessage:new{
        text = string.format(
            "临时好感：%s ♥%d\n%s\n\n存档里的真实值不变，重启 KOReader 自动复原。",
            (mon and mon.name) or "伙伴", level,
            level >= #AFF_HEARTS and "已是最高等级（♥5）"
                or string.format("再陪伴 %s 就到 ♥%d", fmtDuration(next_secs - AFF_HEARTS[level]), level + 1)),
        timeout = 4,
    })
end

-- 称号：♥4 起才有的身份，显示在训练家状态和主面板好感行
function Pokemon:titleText()
    if self:hearts() >= 4 then return "伙伴训练家" end
    return nil
end

function Pokemon:shinyRate()
    local h = self:hearts()
    if h >= 5 then return math.floor(SHINY_RATE * 0.75) end
    if h >= 3 then return math.floor(SHINY_RATE * 0.875) end
    return SHINY_RATE
end

function Pokemon:_addAffection(delta)
    local id = self:partnerId()
    if not id then return end
    -- 连伴天数：跨天且伙伴没换 → 累加；换伙伴由选择器重置为 1
    local today = self:_today()
    if self.partner_day ~= today then
        local y = os.date("%Y-%m-%d", self:_now() - 86400)
        if self.partner_day == y then
            self.partner_streak = (self.partner_streak or 0) + 1
        elseif self.partner_day ~= "" then
            self.partner_streak = 1
        end
        self.partner_day = today
    end
    local mult = (self.partner_streak or 0) >= AFF_BOND_DAYS and 1.2 or 1.0
    local before = self:hearts(id)
    self.affection[id] = (self.affection[id] or 0) + delta * mult
    local after = self:hearts(id)
    if after > before then
        self:_grantHeartReward(after, id)
    end
end

function Pokemon:_grantHeartReward(level, id)
    local mon = DEX_BY_ID[id]
    local nm = (mon and mon.name) or "伙伴"
    local lines = { string.format("%s 对你的好感升到了 ♥%d！", nm, level) }
    if level == 1 then
        self:addCandy(10)
        lines[#lines + 1] = "+10 糖果"
    elseif level == 2 then
        lines[#lines + 1] = "之后每次捕获额外 +1 糖果"
    elseif level == 3 then
        lines[#lines + 1] = string.format("闪光概率提升到 1/%d", self:shinyRate())
    elseif level == 4 then
        lines[#lines + 1] = "解锁称号「伙伴训练家」"
        lines[#lines + 1] = "每天第一次捕获必定遇到没见过的面孔"
    elseif level == 5 then
        lines[#lines + 1] = string.format("闪光概率再提到 1/%d", self:shinyRate())
    end
    self:save()
    if self.suspended then return end
    pcall(function()
        UIManager:show(PokemonInfoView:new{
            title = "好感提升",
            text = table.concat(lines, "\n"),
        })
    end)
end

function Pokemon:openPartnerPicker()
    UIManager:show(PartnerPickerView:new{ plugin = self })
end

function Pokemon:renamePartner()
    local mon = self:partnerMon()
    if not mon then
        UIManager:show(InfoMessage:new{ text = "还没有可选伙伴，先捕获一只吧～", timeout = 3 })
        return
    end
    local ok, err = pcall(function()
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = "给伙伴起个名字",
            input = self:partnerName(mon),
            buttons = { {
                { text = "取消", callback = function()
                    UIManager:close(dlg)
                    -- 输入框是局部刷新，下面还压着已关闭的面板残影，必须整屏刷一次
                    UIManager:scheduleIn(0.4, fullRefreshScreen)
                end },
                { text = "就叫这个", is_primary = true, callback = function()
                    local txt = dlg:getInputText()
                    UIManager:close(dlg)
                    UIManager:scheduleIn(0.4, fullRefreshScreen)
                    if txt and txt ~= "" then
                        self.nicknames[mon.id] = txt
                        self:save()
                        UIManager:show(InfoMessage:new{ text = "名字改好啦～", timeout = 2 })
                    end
                end },
            } },
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end)
    if not ok then
        logger.warn("pokemon: rename failed:", err)
        UIManager:show(InfoMessage:new{ text = "改名卡暂时用不了，稍后再试～", timeout = 3 })
    end
end

--------------------------------------------------------------------
-- 糖果罐
--------------------------------------------------------------------

function Pokemon:itemCount(key)
    return self.items[key] or 0
end

function Pokemon:openCandyJar()
    local view
    view = PokemonPanelView:new{
        title = "糖果罐",
        subtitle = string.format("持有 ● %d　·　捕获 +2 / 重复 +5 / 读完一本书 +20",
            self.candies or 0),
        build = function(_, inner_w)
            local rows = VerticalGroup:new{ align = "center" }
            -- 本机 FrameContainer 的边框按 width 画、上报按内容算：
            -- 内容必须用固定尺寸的 CenterContainer 包住，上报宽 == 绘制宽，才不会跑偏
            local card_bs = Screen:scaleBySize(1)
            local card_pad = Screen:scaleBySize(8)
            local content_w = inner_w - 2 * (card_bs + card_pad)
            for _, it in ipairs(ITEM_DEFS) do
                local have = self:itemCount(it.key)
                -- 单价 / 说明 / 状态三行都按商品类型动态生成：
                -- 额外捕获是当天阶梯价，孵化加速有 3 天冷却，都不能写死。
                local price_txt, desc_txt, status_txt, can_buy
                if it.key == "catch" then
                    local p = self:shopCatchPrice()
                    local used = self:shopCatchUsed()
                    price_txt = p and string.format("● %d", p) or "今日已满"
                    desc_txt = string.format("%s（今日第 %d 次）", it.desc,
                        math.min(used + 1, #SHOP_CATCH_PRICES))
                    status_txt = string.format("今日 %d / %d", used, #SHOP_CATCH_PRICES)
                    can_buy = (p ~= nil) and (self.candies or 0) >= p
                elseif it.key == "hatch" then
                    local left = self:hatchCooldownLeft()
                    price_txt = string.format("● %d", it.cost)
                    desc_txt = it.desc
                    status_txt = string.format("蛋 %d/%d · %s",
                        self.egg_progress or 0, EGG_DAYS,
                        left > 0 and string.format("%d 小时后可用", math.ceil(left / 3600))
                            or "现在可用")
                    can_buy = (left <= 0) and (self.candies or 0) >= it.cost
                else
                    price_txt = string.format("● %d", it.cost)
                    desc_txt = it.desc
                    status_txt = string.format("持有 ×%d", have)
                    can_buy = (self.candies or 0) >= it.cost
                end
                -- 不要用 KOReader 的 Button：本机版本在未显式给尺寸时
                -- 手势区域无效，点了"兑换"回调根本不触发（实机日志无任何反应）。
                -- 用自绘的 makeFlatButton，尺寸明确、手势范围就是按钮本身。
                local btn = makeFlatButton("兑换", function()
                    self:buyItem(it.key, view)
                end, Screen:scaleBySize(92), Screen:scaleBySize(42),
                    { font = 17, color = can_buy and RGB.leaf_green or Blitbuffer.COLOR_GRAY })
                local vg = VerticalGroup:new{ align = "left",
                    HorizontalGroup:new{ align = "center",
                        makeCuteText(it.name, 18, true),
                        HorizontalSpan:new{ width = Screen:scaleBySize(6) },
                        makeText(price_txt, "xx_smallinfofont", false,
                            Blitbuffer.COLOR_GRAY_5),
                    },
                    VerticalSpan:new{ width = Screen:scaleBySize(3) },
                    makeText(desc_txt, "xx_smallinfofont", false, Blitbuffer.COLOR_GRAY_5),
                    VerticalSpan:new{ width = Screen:scaleBySize(6) },
                    HorizontalGroup:new{ align = "center",
                        makeText(status_txt, "xx_smallinfofont", false,
                            Blitbuffer.COLOR_GRAY),
                        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                        btn,
                    },
                }
                table.insert(rows, FrameContainer:new{
                    width = inner_w,
                    padding = card_pad, margin = 0,
                    bordersize = card_bs, radius = Screen:scaleBySize(10),
                    color = Blitbuffer.COLOR_GRAY_6, background = Blitbuffer.COLOR_WHITE,
                    LeftContainer:new{
                        dimen = Geom:new{ w = content_w, h = vg:getSize().h },
                        vg,
                    },
                })
                table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
            end
            return rows
        end,
    }
    UIManager:show(view)
end

-- 额外捕获：当天已买次数（跨天自动归零，不写进 items）
function Pokemon:shopCatchUsed(today)
    today = today or self:_today()
    local s = self.catch_buy
    if type(s) ~= "table" or s.date ~= today then return 0 end
    return tonumber(s.n) or 0
end

-- 当天第 n+1 次额外捕获的价格；已买满返回 nil
function Pokemon:shopCatchPrice(today)
    local n = self:shopCatchUsed(today)
    return SHOP_CATCH_PRICES[n + 1]
end

-- 孵化加速冷却剩余秒数，0 表示可以买
function Pokemon:hatchCooldownLeft()
    local last = tonumber(self.hatch_ts) or 0
    if last <= 0 then return 0 end
    local left = HATCH_BUY_CD - (os.time() - last)
    return left > 0 and left or 0
end

function Pokemon:buyItem(key, view)
    if DEBUG_MODE then
        logger.warn(string.format("[pokemon] buyItem 触发 key=%s candies=%d", key, self.candies or 0))
    end
    local def
    for _, d in ipairs(ITEM_DEFS) do
        if d.key == key then def = d end
    end
    if not def then return end

    local today = self:_today()
    -- 实际单价：额外捕获按当天已买次数阶梯涨价，其余用定义价
    local price = def.cost
    if key == "catch" then
        price = self:shopCatchPrice(today)
        if not price then
            UIManager:show(InfoMessage:new{
                text = "今天的额外捕获已经买满 3 次啦，明天再来～", timeout = 2 })
            return
        end
    end
    -- 孵化加速：3 天冷却，避免"点满 3 次当场孵"变成无限必新泵
    if key == "hatch" then
        local left = self:hatchCooldownLeft()
        if left > 0 then
            UIManager:show(InfoMessage:new{
                text = string.format("孵化加速还要等 %d 小时才能再用～",
                    math.ceil(left / 3600)), timeout = 3 })
            return
        end
    end
    if (self.candies or 0) < price then
        UIManager:show(InfoMessage:new{
            text = string.format("糖果不够啦（需要 ● %d），多读会儿书攒一攒～", price),
            timeout = 2 })
        return
    end
    self:addCandy(-price)
    if key == "rename" then
        self:save()
        -- 走 onClose：带整屏刷新，否则面板残影会留在输入框下面
        if view then view:onClose() end
        self:renamePartner()
        return
    end

    -- 额外捕获：花钱买一次捕获，不占当天名额、不动连续达标 / 首捕标记，
    -- 走 src="shop" 分支（_award 里对该来源强制必新）
    if key == "catch" then
        self.catch_buy = { date = today, n = self:shopCatchUsed(today) + 1 }
        self.shop_meta_ts = os.time()
        self:save()
        if view then view:onClose() end
        UIManager:scheduleIn(0.5, function()
            self:_award(today, false, "shop")
        end)
        return
    end

    local hatch_now = false
    local tip
    if key == "hatch" then
        self.hatch_ts = os.time()          -- 记冷却起点
        self.shop_meta_ts = os.time()
        self.egg_progress = (self.egg_progress or 0) + 1
        -- 攒满就当场孵化。原来这里只 +1 不判定，进度卡在 3/3 永远孵不出来
        if self.egg_progress >= EGG_DAYS then
            self.egg_progress = 0
            self.egg_hatched = (self.egg_hatched or 0) + 1
            self.catch_xp = (self.catch_xp or 0) + EGG_XP
            hatch_now = true
        else
            tip = string.format("蛋的孵化进度 +1 天（%d / %d）· 下次可用：3 天后",
                self.egg_progress, EGG_DAYS)
        end
    else
        self.items[key] = (self.items[key] or 0) + 1
        tip = "兑换成功，熏香会在下一次捕获时自动使用"
    end
    self:save()

    -- 先关面板并整刷，再延时给反馈：否则提示会被那次全屏刷新抹掉
    if view then view:onClose() end
    UIManager:scheduleIn(0.5, function()
        if hatch_now then
            self:_award(self:_today(), false, "egg")
        else
            UIManager:show(InfoMessage:new{ text = tip, timeout = 2 })
            self:openCandyJar()
        end
    end)
end

--------------------------------------------------------------------
-- 每日委托
--------------------------------------------------------------------

function Pokemon:_questEnsure()
    local today = self:_today()
    if self.quests and self.quests.date == today
        and self.quests.list and #self.quests.list == 3 then
        return self.quests
    end
    local seed = tonumber((today:gsub("%D", ""))) or 0
    -- 先洗类型组，再在组内挑一条：保证"时间类只有一条"，且每天组合都不同。
    -- 用自带状态的随机源，不碰 math.randomseed（见 seededRng 的说明）。
    local fams = { "time", "book", "clock", "act" }
    local rnd = seededRng(seed)
    for i = #fams, 2, -1 do
        local j = rnd(i)
        fams[i], fams[j] = fams[j], fams[i]
    end
    local list = {}
    for i = 1, 3 do
        local ids = QUEST_FAMILY[fams[i]]
        local id = ids[rnd(#ids)]
        local def = self:_questDef(id)
        if def then
            list[#list + 1] = { id = id, goal = def.goal, claimed = false }
        end
    end
    self.quests = { date = today, list = list }
    return self.quests
end

-- 当天计数器（遇到老朋友 / 进化 / 读完书）：按日期挂在一个小表里，
-- 跨天自动从 0 开始，不依赖 _questEnsure 的调用时机
function Pokemon:_dayCount(key)
    local c = self.day_counts
    if type(c) ~= "table" or c.date ~= self:_today() then return 0 end
    return tonumber(c[key]) or 0
end

function Pokemon:_bumpDayCount(key)
    local today = self:_today()
    local c = self.day_counts
    if type(c) ~= "table" or c.date ~= today then
        c = { date = today }
        self.day_counts = c
    end
    c[key] = (tonumber(c[key]) or 0) + 1
end

function Pokemon:_questValue(item)
    local today = self:_today()
    if item.id == "read15" or item.id == "read30"
        or item.id == "read45" or item.id == "read60" then
        return self.daily[today] or 0
    elseif item.id == "night" then
        return self.night_secs[today] or 0
    elseif item.id == "morning" then
        return self.morning_secs[today] or 0
    elseif item.id == "newbook" then
        -- 从 books_all 的首次打开时间推算，不再依赖内存标记：
        -- 用标记的话，重启 KOReader 或跨天重建委托都会把进度抹掉。
        for _, ts in pairs(self.books_all or {}) do
            if os.date("%Y-%m-%d", ts) == today then return 1 end
        end
        return 0
    elseif item.id == "finish" then
        return self:_dayCount("book")
    elseif item.id == "dup" then
        return self:_dayCount("dup")
    elseif item.id == "evo" then
        return self:_dayCount("evo")
    end
    return 0
end

function Pokemon:_questDef(id)
    for _, d in ipairs(QUEST_POOL) do
        if d.id == id then return d end
    end
end

function Pokemon:_questTick()
    local q = self:_questEnsure()
    local got = {}
    for _, item in ipairs(q.list) do
        if not item.claimed then
            local v = self:_questValue(item)
            if v >= item.goal then
                item.claimed = true
                local def = self:_questDef(item.id)
                if def then
                    if def.xp then self.catch_xp = (self.catch_xp or 0) + def.xp end
                    if def.candy then self:addCandy(def.candy) end
                    got[#got + 1] = def.text
                end
            end
        end
    end
    if #got > 0 then
        self:save()
        pcall(function()
            UIManager:show(InfoMessage:new{
                text = "委托完成：" .. table.concat(got, "、"),
                timeout = 3,
            })
        end)
    end
    -- 周常顺带结算（同一次 tick 里做，不额外开定时器）
    pcall(function() self:_weeklyTick() end)
end

function Pokemon:questProgressCount()
    local q = self:_questEnsure()
    local done = 0
    for _, item in ipairs(q.list) do
        if self:_questValue(item) >= item.goal then done = done + 1 end
    end
    return done, #q.list
end

-- 自然周起点（周一）与周序号：档案页和周常共用
-- 周序号从"第一个周一"1970-01-05 起按周递增，而不是用 %Y-W%W：
-- 那个格式在跨年那一周会从 2026-W52 跳到 2027-W00，同一周被当成两周，
-- 周常会在元旦重复结算一次。
local function weekStart(ts)
    local now = ts or os.time()
    local wday = tonumber(os.date("%w", now)) or 1   -- 0 = 周日
    local off = (wday == 0) and 6 or (wday - 1)      -- 周一为一周起点
    local monday = now - off * 86400
    local week_no = math.floor((monday - 4 * 86400) / (7 * 86400))
    return os.date("%Y-%m-%d", monday), tostring(week_no)
end

-- ====================================================================
-- 训练家档案：把「奖章 / 训练家状态 / 相遇记录 / 阅读周报」收成一页
-- 主面板原来这四项各占一格（13 格已超出屏高），合并后省下 3 格；
-- 想看细节的还从这一页点进去，四个老面板都保留，不丢功能。
-- ====================================================================
function Pokemon:openProfile()
    local hrs = self:readHours()
    local lv = self:currentLevel()
    local xp = self:totalXP()
    local caught = self:countCaught()
    local shiny_n = self:countShiny()
    local medal_n = self:countMedals()
    local pity = tonumber(self.shiny_pity) or 0

    -- 本周阅读：从 daily 里按当前自然周累加（时钟防呆：走冻结时间）
    local wk_now = self:_now()
    local wk_start, wk = weekStart(wk_now)
    local week_secs, week_days = 0, 0
    for i = 0, 6 do
        local d = os.date("%Y-%m-%d", wk_now - i * 86400)
        if d >= wk_start then
            local s = self.daily[d] or 0
            week_secs = week_secs + s
            if s >= (self.goal or 1800) then week_days = week_days + 1 end
        end
    end

    UIManager:show(PokemonPanelView:new{
        title = "训练家档案",
        subtitle = string.format("Lv.%d %s　·　累计阅读 %s　·　图鉴 %d / %d",
            lv, levelTitle(lv), fmtDuration(self.total_secs or 0), caught, TOTAL),
        build = function(v, inner_w)
            local rows = VerticalGroup:new{ align = "center" }
            local function line(txt, color, bold)
                local tw = makeText(txt, "xx_smallinfofont", bold or false,
                    color or Blitbuffer.COLOR_GRAY_5)
                table.insert(rows, CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = tw:getSize().h }, tw,
                })
            end
            local function bar(pct, color)
                table.insert(rows, PillBar:new{
                    width = inner_w, height = Screen:scaleBySize(7),
                    percentage = pct, fillcolor = color,
                })
                table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
            end

            -- 等级 / 经验
            if lv >= MAX_LEVEL then
                line(string.format("等级　Lv.%d（满级）　·　经验 %d", lv, xp), nil, true)
                bar(1, RGB.poke_red)
            else
                local cur, nxt = xpForLevel(lv), xpForLevel(lv + 1)
                line(string.format("等级　Lv.%d → Lv.%d　·　还差 %d XP",
                    lv, lv + 1, math.max(0, nxt - xp)), nil, true)
                bar((xp - cur) / math.max(1, nxt - cur), RGB.poke_red)
            end

            -- 阅读徽章
            local nb_i, nb, nb_need = self:nextBadge()
            if nb then
                local prev_h = (nb_i > 1) and BADGES[nb_i - 1].hours or 0
                line(string.format("徽章　%d / %d　·　下一枚「%s」还差 %.1f 小时",
                    self:badgeCount(), #BADGES, nb.name, nb_need), nil, true)
                bar((hrs - prev_h) / math.max(1, nb.hours - prev_h), RGB.water_blue)
            else
                line(string.format("徽章　%d / %d　·　已全部点亮", #BADGES, #BADGES), nil, true)
                bar(1, RGB.water_blue)
            end

            -- 闪光保底：让"一直没出闪光"这件事有可见的进度
            line(string.format("闪光保底　%d / %d 次（出闪即清零）", pity, SHINY_PITY),
                nil, true)
            bar(pity / SHINY_PITY, RGB.gold or RGB.poke_red)

            -- 一句话数据摘要
            line(string.format("图鉴 %d 只（闪光 %d）　·　奖章 %d 枚　·　连续达标 %d 天",
                caught, shiny_n, medal_n, self.streak_count or 0))
            line(string.format("当前连击 %d 次　·　本周阅读 %s　·　达标 %d 天",
                self.combo or 0, fmtDuration(week_secs), week_days))
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })

            -- 细节入口：四个老面板原样保留
            table.insert(rows, makeButtonRows({
                { { text = "奖章墙", callback = function()
                    v:onClose(); UIManager:scheduleIn(0.15, function() self:showMedals() end)
                end } },
                { { text = "完整统计", callback = function()
                    v:onClose(); UIManager:scheduleIn(0.15, function() self:showStats() end)
                end } },
                { { text = "相遇记录", callback = function()
                    v:onClose(); UIManager:scheduleIn(0.15, function() self:showRecent() end)
                end } },
                { { text = "阅读周报", callback = function()
                    v:onClose(); UIManager:scheduleIn(0.15, function() self:showWeekly() end)
                end } },
            }, inner_w))
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            line(string.format("本周目标：%s", (self:_weeklyDef() or {}).text or "-"))
            return rows
        end,
    })
end

-- ====================================================================
-- 周常：每周固定一条，进度全部由已有数据推算（不额外记状态）
-- ====================================================================
function Pokemon:_weeklyDef()
    local _, wk = weekStart(self:_now())
    local seed = tonumber((wk:gsub("%D", ""))) or 1
    -- 同一周内结果恒定，跨周才换：靠周号做种子，不必存"这周是哪条"
    local idx = (seed * 7 + 3) % #WEEKLY_POOL + 1
    return WEEKLY_POOL[idx], wk
end

function Pokemon:_weeklyValue(def)
    local now = self:_now()
    local start = weekStart(now)
    if def.id == "w_read4h" then
        local sum = 0
        for i = 0, 6 do
            local d = os.date("%Y-%m-%d", now - i * 86400)
            if d >= start then sum = sum + (self.daily[d] or 0) end
        end
        return sum
    elseif def.id == "w_book2" then
        local n = 0
        for _, ts in pairs(self.books_done or {}) do
            if os.date("%Y-%m-%d", ts) >= start then n = n + 1 end
        end
        return n
    elseif def.id == "w_new10" then
        -- 用首次相遇日期算"本周新收集"；用 ts 会把老面孔重遇也算成新的
        local n = 0
        for _, info in pairs(self.caught or {}) do
            if info.date and info.date >= start then n = n + 1 end
        end
        return n
    elseif def.id == "w_days5" then
        local n = 0
        for i = 0, 6 do
            local d = os.date("%Y-%m-%d", now - i * 86400)
            if d >= start and (self.daily[d] or 0) >= (self.goal or 1800) then
                n = n + 1
            end
        end
        return n
    end
    return 0
end

function Pokemon:_weeklyTick()
    local def, wk = self:_weeklyDef()
    if not def or self.weekly_claimed == wk then return end
    if self:_weeklyValue(def) < def.goal then return end
    self.weekly_claimed = wk
    if def.xp then self.catch_xp = (self.catch_xp or 0) + def.xp end
    if def.candy then self:addCandy(def.candy) end
    if def.item then
        self.items[def.item] = (self.items[def.item] or 0) + (def.n or 1)
    end
    self:save()
    pcall(function()
        UIManager:show(InfoMessage:new{
            text = string.format("本周目标达成：%s\n%s",
                def.text, self:_rewardLabel(def)),
            timeout = 4,
        })
    end)
end

-- 奖励文案：糖果 / 经验 / 道具，哪几项有就拼哪几项
function Pokemon:_rewardLabel(def)
    local t = {}
    if def.candy then t[#t + 1] = string.format("%d 糖果", def.candy) end
    if def.xp then t[#t + 1] = string.format("%d XP", def.xp) end
    if def.item then
        local names = { inc = "熏香", hatch = "孵化加速" }
        t[#t + 1] = string.format("%s×%d", names[def.item] or def.item, def.n or 1)
    end
    return table.concat(t, "　")
end

function Pokemon:openQuests()
    UIManager:show(PokemonPanelView:new{
        title = "每日委托",
        subtitle = "每天 0 点刷新 · 完成后自动发放奖励，不用手动领",
        build = function(_, inner_w)
            local q = self:_questEnsure()
            local rows = VerticalGroup:new{ align = "center" }
            -- 与糖果罐同理：内容用固定尺寸 CenterContainer 包住，避免边框跑偏
            local card_bs = Screen:scaleBySize(1)
            local card_pad = Screen:scaleBySize(8)
            local content_w = inner_w - 2 * (card_bs + card_pad)

            -- 一张委托卡：标题 + 状态 + 进度条 + 奖励/进度说明
            -- 单位跟着 def.unit 走，时间类显示分钟，其余显示本/次/只/天
            local function questCard(def, v, goal, tint)
                v = math.min(v, goal)
                local ok = v >= goal
                local prog_txt
                if def.unit == "分钟" then
                    prog_txt = string.format("%d / %d 分钟",
                        math.floor(v / 60), math.floor(goal / 60))
                else
                    prog_txt = string.format("%d / %d %s", v, goal, def.unit or "")
                end
                local vg = VerticalGroup:new{ align = "left",
                    HorizontalGroup:new{ align = "center",
                        makeText(def.text .. "　", "smallinfofont", true),
                        makeText(ok and "✓ 已完成" or "进行中", "xx_smallinfofont", false,
                            ok and RGB.leaf_green or Blitbuffer.COLOR_GRAY),
                    },
                    VerticalSpan:new{ width = Screen:scaleBySize(4) },
                    PillBar:new{
                        width = content_w,
                        height = Screen:scaleBySize(6),
                        percentage = goal > 0 and (v / goal) or 0,
                        fillcolor = ok and RGB.leaf_green or (tint or RGB.water_blue),
                    },
                    VerticalSpan:new{ width = Screen:scaleBySize(3) },
                    makeText(string.format("奖励 %s　·　%s",
                        self:_rewardLabel(def), prog_txt), "xx_smallinfofont", false,
                        Blitbuffer.COLOR_GRAY_5),
                }
                local card = FrameContainer:new{
                    width = inner_w,
                    padding = card_pad, margin = 0,
                    bordersize = card_bs, radius = Screen:scaleBySize(10),
                    color = Blitbuffer.COLOR_GRAY_6, background = Blitbuffer.COLOR_WHITE,
                    LeftContainer:new{
                        dimen = Geom:new{ w = content_w, h = vg:getSize().h },
                        vg,
                    },
                }
                table.insert(rows, card)
                table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(8) })
            end

            for _, item in ipairs(q.list) do
                local def = self:_questDef(item.id)
                if def then questCard(def, self:_questValue(item), item.goal) end
            end

            -- 本周目标：每周固定一条，比日常重；完成后同样自动结算
            local wdef, wk = self:_weeklyDef()
            if wdef then
                table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                local line = TextWidget:new{
                    text = string.format("本周目标（%s）", wk),
                    face = Font:getFace("xx_smallinfofont"),
                    fgcolor = Blitbuffer.COLOR_GRAY_4,
                }
                table.insert(rows, CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = line:getSize().h }, line,
                })
                table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(6) })
                local wv = self:_weeklyValue(wdef)
                if self.weekly_claimed == wk then
                    -- 已完成：进度条填满，避免"数字够了但条没满"的错觉
                    questCard(wdef, wdef.goal, wdef.goal, RGB.leaf_green)
                else
                    questCard(wdef, wv, wdef.goal, RGB.poke_red)
                end
            end
            return rows
        end,
    })
end

--------------------------------------------------------------------
-- 阅读徽章：按累计阅读时长点亮（不看收集度，只看读了多少）
--------------------------------------------------------------------

function Pokemon:readHours()
    return (self.total_secs or 0) / 3600
end

function Pokemon:badgeCount()
    local n = 0
    for _ in pairs(self.badges or {}) do n = n + 1 end
    return n
end

-- 下一枚要点的徽章：index, def, 还差小时数
function Pokemon:nextBadge()
    local hrs = self:readHours()
    for i, b in ipairs(BADGES) do
        if not self.badges[i] then
            return i, b, math.max(0, b.hours - hrs)
        end
    end
end

-- 点亮检查：读时长到线即发徽章 + 奖励（在 _addTime 里每 tick 调一次，开销可忽略）
function Pokemon:_badgeCheck()
    local hrs = self:readHours()
    local newly = {}
    for i, b in ipairs(BADGES) do
        if not self.badges[i] and hrs >= b.hours then
            self.badges[i] = os.time()
            newly[#newly + 1] = { i = i, name = b.name, hours = b.hours }
        end
    end
    if #newly == 0 then return end
    self.items = self.items or {}
    local candy = 0
    for _, it in ipairs(newly) do
        candy = candy + 20 + it.i * 10
    end
    self.candies = (self.candies or 0) + candy
    self.items.inc = (self.items.inc or 0) + #newly
    self.items.hatch = (self.items.hatch or 0) + #newly
    self.catch_xp = (self.catch_xp or 0) + 100 * #newly
    self:save()
    if self.suspended then return end
    local lines = {}
    for _, it in ipairs(newly) do
        lines[#lines + 1] = string.format("「%s」徽章 · 阅读满 %d 小时", it.name, it.hours)
    end
    pcall(function()
        UIManager:show(PokemonInfoView:new{
            title = #newly == 1 and "点亮了一枚阅读徽章！"
                or string.format("一次点亮 %d 枚徽章！", #newly),
            text = string.format(
                "%s\n\n累计阅读 %.1f 小时\n\n奖励：糖果 +%d　·　熏香 ×%d　·　孵化加速 ×%d　·　+%d XP",
                table.concat(lines, "\n"), hrs, candy, #newly, #newly, 100 * #newly),
        })
    end)
end

function Pokemon:openBadges()
    local hrs = self:readHours()
    local next_i, next_b = self:nextBadge()
    UIManager:show(PokemonPanelView:new{
        title = "阅读徽章",
        subtitle = string.format("按累计阅读时长点亮 · 已点亮 %d / %d",
            self:badgeCount(), #BADGES),
        build = function(_, inner_w)
            local rows = VerticalGroup:new{ align = "center" }
            local function line(txt, face, bold, color)
                local tw = makeText(txt, face or "xx_smallinfofont", bold or false,
                    color or Blitbuffer.COLOR_GRAY_5)
                table.insert(rows, CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = tw:getSize().h }, tw,
                })
            end
            line(string.format("累计阅读 %.1f 小时", hrs),
                "smallinfofont", true, RGB.poke_red)
            if next_b then
                line(string.format("下一枚「%s」还差 %.1f 小时",
                    next_b.name, math.max(0, next_b.hours - hrs)),
                    "xx_smallinfofont", false, RGB.leaf_green)
            else
                line(string.format("%d 枚徽章全部点亮，太厉害了！", #BADGES),
                    "xx_smallinfofont", false, RGB.leaf_green)
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(10) })
            -- 十枚走 4 列 3 行，九枚走 3×3
            local cols = (#BADGES > 9) and 4 or 3
            local rows_n = math.ceil(#BADGES / cols)
            local gap = Screen:scaleBySize(8)
            -- 格子别跟着变大方，限宽防止面板超出屏幕
            local cell_w = math.min(
                math.floor((inner_w - (cols - 1) * gap) / cols),
                Screen:scaleBySize(118))
            local cell_h = cell_w
            for r = 0, rows_n - 1 do
                local row = HorizontalGroup:new{ align = "center" }
                for c = 0, cols - 1 do
                    local idx = r * cols + c + 1
                    local b = BADGES[idx]
                    if c > 0 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                    if b then
                        local earned = self.badges[idx]
                        local is_next = (idx == next_i)
                        local sub
                        if earned then
                            sub = "已点亮"
                        elseif is_next then
                            sub = string.format("还差 %.1fh", math.max(0, b.hours - hrs))
                        else
                            sub = string.format("%d 小时", b.hours)
                        end
                        local main_color = earned and RGB.poke_red
                            or (is_next and RGB.leaf_green or Blitbuffer.COLOR_GRAY)
                        table.insert(row, FrameContainer:new{
                            width = cell_w, height = cell_h,
                            padding = 0, margin = 0,
                            bordersize = Screen:scaleBySize(earned and 2 or 1),
                            radius = math.floor(cell_w / 2),
                            color = earned and RGB.poke_red
                                or (is_next and RGB.leaf_green or Blitbuffer.COLOR_GRAY_6),
                            background = Blitbuffer.COLOR_WHITE,
                            CenterContainer:new{
                                dimen = Geom:new{ w = cell_w, h = cell_h },
                                VerticalGroup:new{ align = "center",
                                    makeCuteText(earned and "✓" or "?", 20, true, main_color),
                                    makeCuteText(b.name, 13, false,
                                        earned and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY),
                                    makeText(sub, "xx_smallinfofont", false,
                                        earned and RGB.poke_red
                                            or (is_next and RGB.leaf_green or Blitbuffer.COLOR_GRAY_5)),
                                },
                            },
                        })
                    else
                        table.insert(row, HorizontalSpan:new{ width = cell_w })
                    end
                end
                table.insert(rows, row)
                -- 每两行之间都要留间距。之前写成 r == 0，只有第 1、2 行之间有缝，
                -- 10 枚徽章排 3 行时第 2、3 行会贴成一块。
                if r < rows_n - 1 then
                    table.insert(rows, VerticalSpan:new{ width = gap })
                end
            end
            table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(12) })
            line("每点亮一枚：糖果 + 熏香 + 孵化加速", "xx_smallinfofont", false,
                Blitbuffer.COLOR_GRAY_5)
            return rows
        end,
    })
end

--------------------------------------------------------------------
-- 读完一本书
--------------------------------------------------------------------

function Pokemon:_checkBookFinished()
    local ok, pct = pcall(function()
        if self.ui and self.ui.doc_settings then
            return self.ui.doc_settings:readSetting("percent_finished")
        end
    end)
    if not ok or type(pct) ~= "number" or pct < 0.99 then return end
    local path = self:_currentBookPath()
    if not path or self.books_done[path] then return end
    self.books_done[path] = os.time()
    self:_grantBookReward()
end

-- debug_title / is_debug 仅调试面板使用：跳过 books_done 记录，
-- 捕获侧也不再推进每日状态（不占当天名额、不影响连续天数与首捕标记）。
function Pokemon:_grantBookReward(debug_title, is_debug)
    local title = debug_title or self:_currentBookTitle() or "这本书"
    self.catch_xp = (self.catch_xp or 0) + BOOK_XP
    self:addCandy(CANDY_BOOK)
    self.items.inc = (self.items.inc or 0) + 1
    if not is_debug then self:_bumpDayCount("book") end  -- 委托「读完 1 本书」
    self:save()
    local n = 0
    for _ in pairs(self.books_done) do n = n + 1 end
    if self.suspended then return end
    pcall(function()
        UIManager:show(PokemonInfoView:new{
            title = "读完一本书！",
            text = string.format(
                "《%s》读完了！\n\n累计读完 %d 本\n+%d XP　·　+%d 糖果　·　+1 熏香\n\n一只稀有伙伴被你的坚持吸引过来了…",
                title, n, BOOK_XP, CANDY_BOOK),
        })
    end)
    local function try_book(retries)
        if self.suspended then
            if retries > 0 then
                UIManager:scheduleIn(8, function() try_book(retries - 1) end)
            end
            return
        end
        self:_award(self:_today(), is_debug and true or false, "book")
    end
    UIManager:scheduleIn(4, function() try_book(12) end)
end

function Pokemon:_pickLegendaryNew()
    -- 读完一本书：从未捕获的「稀有 + 传说」池里均匀抽一只。
    -- 原来只抽传说（94 只），会把最珍贵的一档太快抽空，降为稀有及以上。
    local pool = {}
    for _, mon in ipairs(DEX) do
        if (mon.rarity == "legendary" or mon.rarity == "rare")
            and not self.caught[mon.id] then
            pool[#pool + 1] = mon
        end
    end
    if #pool == 0 then return nil end
    math.randomseed(os.time() + math.floor(time.now() % 997))
    return pool[math.random(#pool)], false
end

return Pokemon
