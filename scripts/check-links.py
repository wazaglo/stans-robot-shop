#!/usr/bin/env python3
"""Check that every relative link in the markdown resolves."""
import glob
import os
import re
import sys

bad = 0
for md in glob.glob('**/*.md', recursive=True):
    if '.git/' in md:
        continue
    base = os.path.dirname(md)
    for link in re.findall(r'\[[^\]]*\]\(([^)#]+)\)', open(md).read()):
        if link.startswith(('http', 'mailto:')):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(base, link))):
            print(f'  broken {md} -> {link}')
            bad += 1
if bad:
    print(f'  {bad} broken link(s)', file=sys.stderr)
    sys.exit(1)
print('  no broken links')
