"""Static content for the Phase-0 director simulator.

Everything a designer might want to tune lives here so the engine stays free of
literals: the city map, the ten player archetypes, and the director's directive
catalogue.

Design notes
------------
* Locations are *static*; per-session state (crime pressure, police boost) is
  kept on :class:`director_sim.engine.World`, never on the dataclass.
* Archetypes carry motivation weights in ``0..1`` and skill values in ``0..1``.
  Utility is a plain dot product, so adding a motivation is additive work.
* Every directive records which real ``custom-director`` action(s) could
  realise it and, when none can, the blocking gap. That mapping is the main
  Phase-0 output: it tells us what the action whitelist is still missing.
"""

from __future__ import annotations

from dataclasses import dataclass, field


# --------------------------------------------------------------------------
# Motives and event vocabulary
# --------------------------------------------------------------------------

MOTIVES: tuple[str, ...] = (
    "money",
    "safety",
    "status",
    "thrill",
    "duty",
    "loyalty",
    "curiosity",
)

# Simulation-only event types. The live perception layer already emits
# ``player.*`` / ``quest.*`` / ``economy.*`` / ``story.*``; these are the
# additional subtypes a director needs in order to reason about drama. They
# are *not* claimed to exist in FXServer yet -- see DIRECTOR_PHASE0.md.
EVENT_TYPES: tuple[str, ...] = (
    "player.work",
    "player.rob",
    "player.attack",
    "player.arrest",
    "player.patrol",
    "player.heal",
    "player.deal",
    "player.gamble",
    "player.investigate",
    "player.socialize",
    "player.hide",
    "player.rest",
    "player.help",
    "player.injury",
    "player.death",
    "player.revive",
    "player.jail",
    "player.spotlight",
    "economy.transaction",
    "story.beat",
    "story.hook",
    "director.directive",
    "world.weather",
    "world.blackout",
)


# --------------------------------------------------------------------------
# City
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Location:
    """A coarse-grained city district.

    ``police``/``wealth``/``danger`` are static 0..1 priors. ``pos`` is only
    used to derive travel time on a Manhattan grid.
    """

    id: str
    name: str
    pos: tuple[int, int]
    police: float
    wealth: float
    danger: float
    tags: tuple[str, ...] = ()

    @property
    def nightlife(self) -> bool:
        return "夜间" in self.tags


LOCATIONS: dict[str, Location] = {
    "downtown": Location("downtown", "市中心", (1, 1), 0.75, 0.90, 0.35, ("商业", "人流")),
    "docks": Location("docks", "码头", (0, 1), 0.20, 0.40, 0.85, ("走私", "仓库")),
    "industrial": Location("industrial", "工业区", (0, 2), 0.30, 0.35, 0.60, ("工厂", "黑市")),
    "suburbs": Location("suburbs", "郊区", (1, 0), 0.40, 0.60, 0.10, ("住宅", "安静")),
    "hospital": Location("hospital", "医院", (1, 2), 0.50, 0.50, 0.10, ("医疗", "安全")),
    "pd": Location("pd", "警局", (2, 2), 1.00, 0.50, 0.05, ("警察", "安全")),
    "casino": Location("casino", "赌场", (2, 1), 0.55, 0.85, 0.40, ("金钱", "夜间")),
    "club": Location("club", "夜店", (2, 0), 0.45, 0.70, 0.30, ("社交", "夜间")),
    "highway": Location("highway", "高速", (1, 3), 0.25, 0.20, 0.50, ("追逐", "逃离")),
    "airport": Location("airport", "机场", (3, 1), 0.60, 0.60, 0.20, ("出入", "货运")),
}


def travel_ticks(a: str, b: str) -> int:
    """Manhattan travel time in ticks (one tick = 5 in-game seconds)."""

    (ax, ay), (bx, by) = LOCATIONS[a].pos, LOCATIONS[b].pos
    return max(1, abs(ax - bx) + abs(ay - by))


# --------------------------------------------------------------------------
# Players
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Archetype:
    id: str
    name: str
    job: str
    home: str
    cash: int
    weights: dict[str, float]
    skills: dict[str, float]
    tagline: str


ARCHETYPES: dict[str, Archetype] = {
    "cop_chief": Archetype(
        "cop_chief", "陈国栋", "police", "pd", 1800,
        {"duty": 1.0, "status": 0.6, "safety": 0.5, "money": 0.3, "loyalty": 0.6, "curiosity": 0.3, "thrill": 0.15},
        {"risk": 0.4, "empathy": 0.5, "greed": 0.2, "curiosity": 0.5},
        "干了二十年的老警长，最怕这座城市在他手上烂掉。",
    ),
    "rookie_cop": Archetype(
        "rookie_cop", "Leo", "police", "pd", 600,
        {"duty": 0.8, "thrill": 0.5, "status": 0.4, "safety": 0.6, "money": 0.3, "loyalty": 0.4, "curiosity": 0.4},
        {"risk": 0.6, "empathy": 0.6, "greed": 0.1, "curiosity": 0.6},
        "警校刚毕业，还没学会什么时候该装作没看见。",
    ),
    "gang_boss": Archetype(
        "gang_boss", "老K", "gang", "docks", 2400,
        {"money": 0.8, "status": 0.9, "loyalty": 0.5, "thrill": 0.4, "safety": 0.5, "duty": 0.1, "curiosity": 0.2},
        {"risk": 0.8, "empathy": 0.2, "greed": 0.9, "curiosity": 0.3},
        "码头的话事人。他要的不是钱，是别人叫他一声 K 哥。",
    ),
    "enforcer": Archetype(
        "enforcer", "阿豹", "gang", "industrial", 400,
        {"loyalty": 0.9, "thrill": 0.7, "status": 0.5, "money": 0.5, "safety": 0.3, "duty": 0.1, "curiosity": 0.1},
        {"risk": 0.9, "empathy": 0.2, "greed": 0.4, "curiosity": 0.1},
        "老K 的刀。他不问为什么，只问几点。",
    ),
    "medic": Archetype(
        "medic", "林医生", "medic", "hospital", 900,
        {"duty": 0.9, "money": 0.6, "safety": 0.6, "status": 0.3, "loyalty": 0.4, "curiosity": 0.3, "thrill": 0.2},
        {"risk": 0.3, "empathy": 0.9, "greed": 0.2, "curiosity": 0.4},
        "急诊科的主治。她救过的人里，有一半第二天又躺回来。",
    ),
    "mechanic": Archetype(
        "mechanic", "老周", "mechanic", "industrial", 700,
        {"money": 0.9, "safety": 0.5, "status": 0.3, "loyalty": 0.4, "duty": 0.3, "thrill": 0.2, "curiosity": 0.3},
        {"risk": 0.3, "empathy": 0.4, "greed": 0.7, "curiosity": 0.4},
        "全城最好的改装师。他的账本比警局的档案还全。",
    ),
    "gambler": Archetype(
        "gambler", "小美", "gambler", "casino", 300,
        {"thrill": 1.0, "money": 0.9, "status": 0.4, "safety": 0.2, "loyalty": 0.3, "duty": 0.1, "curiosity": 0.5},
        {"risk": 0.9, "empathy": 0.4, "greed": 0.8, "curiosity": 0.5},
        "她总说“最后一把”，然后输掉明天的房租。",
    ),
    "journalist": Archetype(
        "journalist", "方姐", "journalist", "downtown", 500,
        {"curiosity": 1.0, "status": 0.8, "duty": 0.5, "safety": 0.3, "money": 0.4, "loyalty": 0.3, "thrill": 0.5},
        {"risk": 0.6, "empathy": 0.5, "greed": 0.2, "curiosity": 0.95},
        "她相信真相有价格，而且她知道该找谁买单。",
    ),
    "dealer": Archetype(
        "dealer", "黑仔", "dealer", "docks", 800,
        {"money": 1.0, "thrill": 0.6, "safety": 0.5, "loyalty": 0.3, "status": 0.4, "duty": 0.05, "curiosity": 0.2},
        {"risk": 0.7, "empathy": 0.3, "greed": 0.9, "curiosity": 0.2},
        "他只做熟客。熟客的定义是还没被抓的那些。",
    ),
    "civilian": Archetype(
        "civilian", "王叔", "civilian", "suburbs", 350,
        {"safety": 1.0, "money": 0.6, "loyalty": 0.5, "status": 0.2, "duty": 0.4, "thrill": 0.1, "curiosity": 0.2},
        {"risk": 0.1, "empathy": 0.7, "greed": 0.4, "curiosity": 0.3},
        "开小卖部的。他只想把女儿供到大学毕业。",
    ),
}


# --------------------------------------------------------------------------
# Income
# --------------------------------------------------------------------------

INCOME: dict[str, int] = {
    "police": 95,
    "medic": 120,
    "mechanic": 135,
    "journalist": 70,
    "civilian": 80,
    "gambler": 40,
    "dealer": 0,
    "gang": 0,
}


# --------------------------------------------------------------------------
# Director directives
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Directive:
    """A narrative beat the director may schedule.

    ``realized_by`` lists the ``custom-director`` actions that can express the
    directive today. ``gap`` is set when the list cannot fully realise it.
    """

    id: str
    name: str
    intent: str
    tension: float
    desc: str
    realized_by: tuple[str, ...] = ()
    gap: str | None = None
    requires: tuple[str, ...] = ()


DIRECTIVES: dict[str, Directive] = {
    "incite_crime": Directive(
        "incite_crime", "制造犯罪机会", "escalate", 14.0,
        "在一处地点放入一桩值得被看见的犯罪：一笔货、一次交易、一个落单的目标。",
        ("start_quest", "announce", "spawn_vehicle"),
        "crime 类 quest 必须已在 custom-quest catalog 中；没有 spawn_ped/spawn_prop，"
        "“一笔货”只能靠叙事文本，玩家无法真的看到它。",
        ("loc",),
    ),
    "police_crackdown": Directive(
        "police_crackdown", "警方突击", "escalate", 12.0,
        "警力向某区倾斜：盘查、封路、增加巡逻密度。",
        ("announce", "spawn_vehicle"),
        "没有 set_police_presence / dispatch 动作；只能靠 announce 叙事，"
        "真实的警力调度要人手改 job 或依赖既有警察玩家自觉。",
        ("loc",),
    ),
    "blackout": Directive(
        "blackout", "停电", "escalate", 10.0,
        "整片街区断电，监控失效，犯罪成本瞬间下降。",
        ("set_weather", "announce"),
        "set_weather 只改视觉天气，无法真正关闭路灯/监控/电子锁；"
        "需要一个 world_state 级别的 blackout 开关。",
        ("loc",),
    ),
    "gang_summit": Directive(
        "gang_summit", "帮派谈判", "escalate", 9.0,
        "把两个帮派的人叫到同一张桌子上。谈成了是和平，谈崩了是战争。",
        ("start_quest", "announce"),
        "没有批量 teleport / group 动作，无法保证两拨人真的到场；"
        "start_quest 只能按人发，不能成组。",
        ("loc",),
    ),
    "personal_hook": Directive(
        "personal_hook", "私人钩子", "spotlight", 7.0,
        "给一个被冷落的玩家一条只属于他的线：旧仇人、家人、一笔旧账。",
        ("start_quest", "notify"),
        "没有 spawn_ped，无法让“旧仇人”真的出现在玩家面前；"
        "notify 只是文字，玩家没有可交互对象。",
        ("cid",),
    ),
    "media_wave": Directive(
        "media_wave", "媒体发酵", "advance", 6.0,
        "一件事被媒体放大，全城开始谈论它，相关的人被迫表态。",
        ("announce", "notify"),
        "没有动态 news / NPC 反应系统；announce 是一次性广播，不能持续发酵。",
        ("loc",),
    ),
    "celebrity_visit": Directive(
        "celebrity_visit", "名人到访", "relax", 5.0,
        "一个有名的人出现在某处，人群聚集，警力被迫分散。",
        ("spawn_vehicle", "announce"),
        "没有 spawn_ped；只能刷一辆车加一条广播，人群不会真的聚集。",
        ("loc",),
    ),
    "economic_shock": Directive(
        "economic_shock", "经济波动", "escalate", 6.0,
        "物价、工资或某类货品的价格突然变化，所有人的算盘都要重打。",
        ("add_money", "grant_item", "remove_item"),
        "add_money 是逐玩家操作，没有全局价格/工资旋钮；"
        "做不到“全城物价 +20%”。",
        (),
    ),
    "weather_shift": Directive(
        "weather_shift", "天气变化", "relax", -3.0,
        "下雨、起雾或放晴。天气改变人们愿不愿意出门。",
        ("set_weather",),
        None,
        ("weather",),
    ),
    "calm_day": Directive(
        "calm_day", "刻意的平静", "relax", -8.0,
        "什么都不发生。让玩家有时间消化上一幕，也让下一次爆发更响。",
        ("set_weather", "announce"),
        None,
        (),
    ),
    "advance_storyline": Directive(
        "advance_storyline", "推进线索", "advance", 8.0,
        "把一条已经开了头的线往前推一步：证据出现、人消失、条件变化。",
        ("start_quest", "announce", "set_time_of_day"),
        "没有 story-engine 的“推进到下一步”接口；只能另起一个 quest，"
        "叙事连续性靠人写。",
        ("storyline",),
    ),
    "no_op": Directive(
        "no_op", "不介入", "neutral", 0.0,
        "导演选择沉默。不是每个节拍都需要一个事件。",
        (),
        None,
        (),
    ),
}


ESCALATE_POOL: tuple[str, ...] = (
    "incite_crime",
    "police_crackdown",
    "blackout",
    "gang_summit",
    "economic_shock",
    "personal_hook",
)

RELAX_POOL: tuple[str, ...] = (
    "calm_day",
    "weather_shift",
    "celebrity_visit",
)
