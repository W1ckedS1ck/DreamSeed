#!/usr/bin/env python3
import re
import sys


def main():
    comment = sys.argv[1] if len(sys.argv) > 1 else ""
    output = sys.argv[2] if len(sys.argv) > 2 else ""
    comment = comment.strip()

    keys = {}

    # help
    if re.search(r'^/deploy\s+help', comment):
        keys['command'] = 'help'

    # status
    elif re.search(r'^/deploy\s+status', comment):
        keys['command'] = 'status'

    # destroy
    elif m := re.search(r'^/destroy\s+(prod|prod-hetz|dev-aws|dev-hetz)', comment):
        keys['command'] = 'destroy'
        keys['target'] = m.group(1)
        keys['action'] = 'destroy'

    # deploy
    elif m := re.search(r'^/deploy\s+(prod|prod-hetz|dev-aws|dev-hetz)', comment):
        keys['command'] = 'deploy'
        keys['target'] = m.group(1)
        keys['action'] = 'deploy'
        keys['web_server'] = 'apache' if re.search(r'\s-a\b', comment) else 'nginx'
        keys['mode'] = 'parallel' if re.search(r'\s-p\b', comment) else 'sequential'
        if ip := re.search(r'\s-i\s+(\d+\.\d+\.\d+\.\d+)', comment):
            keys['ip'] = ip.group(1)

    else:
        keys['command'] = 'invalid'

    if output:
        with open(output, 'a') as f:
            f.writelines(f'{k}={v}\n' for k, v in keys.items())
    else:
        for k, v in keys.items():
            print(f'{k}={v}')


if __name__ == '__main__':
    main()
