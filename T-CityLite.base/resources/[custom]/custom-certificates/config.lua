Config = Config or {}

-- 证件类型定义：key = licences/cert_status 键名，item = 实体物品名，cost = 市政厅补办费用
Config.CertificateTypes = {
    driver = {
        label = 'Driver License',
        item = 'driver_license',
        cost = 150,
        vehicleClasses = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 18, 22 },
    },
    pilot = {
        label = 'Pilot License',
        item = 'pilot_license',
        cost = 150,
        vehicleClasses = { 15, 16 },
    },
    boat = {
        label = 'Boat License',
        item = 'boat_license',
        cost = 150,
        vehicleClasses = { 14 },
    },
    heavy = {
        label = 'Heavy Vehicle License',
        item = 'heavy_license',
        cost = 150,
        vehicleClasses = { 10, 11, 17, 19, 20 },
    },
    weapon = {
        label = 'Weapon License',
        item = 'weaponlicense',
        cost = 150,
        vehicleClasses = {}, -- 不涉及载具
    },
}

-- 序列号格式：cert-<type>-<citizenid>
function Config.GenerateSerial(citizenid, certType)
    return ('cert-%s-%s'):format(certType, citizenid)
end
