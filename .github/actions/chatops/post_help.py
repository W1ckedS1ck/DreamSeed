#!/usr/bin/env python3
import subprocess
import sys


def main():
    issue = sys.argv[1]
    repo = sys.argv[2]

    body = """## Deploy Commands

```
/deploy prod -n            Production (AWS, Nginx)
/deploy prod-hetz -a       Production (Hetzner, Apache)
/deploy dev-aws -n         Dev (AWS)
/deploy dev-hetz -n -p     Dev (Hetzner, parallel)
/deploy <target> -i 1.2.3.4   Reconfigure existing IP
/destroy <target>          Destroy environment
/deploy status             Recent deploys
/deploy help               This message
```

Flags: -n Nginx, -a Apache, -p parallel, -i <ip> skip Terraform
Authorized: users with write/admin access"""

    subprocess.run([
        'gh', 'issue', 'comment', issue,
        '--repo', repo,
        '--body', body,
    ], check=True)


if __name__ == '__main__':
    main()
