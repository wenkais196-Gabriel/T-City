/**
 * test_flatten_json.cjs — flattenJSON 契约测试（真实 mysql2 连接）
 *
 * 验证 build.js 的 flattenJSON 函数对 mysql2 v3 真实输出的处理:
 *   1. JSON 列: mysql2 v3 自动解析为 object → flattenJSON 应转回 string
 *   2. INT 列: mysql2 正常返回 number → flattenJSON 应原样保留
 *   3. VARCHAR 列: string → 原样保留
 *   4. NULL 列: null → 原样保留
 *   5. 嵌套 JSON 内的 object: 递归转换
 *
 * 运行: node tests/unit/layer0_js/test_flatten_json.cjs
 * 需要: mysql2 已安装, MySQL 可连接
 */

const mysql = require('mysql2');
const assert = require('assert');

// ── 复制 build.js 的 flattenJSON ──────────────────────────────────────
function flattenJSON(result) {
    if (!result) return result;
    if (Array.isArray(result)) {
        for (var i = 0; i < result.length; i++) {
            var row = result[i];
            if (row && typeof row === 'object') {
                var keys = Object.keys(row);
                for (var j = 0; j < keys.length; j++) {
                    if (row[keys[j]] !== null && typeof row[keys[j]] === 'object') {
                        try { row[keys[j]] = JSON.stringify(row[keys[j]]); } catch(e) {}
                    }
                }
            }
        }
    } else if (typeof result === 'object') {
        var keys = Object.keys(result);
        for (var j = 0; j < keys.length; j++) {
            if (result[keys[j]] !== null && typeof result[keys[j]] === 'object') {
                try { result[keys[j]] = JSON.stringify(result[keys[j]]); } catch(e) {}
            }
        }
    }
    return result;
}

// ── 读取连接配置 ──────────────────────────────────────────────────────
function getConfig() {
    var cs = process.env.MYSQL_URL || 'mysql://swk:1543368168@localhost/TCityLite?charset=utf8mb4';
    var url = new URL(cs);
    return {
        host: url.hostname,
        port: parseInt(url.port) || 3306,
        user: decodeURIComponent(url.username),
        password: decodeURIComponent(url.password),
        database: url.pathname.replace(/^\//, ''),
        charset: (new URLSearchParams(url.search)).get('charset') || 'utf8mb4',
        connectTimeout: 10000,
        connectionLimit: 1,
        supportBigNumbers: true,
        bigNumberStrings: true,
    };
}

// ── 测试 ──────────────────────────────────────────────────────────────

let passed = 0, failed = 0;
function test(name, fn) { try { fn(); passed++; } catch(e) { failed++; console.log('  FAIL ' + name + ': ' + e.message); } }

async function run() {
    var cfg = getConfig();
    var pool = mysql.createPool(cfg);

    // 创建临时测试表
    await new Promise((resolve, reject) => {
        pool.query(`
            CREATE TEMPORARY TABLE IF NOT EXISTS _test_flatten (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(64),
                count INT,
                metadata JSON,
                nested JSON,
                amount DECIMAL(10,2)
            )
        `, (err) => err ? reject(err) : resolve());
    });

    await new Promise((resolve, reject) => {
        pool.query(`INSERT INTO _test_flatten (name, count, metadata, nested, amount) VALUES
            ('test_item', 42, '{"key":"value","num":99}', '{"outer":{"inner":"deep"}}', 99.99),
            ('empty_json', 0, '{}', NULL, 0.00)
        `, (err) => err ? reject(err) : resolve());
    });

    console.log('=== flattenJSON 契约测试 (真实 mysql2 v3) ===\n');

    // ── 测试 1: JSON 列被 mysql2 解析为 object → flattenJSON 转回 string ─
    await new Promise((resolve, reject) => {
        pool.query('SELECT metadata FROM _test_flatten WHERE name = ?', ['test_item'], function(err, rows) {
            if (err) return reject(err);

            var rawType = typeof rows[0].metadata;
            console.log('  mysql2 返回 metadata 类型: ' + rawType);

            test('JSON 列被 mysql2 解析为 object', () => {
                assert.strictEqual(rawType, 'object', 'mysql2 v3 should auto-parse JSON to object');
            });

            var processed = flattenJSON(rows);
            var processedType = typeof processed[0].metadata;
            console.log('  flattenJSON 后 metadata 类型: ' + processedType);

            test('flattenJSON 将 JSON object 转回 string', () => {
                assert.strictEqual(processedType, 'string', 'flattenJSON should stringify JSON objects');
            });

            test('转回的 string 可再次 JSON.parse', () => {
                var parsed = JSON.parse(processed[0].metadata);
                assert.strictEqual(parsed.key, 'value');
                assert.strictEqual(parsed.num, 99);
            });

            resolve();
        });
    });

    // ── 测试 2: 多列查询 — JSON 转 string, INT 保持 number ─
    await new Promise((resolve, reject) => {
        pool.query('SELECT id, name, count, metadata, amount FROM _test_flatten WHERE name = ?', ['test_item'], function(err, rows) {
            if (err) return reject(err);

            var processed = flattenJSON(rows);
            var row = processed[0];

            test('id (INT) 保持 number', () => {
                assert.strictEqual(typeof row.id, 'number');
            });

            test('name (VARCHAR) 保持 string', () => {
                assert.strictEqual(typeof row.name, 'string');
                assert.strictEqual(row.name, 'test_item');
            });

            test('count (INT) 保持 number', () => {
                assert.strictEqual(typeof row.count, 'number');
                assert.strictEqual(row.count, 42);
            });

            test('metadata (JSON) 转为 string', () => {
                assert.strictEqual(typeof row.metadata, 'string');
            });

            test('amount (DECIMAL) 保持 string (bigNumberStrings)', () => {
                // DECIMAL with bigNumberStrings:true → string
                assert.strictEqual(typeof row.amount, 'string');
                assert.strictEqual(row.amount, '99.99');
            });

            resolve();
        });
    });

    // ── 测试 3: 嵌套 JSON 列 → 递归 stringify ─
    await new Promise((resolve, reject) => {
        pool.query('SELECT nested FROM _test_flatten WHERE name = ?', ['test_item'], function(err, rows) {
            if (err) return reject(err);

            var processed = flattenJSON(rows);

            test('嵌套 JSON 列也被 stringify', () => {
                assert.strictEqual(typeof processed[0].nested, 'string');
            });

            test('嵌套 JSON 可完整还原', () => {
                var parsed = JSON.parse(processed[0].nested);
                assert.strictEqual(parsed.outer.inner, 'deep');
            });

            resolve();
        });
    });

    // ── 测试 4: NULL 值保持 null ─
    await new Promise((resolve, reject) => {
        pool.query('SELECT nested FROM _test_flatten WHERE name = ?', ['empty_json'], function(err, rows) {
            if (err) return reject(err);

            var processed = flattenJSON(rows);

            test('NULL 值保持 null', () => {
                assert.strictEqual(processed[0].nested, null);
            });

            resolve();
        });
    });

    // ── 测试 5: 空数组/空结果 ─
    test('空数组原样返回', () => {
        var result = flattenJSON([]);
        assert.deepStrictEqual(result, []);
    });

    test('null 原样返回', () => {
        assert.strictEqual(flattenJSON(null), null);
    });

    test('undefined 原样返回', () => {
        assert.strictEqual(flattenJSON(undefined), undefined);
    });

    // ── 测试 6: 纯文本行不受影响 ─
    await new Promise((resolve, reject) => {
        pool.query('SELECT id, name FROM _test_flatten WHERE count = 0', function(err, rows) {
            if (err) return reject(err);

            var processed = flattenJSON(rows);

            test('纯 INT+VARCHAR 行: id 保持 number', () => {
                assert.strictEqual(typeof processed[0].id, 'number');
            });

            test('纯 INT+VARCHAR 行: name 保持 string', () => {
                assert.strictEqual(typeof processed[0].name, 'string');
                assert.strictEqual(processed[0].name, 'empty_json');
            });

            resolve();
        });
    });

    // ── 测试 7: COUNT(*) 等聚合函数返回类型 ─
    // 这个测试验证 multicharacter 的 currentCount 场景
    await new Promise((resolve, reject) => {
        pool.query('SELECT COUNT(*) as cnt FROM _test_flatten', function(err, rows) {
            if (err) return reject(err);

            var processed = flattenJSON(rows);
            console.log('  COUNT(*) 返回类型: ' + typeof processed[0].cnt);

            test('COUNT(*) 返回 number（不是 string）', () => {
                assert.strictEqual(typeof processed[0].cnt, 'number',
                    'COUNT should be number so Lua comparison works');
                assert.strictEqual(processed[0].cnt, 2);
            });

            resolve();
        });
    });

    // ── 清理 ─
    await new Promise((resolve) => pool.end(resolve));

    console.log('\n========================================');
    console.log('flattenJSON 契约测试结果');
    console.log('========================================');
    console.log('Passed: ' + passed + '/' + (passed + failed));
    if (failed > 0) {
        console.log('Failed: ' + failed);
    } else {
        console.log('All tests passed!');
    }
    console.log('========================================');
}

run().catch(e => {
    console.error('Test setup failed:', e.message);
    process.exit(1);
});
