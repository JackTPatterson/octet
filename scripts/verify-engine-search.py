#!/usr/bin/env python3
"""Probe a disposable engine session; creates and closes only its own workspace.

Start the bundled engine with --session octet-corpus-test server, then run:
python3 scripts/verify-engine-search.py /path/to/sessions/octet-corpus-test/herdr.sock
"""
import json
import pathlib
import shlex
import socket
import sys
import time
import uuid

path = pathlib.Path(sys.argv[1])
if path.parent.name != 'octet-corpus-test' or path.name != 'herdr.sock':
    raise SystemExit('This probe only accepts the disposable octet-corpus-test session socket.')


def call(method, params=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        connection.sendall((json.dumps({'id': 'search-probe', 'method': method, 'params': params or {}}) + '\n').encode())
        response = json.loads(connection.makefile().readline())
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response['result']


created = call('workspace.create', {'cwd': '/tmp', 'label': 'Search regression', 'focus': True})
workspace = created['workspace']['workspace_id']
pane = created['root_pane']['pane_id']
try:
    prefix = 'octet_probe_' + uuid.uuid4().hex[:8] + '_'
    program = "[print('%s%%06d 日本語' %% i) for i in range(4000)]" % prefix
    call('pane.send_text', {'pane_id': pane, 'text': 'python3 -c ' + shlex.quote(program) + '\r'})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        recent = call('pane.read', {'pane_id': pane, 'source': 'recent', 'lines': 4294967295})['read']
        if prefix + '003999' in recent['text']:
            break
        time.sleep(.1)
    else:
        raise AssertionError('Fixture did not finish')
    assert recent['truncated'] and prefix + '000100' not in recent['text']
    for suffix in ['000100', '003999']:
        query = prefix + suffix
        revision = call('pane.copy_motion', {'pane_id': pane, 'cursor': {'row': 0, 'col': 0}, 'motion': 'line_end'})['content_revision']
        result = call('pane.copy_search', {'pane_id': pane, 'query': query, 'direction': 'forward',
                      'cursor': {'row': 0, 'col': 0}, 'content_revision': revision})
        assert result['total'] == 1
        row = result['matches'][result['current']]['start']['row']
        scroll = call('pane.get', {'pane_id': pane})['pane']['scroll']
        offset = max(0, scroll['max_offset_from_bottom'] - max(0, row - scroll['viewport_rows'] // 2))
        call('pane.scroll', {'pane_id': pane, 'offset_from_bottom': offset})
        visible = call('pane.read', {'pane_id': pane, 'source': 'visible'})['read']['text']
        assert query in visible, 'Search match not visible after scrolling'
    missing = call('pane.copy_search', {'pane_id': pane, 'query': prefix + 'missing', 'direction': 'forward',
                   'cursor': {'row': 0, 'col': 0}, 'content_revision': revision})
    assert missing['total'] == 0
    print('PASS: capped snapshot reproduced; full-buffer old/new Unicode matches scroll into view; no-match case')
finally:
    call('workspace.close', {'workspace_id': workspace})
