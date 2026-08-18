#!/usr/bin/env python3
import re
import sys


def main():
    comment = sys.argv[1] if len(sys.argv) > 1 else ""
    output = sys.argv[2] if len(sys.argv) > 2 else ""
    comment = comment.strip()

    keys = {}

    if re.search(r'^/deploy\s+help', comment):
        keys['command'] = 'help'

    elif re.search(r'^/deploy\s+status', comment):
        keys['command'] = 'status'

    elif m := re.search(r'^/destroy\s+(prod-hetz|dev-aws|dev-hetz|prod)(?=\s|$)', comment):
        keys['command'] = 'destroy'
        keys['target'] = m.group(1)
        keys['action'] = 'destroy'

    elif m := re.search(r'^/deploy\s+(prod-hetz|dev-aws|dev-hetz|prod)(?=\s|$)', comment):
        keys['command'] = 'deploy'
        keys['target'] = m.group(1)
        keys['action'] = 'deploy'
        keys['web_server'] = 'apache' if re.search(r'\s-a\b', comment) else 'nginx'
        keys['mode'] = 'parallel' if re.search(r'\s-p\b', comment) else 'sequential'
        if ip := re.search(r'\s-i\s+(\d+\.\d+\.\d+\.\d+)', comment):
            keys['ip'] = ip.group(1)

    elif comment.startswith('/'):
        # A slash command we don't recognize — reply with help, never deploy.
        keys['command'] = 'invalid'

    else:
        # Not a chatops command at all — ignore silently (no reaction, no failure).
        keys['command'] = 'none'

    if output:
        with open(output, 'a') as f:
            f.writelines(f'{k}={v}\n' for k, v in keys.items())
    else:
        for k, v in keys.items():
            print(f'{k}={v}')


if __name__ == '__main__':
    main()
