#!/usr/bin/env python3
"""Print Infracost breakdown summary."""
import json
import sys

with open('/tmp/base.json') as f:
    data = json.load(f)

total = data.get('totalMonthlyCost', 'N/A')
print('--- Monthly Cost Breakdown ---')
for p in data.get('projects', []):
    name = p.get('name', '?').split('/')[-1]
    cost = p.get('breakdown', {}).get('totalMonthlyCost', 'N/A')
    print(f'  {name}: ${cost}/mo')
print(f'  Total: ${total}/mo')
print('-----------------------------')
