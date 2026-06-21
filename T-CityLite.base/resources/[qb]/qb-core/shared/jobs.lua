QBShared = QBShared or {}
QBShared.ForceJobDefaultDutyAtLogin = true -- true: Force duty state to jobdefaultDuty | false: set duty state from database last saved

-- ==============================================================
-- 统一五级组织模板 — 职业 (Jobs)
-- 等级体系: 0=实习 → 1=正式 → 2=小组长 → 3=副部长 → 4=Boss
-- ==============================================================
QBShared.Jobs = {
	-- === 默认无业状态 ===
	unemployed = { label = 'Civilian', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },

	-- ==============================================================
	-- 政府 / 司法
	-- ==============================================================

	-- === 市政厅 / City Hall ===
	mayor = {
		label = 'City Hall',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Intern', payment = 30 },            -- 实习生
			['1'] = { name = 'Clerk', payment = 50 },             -- 办事员
			['2'] = { name = 'Supervisor', payment = 80 },        -- 科室主管
			['3'] = { name = 'Deputy Mayor', payment = 120 },     -- 副市长
			['4'] = { name = 'Mayor', isboss = true, payment = 200 }, -- 市长
		},
	},

	-- === 司法系统 / Honorary ===
	judge = {
		label = 'Honorary',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Law Clerk', payment = 40 },         -- 法官助理
			['1'] = { name = 'Associate Counsel', payment = 70 }, -- 助理法律顾问
			['2'] = { name = 'Magistrate', payment = 100 },       -- 地方法官
			['3'] = { name = 'District Judge', payment = 150 },   -- 地区法官
			['4'] = { name = 'Chief Justice', isboss = true, payment = 200 }, -- 首席大法官
		},
	},

	-- === 律师事务所 / Law Firm ===
	lawyer = {
		label = 'Law Firm',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Paralegal', payment = 30 },         -- 律师助理
			['1'] = { name = 'Junior Associate', payment = 50 },  -- 初级律师
			['2'] = { name = 'Senior Associate', payment = 80 },  -- 高级律师
			['3'] = { name = 'Partner', payment = 130 },          -- 合伙人
			['4'] = { name = 'Managing Partner', isboss = true, payment = 180 }, -- 管理合伙人
		},
	},

	-- ==============================================================
	-- 紧急服务
	-- ==============================================================

	-- === 警察 / Law Enforcement ===
	police = {
		label = 'Law Enforcement',
		type = 'leo',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },           -- 实习警员
			['1'] = { name = 'Officer', payment = 75 },           -- 正式警员
			['2'] = { name = 'Sergeant', payment = 100 },         -- 警司/小组长
			['3'] = { name = 'Lieutenant', payment = 125 },       -- 副警监/副部长
			['4'] = { name = 'Chief', isboss = true, payment = 150 }, -- 警长/Boss
		},
	},

	-- === 医护 / EMS ===
	ambulance = {
		label = 'EMS',
		type = 'ems',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },           -- 实习医护
			['1'] = { name = 'Paramedic', payment = 75 },         -- 正式急救员
			['2'] = { name = 'Doctor', payment = 100 },           -- 医生/小组长
			['3'] = { name = 'Surgeon', payment = 125 },          -- 外科/副部长
			['4'] = { name = 'Chief', isboss = true, payment = 150 }, -- 首席/Boss
		},
	},

	-- ==============================================================
	-- 交通运输
	-- ==============================================================

	-- === 出租车 / Taxi ===
	taxi = {
		label = 'Taxi',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 30 },           -- 实习司机
			['1'] = { name = 'Driver', payment = 50 },            -- 正式司机
			['2'] = { name = 'VIP Driver', payment = 75 },        -- VIP 专车司机
			['3'] = { name = 'Fleet Supervisor', payment = 100 }, -- 车队主管
			['4'] = { name = 'Manager', isboss = true, payment = 150 }, -- 经理/Boss
		},
	},

	-- === 公交 / Bus ===
	bus = {
		label = 'Bus',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习司机
			['1'] = { name = 'Driver', payment = 50 },            -- 正式司机
			['2'] = { name = 'Senior Driver', payment = 70 },     -- 资深司机
			['3'] = { name = 'Route Supervisor', payment = 90 },  -- 线路主管
			['4'] = { name = 'Depot Manager', isboss = true, payment = 130 }, -- 车场经理/Boss
		},
	},

	-- === 货运 / Trucker ===
	trucker = {
		label = 'Trucker',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习司机
			['1'] = { name = 'Driver', payment = 50 },            -- 正式司机
			['2'] = { name = 'Senior Driver', payment = 75 },     -- 资深司机/小组长
			['3'] = { name = 'Dispatcher', payment = 100 },       -- 调度员
			['4'] = { name = 'Logistics Manager', isboss = true, payment = 150 }, -- 物流经理/Boss
		},
	},

	-- === 拖车 / Towing ===
	tow = {
		label = 'Towing',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习操作员
			['1'] = { name = 'Operator', payment = 50 },          -- 正式拖车员
			['2'] = { name = 'Senior Operator', payment = 75 },   -- 高级操作员
			['3'] = { name = 'Supervisor', payment = 100 },       -- 现场主管
			['4'] = { name = 'Manager', isboss = true, payment = 150 }, -- 经理/Boss
		},
	},

	-- ==============================================================
	-- 车辆相关
	-- ==============================================================

	-- === 汽车经销商 / Vehicle Dealer ===
	cardealer = {
		label = 'Vehicle Dealer',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习销售
			['1'] = { name = 'Showroom Sales', payment = 50 },    -- 展厅销售
			['2'] = { name = 'Business Sales', payment = 80 },    -- 企业销售/小组长
			['3'] = { name = 'Finance', payment = 120 },          -- 金融专员/副部长
			['4'] = { name = 'Dealer Principal', isboss = true, payment = 180 }, -- 店主/Boss
		},
	},

	-- === LS Customs (mechanic 1/2/3) — 统一车间命名 ===
	mechanic = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice', payment = 30 },        -- 学徒
			['1'] = { name = 'Technician', payment = 50 },        -- 技工
			['2'] = { name = 'Specialist', payment = 80 },        -- 专修技师/小组长
			['3'] = { name = 'Shop Foreman', payment = 120 },     -- 车间领班/副部长
			['4'] = { name = 'Shop Owner', isboss = true, payment = 180 }, -- 店主/Boss
		},
	},
	mechanic2 = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice', payment = 30 },
			['1'] = { name = 'Technician', payment = 50 },
			['2'] = { name = 'Specialist', payment = 80 },
			['3'] = { name = 'Shop Foreman', payment = 120 },
			['4'] = { name = 'Shop Owner', isboss = true, payment = 180 },
		},
	},
	mechanic3 = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice', payment = 30 },
			['1'] = { name = 'Technician', payment = 50 },
			['2'] = { name = 'Specialist', payment = 80 },
			['3'] = { name = 'Shop Foreman', payment = 120 },
			['4'] = { name = 'Shop Owner', isboss = true, payment = 180 },
		},
	},

	-- === Beeker's Garage ===
	beeker = {
		label = 'Beeker\'s Garage',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice', payment = 30 },
			['1'] = { name = 'Technician', payment = 50 },
			['2'] = { name = 'Specialist', payment = 80 },
			['3'] = { name = 'Shop Foreman', payment = 120 },
			['4'] = { name = 'Shop Owner', isboss = true, payment = 180 },
		},
	},

	-- === Benny's Original Motor Works ===
	bennys = {
		label = 'Benny\'s Original Motor Works',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice', payment = 30 },
			['1'] = { name = 'Technician', payment = 50 },
			['2'] = { name = 'Specialist', payment = 80 },
			['3'] = { name = 'Shop Foreman', payment = 120 },
			['4'] = { name = 'Shop Owner', isboss = true, payment = 180 },
		},
	},

	-- ==============================================================
	-- 房地产
	-- ==============================================================

	realestate = {
		label = 'Real Estate',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习中介
			['1'] = { name = 'House Sales', payment = 50 },       -- 住宅销售
			['2'] = { name = 'Business Sales', payment = 80 },    -- 商业地产销售/小组长
			['3'] = { name = 'Broker', payment = 130 },           -- 持牌经纪人/副部长
			['4'] = { name = 'Agency Owner', isboss = true, payment = 200 }, -- 事务所老板/Boss
		},
	},

	-- ==============================================================
	-- 杂项 / 公共服务
	-- ==============================================================

	-- === 新闻媒体 / Reporter ===
	reporter = {
		label = 'Reporter',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Intern', payment = 30 },            -- 实习记者
			['1'] = { name = 'Reporter', payment = 50 },          -- 正式记者
			['2'] = { name = 'Senior Reporter', payment = 80 },   -- 资深记者/小组长
			['3'] = { name = 'Editor', payment = 120 },           -- 编辑/副部长
			['4'] = { name = 'Editor-in-Chief', isboss = true, payment = 180 }, -- 主编/Boss
		},
	},

	-- === 环卫 / Garbage ===
	garbage = {
		label = 'Garbage',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 30 },           -- 实习清洁工
			['1'] = { name = 'Collector', payment = 50 },         -- 正式收集员
			['2'] = { name = 'Crew Leader', payment = 75 },       -- 小队领班
			['3'] = { name = 'Route Supervisor', payment = 100 }, -- 路线主管
			['4'] = { name = 'Operations Manager', isboss = true, payment = 150 }, -- 运营经理/Boss
		},
	},

	-- === 葡萄酒庄园 / Vineyard ===
	vineyard = {
		label = 'Vineyard',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Seasonal Worker', payment = 20 },   -- 季节工/实习
			['1'] = { name = 'Vineyard Worker', payment = 40 },   -- 正式庄园工人
			['2'] = { name = 'Cellar Hand', payment = 65 },       -- 酿酒助理/小组长
			['3'] = { name = 'Winemaker', payment = 100 },        -- 酿酒师/副部长
			['4'] = { name = 'Vineyard Owner', isboss = true, payment = 160 }, -- 庄园主/Boss
		},
	},

	-- === 矿业公司 / Mining Company ===
	miner = {
		label = 'Mining Co.',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Apprentice Miner', payment = 25 },    -- 学徒矿工
			['1'] = { name = 'Miner', payment = 45 },               -- 正式矿工
			['2'] = { name = 'Senior Miner', payment = 70 },        -- 资深矿工/小组长
			['3'] = { name = 'Mine Foreman', payment = 110 },       -- 矿场领班/副部长
			['4'] = { name = 'Mine Owner', isboss = true, payment = 180 }, -- 矿场主/Boss
		},
	},

	-- === 热狗摊 / Hotdog ===
	hotdog = {
		label = 'Hotdog',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Trainee', payment = 20 },           -- 实习摊贩
			['1'] = { name = 'Vendor', payment = 40 },            -- 正式摊贩
			['2'] = { name = 'Shift Lead', payment = 60 },        -- 当班组长
			['3'] = { name = 'Area Manager', payment = 90 },      -- 区域经理
			['4'] = { name = 'Franchise Owner', isboss = true, payment = 140 }, -- 加盟店主/Boss
		},
	},
}
