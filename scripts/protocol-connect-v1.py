#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import re
import sys

ENGINE_PATH = pathlib.Path('/usr/lib/milmit-surfshark/connection-engine-v3.py')


def load_engine():
    if not ENGINE_PATH.is_file():
        raise RuntimeError(f'connection engine is not installed at {ENGINE_PATH}')
    spec = importlib.util.spec_from_file_location('milmit_engine_v3', ENGINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError('could not load connection engine v3')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    if os.geteuid() != 0:
        print('protocol connector must run as root', file=sys.stderr)
        return 77
    if len(sys.argv) != 3:
        print('usage: protocol-connect-v1.py wireguard|openvpn SERVER_IDENTITY', file=sys.stderr)
        return 64
    protocol = sys.argv[1].strip().lower()
    identity = sys.argv[2].strip()
    if protocol not in ('wireguard', 'openvpn'):
        print('unsupported forced protocol', file=sys.stderr)
        return 64
    if not re.fullmatch(r'[A-Za-z0-9.-]+\.prod\.surfshark\.com', identity):
        print('invalid server identity', file=sys.stderr)
        return 64

    engine = load_engine()
    engine.EVENTS.write_text('')
    os.chmod(engine.EVENTS, 0o600)
    engine.atomic_json(engine.STATE, {
        'phase': 'PREPARING',
        'identity': identity,
        'protocol': protocol,
        'started_at': engine.now(),
        'forced_protocol': True,
    }, 0o644)
    engine.emit('PREPARING', f'Starting forced {protocol} connection', identity=identity, protocol=protocol)
    engine.cleanup_protocols()

    fn = engine.wireguard_try if protocol == 'wireguard' else engine.openvpn_try
    result, detail = fn(identity)
    if result is True:
        engine.emit('CONNECTED', f'Connected using forced {protocol}', protocol=protocol, identity=identity, detail=detail)
        print(json.dumps({'ok': True, 'protocol': protocol, 'identity': identity, 'detail': detail}))
        return 0
    if result is None:
        engine.emit('FAILED', f'{protocol} profile is not configured', protocol=protocol, identity=identity, detail=detail)
        print(json.dumps({'ok': False, 'error': detail}), file=sys.stderr)
        return 69

    engine.emit('FAILED', f'Forced {protocol} connection failed', protocol=protocol, identity=identity, detail=detail)
    print(json.dumps({'ok': False, 'error': detail}), file=sys.stderr)
    return 68


if __name__ == '__main__':
    raise SystemExit(main())
