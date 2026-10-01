#!/usr/bin/env python3
"""
Assert the chart's default render matches what the documentation claims.

The defaults are a contract. README.md and docs/probes.md both state
specific numbers, and a change that silently alters one of them makes
the docs wrong. This fails instead.

Usage: helm template robot-shop EKS/helm -n robot-shop | ./scripts/assert-defaults.py
"""
import sys
import yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

kinds = {}
for d in docs:
    kinds[d['kind']] = kinds.get(d['kind'], 0) + 1
print('  kinds:', kinds)

def check(cond, msg):
    if not cond:
        print(f'  FAIL {msg}', file=sys.stderr)
        sys.exit(1)

check(kinds.get('Deployment') == 11, f"expected 11 Deployments, got {kinds.get('Deployment')}")
check(kinds.get('StatefulSet') == 1, f"expected 1 StatefulSet, got {kinds.get('StatefulSet')}")
check(kinds.get('Service') == 12, f"expected 12 Services, got {kinds.get('Service')}")
# PodSecurityPolicy was removed in Kubernetes 1.25; these templates were deleted
check('PodSecurityPolicy' not in kinds, 'PodSecurityPolicy must not be rendered')

ready, live = [], []
for d in docs:
    if d['kind'] == 'Service':
        continue
    c = d['spec']['template']['spec']['containers'][0]
    if c.get('readinessProbe'):
        ready.append(d['metadata']['name'])
    if c.get('livenessProbe'):
        live.append(d['metadata']['name'])

expected_ready = ['cart', 'catalogue', 'mongodb', 'mysql', 'ratings', 'shipping', 'user']
check(sorted(ready) == expected_ready, f'readiness probes {sorted(ready)} != {expected_ready}')
check(not live, f'liveness must be off by default, found {live}')

web = [d['spec']['type'] for d in docs
       if d['kind'] == 'Service' and d['metadata']['name'] == 'web']
check(web == ['ClusterIP'], f'web Service should be ClusterIP, is {web}')

print('  readiness:', sorted(ready))
print('  liveness: none, as documented')
print('  web Service: ClusterIP')
print('  defaults match the documentation')
