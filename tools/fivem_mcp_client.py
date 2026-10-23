#!/usr/bin/env python3
"""MCP client over the FXServer polling bridge (no inbound host ports)."""
import argparse, json, os, time, urllib.request, urllib.parse

BASE = os.environ.get('FIVEM_BRIDGE_URL', 'http://127.0.0.1:30120/host-setup/fivem-mcp')
TOKEN = os.environ.get('FIVEM_BRIDGE_TOKEN') or open('/tmp/fivem_bridge_token').read().strip()

def http_json(path, **params):
    params['token'] = TOKEN
    url = BASE + path + '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.loads(r.read().decode())

class MCP:
    def __init__(self):
        self.id = 0

    def notify(self, method, params=None):
        msg = {'jsonrpc': '2.0', 'method': method}
        if params is not None: msg['params'] = params
        line = json.dumps(msg)
        http_json('/request', id=f'n{time.time_ns()}', line=line)

    def request(self, method, params=None, timeout=60):
        self.id += 1
        msg = {'jsonrpc': '2.0', 'id': self.id, 'method': method}
        if params is not None: msg['params'] = params
        line = json.dumps(msg)
        http_json('/request', id=self.id, line=line)
        deadline = time.time() + timeout
        while time.time() < deadline:
            data = http_json('/response', id=self.id)
            if isinstance(data, dict) and data.get('line'):
                return json.loads(data['line'])
            time.sleep(0.05)
        raise TimeoutError(f'MCP request {method} id={self.id} timed out')

    def initialize(self):
        r = self.request('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'tcity-agent', 'version': '1.0'},
        })
        self.notify('notifications/initialized', {})
        return r

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--list', action='store_true')
    p.add_argument('--tool')
    p.add_argument('--args', default='{}')
    a = p.parse_args()
    m = MCP()
    print(json.dumps(m.initialize(), ensure_ascii=False))
    if a.list:
        print(json.dumps(m.request('tools/list'), ensure_ascii=False))
        return
    if a.tool:
        print(json.dumps(m.request('tools/call', {
            'name': a.tool, 'arguments': json.loads(a.args)
        }), ensure_ascii=False))

if __name__ == '__main__':
    main()
