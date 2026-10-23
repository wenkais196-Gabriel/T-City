// Reverse HTTP-polling bridge: host runs this, VM queues MCP requests/responses.
// No inbound ports on the Windows host; only outbound HTTP to the VM's FXServer.
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TOKEN = '__TOKEN__';
const RCON = '__RCON__';
const BASE = 'http://172.20.101.94:30120/host-setup/fivem-mcp';

function bridgeUrl(endpoint, params = {}) {
    const u = new URL(BASE + endpoint);
    u.searchParams.set('token', TOKEN);
    for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
    return u.toString();
}
const LOG = path.join(os.tmpdir(), 'fivem-mcp-bridge.log');

function log(...args) {
    const line = `[${new Date().toISOString()}] ${args.join(' ')}`;
    console.log(line);
    try { fs.appendFileSync(LOG, line + '\n'); } catch (e) {}
}

const env = {
    ...process.env,
    FIVEM_HOST: '127.0.0.1',
    FIVEM_EXECUTABLE: path.join(process.env.LOCALAPPDATA || '', 'FiveM', 'FiveM.exe'),
    FIVEM_CLIENT_DEVCON_PORT: '29200',
    FIVEM_RCON_ADDRESS: '172.20.101.94:30120',
    FIVEM_RCON_PASSWORD: RCON,
    FIVEM_MCP_DEBUG: '1',
};

log('starting fivem-mcp-server');
const child = spawn('npx', ['-y', 'fivem-mcp-server'], {
    env,
    shell: true,
    windowsHide: true,
});

let stdoutBuf = '';

async function getJson(endpoint, params) {
    const res = await fetch(bridgeUrl(endpoint, params));
    if (!res.ok) log('GET', endpoint, res.status);
    return res;
}

function handleLine(line) {
    line = line.trim();
    if (!line) return;
    let msg;
    try {
        msg = JSON.parse(line);
    } catch (e) {
        log('non-json from mcp:', line.slice(0, 300));
        return;
    }
    if (msg.id !== undefined && msg.id !== null) {
        getJson('/response', { id: msg.id, line }).catch(e => log('response failed:', e.message));
        log('response id=', msg.id);
    } else {
        log('notification:', line.slice(0, 300));
    }
}

child.stdout.on('data', chunk => {
    stdoutBuf += chunk.toString('utf8');
    let idx;
    while ((idx = stdoutBuf.indexOf('\n')) >= 0) {
        const line = stdoutBuf.slice(0, idx);
        stdoutBuf = stdoutBuf.slice(idx + 1);
        handleLine(line);
    }
});

child.stderr.on('data', chunk => {
    const text = chunk.toString('utf8').trim();
    if (text) log('stderr:', text);
});

child.on('exit', code => {
    log('fivem-mcp-server exited', code);
    process.exit(code || 0);
});

child.on('error', err => {
    log('spawn failed:', err.message);
    process.exit(1);
});

let busy = false;
setInterval(async () => {
    if (busy || child.stdin.destroyed) return;
    busy = true;
    try {
        const res = await getJson('/poll');
        if (!res.ok) {
            log('poll HTTP', res.status);
            return;
        }
        const data = await res.json();
        for (const item of data.requests || []) {
            log('request id=', item.id);
            child.stdin.write(item.line + '\n');
        }
    } catch (e) {
        log('poll error:', e.message);
    } finally {
        busy = false;
    }
}, 100);

log('bridge running; keep this window open');
