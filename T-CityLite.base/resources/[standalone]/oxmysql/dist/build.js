// dist/build.js — oxmysql JS backend for T-City Lite
// Handles FXServer JS bridge quirks: nil-dropping, scalar vs array args

process.on('uncaughtException', function(err) {
    if (err && err.message && err.message.includes('cb is not a function')) return;
    console.error('[oxmysql] Uncaught:', err ? err.message : err);
});

var mysql = require('mysql2');

var config = null;
function getConfig() {
    if (!config) {
        var cs = GetConvar('mysql_connection_string', '');
        if (!cs) {
            console.error('[oxmysql] No mysql_connection_string set');
            return null;
        }
        try {
            var url = new URL(cs);
            config = {
                host: url.hostname || '127.0.0.1',
                port: parseInt(url.port) || 3306,
                user: decodeURIComponent(url.username),
                password: decodeURIComponent(url.password),
                database: url.pathname.replace(/^\//, ''),
                charset: (new URLSearchParams(url.search)).get('charset') || 'utf8mb4',
            };
        } catch (e) {
            console.error('[oxmysql] Bad connection string:', e.message);
            return null;
        }
    }
    return config;
}

var pool = null;
function getPool() {
    if (!pool) {
        var cfg = getConfig();
        if (!cfg) return null;
        try {
            pool = mysql.createPool({
                host: cfg.host,
                port: cfg.port,
                user: cfg.user,
                password: cfg.password,
                database: cfg.database,
                charset: cfg.charset,
                connectTimeout: 10000,
                connectionLimit: 10,
                supportBigNumbers: true,
                bigNumberStrings: false,
            });
            pool.on('error', function() {});
        } catch (e) {
            console.error('[oxmysql] Pool creation failed:', e.message);
            return null;
        }
    }
    return pool;
}

function handle(method, query, parameters, cb, returnErrors) {
    var p = getPool();
    if (!p) return cb('No database config', null);

    var sql;
    if (typeof query === 'number') {
        return cb('Query store not supported', null);
    }
    if (!query || (typeof query === 'string' && query.trim() === '')) {
        return cb([], null);
    }
    sql = String(query || '');
    var params = parameters || [];

    // 🔧 Fix: Convert named params (:param) to positional (?) for mysql2
    // Lua code sends {:citizenid, :cid, ...} but mysql2 only supports ?
    function convertNamedParams(sql, params) {
        if (!params || typeof params !== 'object' || Array.isArray(params)) {
            return { sql: sql, params: params };
        }
        var result = '';
        var newParams = [];
        var i = 0;
        var len = sql.length;
        while (i < len) {
            if (sql[i] === ':' && i + 1 < len && /[a-zA-Z_]/.test(sql[i+1])) {
                var start = i + 1;
                var name = '';
                while (start < len && /[a-zA-Z0-9_]/.test(sql[start])) {
                    name += sql[start];
                    start++;
                }
                if (name && params.hasOwnProperty(name)) {
                    result += '?';
                    newParams.push(params[name]);
                    i = start;
                    continue;
                }
            }
            result += sql[i];
            i++;
        }
        return { sql: result, params: newParams };
    }
    var converted = convertNamedParams(sql, params);
    sql = converted.sql;
    params = converted.params;

    function safeCb(err, result) {
        if (typeof cb !== 'function') return;
        if (err) {
            var msg = typeof err === 'string' ? err : (err.message || err.code || '');
            cb(returnErrors ? msg : null, returnErrors ? null : msg);
        } else {
            cb(result, null);
        }
    }

    // mysql2 v3 fix: re-stringify any object values (JSON auto-parsed despite typeCast)
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

    try {
        switch (method) {
            case 'scalar':
                p.query(sql, params, function(err, rows) {
                    if (err) return safeCb(err);
                    safeCb(null, flattenJSON((rows && rows.length > 0) ? Object.values(rows[0])[0] : null));
                });
                break;
            case 'single':
                p.query(sql, params, function(err, rows) {
                    if (err) return safeCb(err);
                    safeCb(null, flattenJSON((rows && rows.length > 0) ? rows[0] : null));
                });
                break;
            case 'query':
                p.query(sql, params, function(err, rows) {
                    if (err) return safeCb(err);
                    safeCb(null, flattenJSON(rows));
                });
                break;
            case 'insert':
                p.query(sql, params, function(err, result) {
                    if (err) return safeCb(err);
                    safeCb(null, { insertId: result.insertId, affectedRows: result.affectedRows });
                });
                break;
            case 'update':
            case 'rawExecute':
                p.query(sql, params, function(err, result) {
                    if (err) return safeCb(err);
                    safeCb(null, { affectedRows: result.affectedRows });
                });
                break;
            case 'prepare':
                p.query(sql, params, function(err, rows) {
                    if (err) return safeCb(err);
                    if (!rows || rows.length === 0) return safeCb(null, null);
                    var row = rows[0];
                    if (!row) return safeCb(null, null);
                    var keys = Object.keys(row);
                    safeCb(null, flattenJSON(keys.length === 1 ? row[keys[0]] : row));
                });
                break;
            default:
                safeCb('Unknown method: ' + method);
        }
    } catch (e) {
        safeCb(e);
    }
}

function makeExport(method) {
    return function() {
        var args = arguments;
        var firstArg = args[0];
        var _, q, p, cb, rn, re;

        if (Array.isArray(firstArg) && firstArg.length >= 1) {
            _ = firstArg[0];
            q = firstArg.length > 1 ? firstArg[1] : undefined;
            p = firstArg.length > 2 ? firstArg[2] : undefined;
            cb = firstArg.length > 3 ? firstArg[3] : undefined;
            rn = firstArg.length > 4 ? firstArg[4] : undefined;
            re = firstArg.length > 5 ? firstArg[5] : undefined;

            if (Array.isArray(_)) {
                var inner = _;
                _ = inner[0]; q = inner[1]; p = inner[2];
                cb = inner[3]; rn = inner[4]; re = inner[5];
            }
        } else {
            _ = null;
            if (args.length >= 1 && args[0] !== null && args[0] !== undefined && typeof args[0] !== 'object') {
                q = args[0];
                p = args.length > 1 ? args[1] : undefined;
                cb = args.length > 2 ? args[2] : undefined;
                rn = args.length > 3 ? args[3] : undefined;
                re = args.length > 4 ? args[4] : undefined;
            } else {
                _ = args[0];
                q = args[1];
                p = args[2];
                cb = args[3];
                rn = args[4];
                re = args[5];
            }
        }

        if (typeof cb !== 'function') {
            if (typeof p === 'function') { cb = p; p = null; }
            else if (typeof q === 'function') { cb = q; q = null; }
            else if (typeof _ === 'function') { cb = _; _ = null; }
            else {
                // Fire-and-forget: no callback, but still execute the query
                if (q) handle(method, q, p, function(){}, re);
                return;
            }
        }
        handle(method, q, p, cb, re);
    };
}

exports('scalar',       makeExport('scalar'));
exports('single',       makeExport('single'));
exports('query',        makeExport('query'));
exports('insert',       makeExport('insert'));
exports('update',       makeExport('update'));
exports('prepare',      makeExport('prepare'));
exports('rawExecute',   makeExport('rawExecute'));
exports('fetchAll',     makeExport('query'));
exports('fetchScalar',  makeExport('scalar'));
exports('fetchSingle',  makeExport('single'));
exports('fetch',        makeExport('query'));
exports('execute',      makeExport('update'));

exports('awaitConnection', function() {
    var args = arguments;
    var firstArg = args[0];
    var _, q, p, cb;

    if (Array.isArray(firstArg) && firstArg.length >= 1) {
        _ = firstArg[0]; q = firstArg[1]; p = firstArg[2]; cb = firstArg[3];
    } else {
        if (args.length >= 1 && typeof args[0] === 'function') {
            cb = args[0];
        } else if (args.length >= 1 && args[0] !== null && args[0] !== undefined && typeof args[0] !== 'object') {
            q = args[0];
            cb = args.length > 1 ? args[1] : undefined;
        } else {
            _ = args[0]; q = args[1]; p = args[2]; cb = args[3];
        }
    }

    if (typeof cb !== 'function') {
        if (typeof p === 'function') cb = p;
        else if (typeof q === 'function') cb = q;
        else if (typeof _ === 'function') cb = _;
        else {
            var cfg = getConfig();
            if (!cfg) return;
            var conn = require('mysql2').createConnection({
                host: cfg.host, port: cfg.port, user: cfg.user,
                password: cfg.password, database: cfg.database, charset: cfg.charset,
            });
            conn.on('error', function(){});
            conn.connect(function(err) {
                if (err) console.error('[oxmysql] awaitConnection failed:', err.message);
                conn.destroy();
                getPool();
            });
            return;
        }
    }
    var pool = getPool();
    if (!pool) return cb(false, 'No database pool');
    pool.query('SELECT 1', function(err) {
        if (err) return cb(false, err.message);
        cb(true, null);
    });
});

getPool();
console.log('[oxmysql] Ready');
