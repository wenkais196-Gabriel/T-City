-- custom-testing 配置
-- 控制测试运行行为

Config = Config or {}

-- 测试报告输出路径（相对于服务器根目录）
Config.TestReportPath = "logs/test_reports"

-- 测试超时时间（秒），超时自动标记为 FAIL
Config.TestTimeout = 30

-- 是否在测试开始时自动清理测试产生的数据库记录
-- 开启后可重复测试，但需要数据库写入权限
-- 设置为 false 则只验证读操作
-- WARNING: true 会删除玩家的测试银行记录，仅在开发服使用
Config.CleanTestData = false

-- 测试管理员白名单（steam hex 或 license）
-- 留空则允许 /test 命令被所有人调用（开发阶段用）
-- 生产服应设置为具体的管理员标识
Config.AdminWhitelist = {}

-- 测试运行模式
-- "normal"  — 正常跑测试，输出 PASS/FAIL
-- "verbose" — 每个断言都打印详细信息
-- "dryrun"  — 只列出测试用例，不实际执行
Config.RunMode = "normal"

-- 是否在测试失败时立即中断当前套件
Config.FailFast = true

-- 单人模式：服务端自动模拟多角色
-- true  — 自动创建模拟玩家表，无需真人客户端在线
-- false — 需要真人玩家触发测试，更贴近真实环境
Config.SinglePlayerMode = true

-- 模拟玩家的默认数据
Config.MockPlayer = {
    citizenid = "TEST00001",
    license = "license:test_dev_00001",
    firstname = "测试",
    lastname = "员A",
    cash = 10000,
    bank = 5000,
    job = "unemployed",
    job_grade = 0,
}
