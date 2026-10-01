#!/usr/bin/env python3
"""
Render live cluster state to PNG so the docs show what actually happened,
not hand-written mockups.

    ./docs/capture.py            # regenerate every capture
    ./docs/capture.py --only nodes

Each capture is a terminal screenshot: title bar, the real command, and its
real output. Output is coloured by status (green Running/Ready/Bound,
red failures) so a broken state is obvious at a glance.
"""

import argparse
import os
import re
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshots")
REGION = "us-east-1"
CLUSTER = "wisdom-eks"
NODEGROUP = "ng-micro-17"

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

BG = (24, 26, 32)
BAR = (44, 47, 56)
TITLE = (150, 155, 168)
FG = (208, 213, 223)
GREEN = (126, 200, 128)
RED = (232, 122, 122)
YELLOW = (226, 192, 106)
CYAN = (128, 190, 210)
DIM = (128, 133, 145)

# (filename, window title, shell command)
CAPTURES = [
    ("01-nodes.png", "kubectl get nodes -o wide",
     f"kubectl get nodes -o wide"),
    ("02-node-capacity.png", "per-node allocatable memory (the 512Mi ceiling)",
     "kubectl get nodes -o jsonpath='{range .items[*]}"
     "{.metadata.name}{\"  allocMem=\"}{.status.allocatable.memory}"
     "{\"  maxPods=\"}{.status.capacity.pods}{\"\\n\"}{end}'"),
    ("03-pods.png", "kubectl get pods -n robot-shop",
     "kubectl get pods -n robot-shop"),
    ("04-deployments.png", "kubectl get deploy,sts -n robot-shop",
     "kubectl get deploy,sts -n robot-shop"),
    ("05-ingress.png", "kubectl get ingress -n robot-shop (public ALB address)",
     "kubectl get ingress -n robot-shop"),
    ("06-services.png", "kubectl get svc -n robot-shop",
     "kubectl get svc -n robot-shop"),
    ("07-pvc.png", "kubectl get pvc -n robot-shop (EBS volume bound via CSI)",
     "kubectl get pvc -n robot-shop"),
    ("08-helm.png", "helm list -A",
     "helm list -A"),
    ("09-storageclass.png", "kubectl get storageclass (in-tree gp2 vs ebs.csi.aws.com)",
     "kubectl get storageclass"),
    ("10-addons.png", f"aws eks list-addons --cluster-name {CLUSTER}",
     f"aws eks list-addons --cluster-name {CLUSTER} --region {REGION}"),
    ("11-nodegroup.png", "node group: t3.micro, max 7",
     f"aws eks describe-nodegroup --cluster-name {CLUSTER} "
     f"--nodegroup-name {NODEGROUP} --region {REGION} "
     "--query 'nodegroup.{types:instanceTypes,scaling:scalingConfig}'"),
    ("12-ecr.png", "ECR repositories and tags",
     f"for r in cart catalogue dispatch mongodb mysql-db payment ratings "
     f"shipping user web; do printf '%-14s ' $r; aws ecr describe-images "
     f"--repository-name robot-shop/rs-$r --region {REGION} "
     "--query 'imageDetails[0].imageTags' --output json | tr -d '\\n '; echo; done"),
    ("13-loadbalancers.png", "ELBv2: exactly one internet-facing ALB",
     f"aws elbv2 describe-load-balancers --region {REGION} "
     "--query 'LoadBalancers[].{Name:LoadBalancerName,Scheme:Scheme,Type:Type,"
     "State:State.Code}' --output table"),
    ("14-irsa-trust.png", "IRSA trust policies are scoped by sub",
     "aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole "
     "--query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' "
     "--output json"),
    ("15-storefront.png", "storefront responds through the ALB",
     "curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\\n' "
     "--max-time 20 http://k8s-robotsho-robotsho-bbf1f25197-365575556."
     "us-east-1.elb.amazonaws.com/"),
]

STATUS_COLORS = [
    (r"\bRunning\b", GREEN),
    (r"\bReady\b", GREEN),
    (r"\bBound\b", GREEN),
    (r"\bActive\b", GREEN),
    (r"\bactive\b", GREEN),
    (r"\bdeployed\b", GREEN),
    (r"\bsucceeded\b", GREEN),
    (r"\bHTTP 2\d\d\b", GREEN),
    (r"\bNotReady\b", YELLOW),
    (r"\bPending\b", YELLOW),
    (r"\bCreating\b", YELLOW),
    (r"\bTerminating\b", DIM),
    (r"\bEvicted\b", RED),
    (r"\bCrashLoopBackOff\b", RED),
    (r"\bFailed\b", RED),
    (r"\bError\b", RED),
    (r"\bDEGRADED\b", RED),
    (r"\bNotFound\b", RED),
]


def run(cmd):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=90)
        out = (p.stdout + p.stderr).rstrip()
        return out or "(no output)"
    except subprocess.TimeoutExpired:
        return "(timed out)"
    except Exception as exc:  # noqa: BLE001
        return f"(failed: {exc})"


def color_for(line):
    for pattern, color in STATUS_COLORS:
        if re.search(pattern, line):
            return color
    return FG


def render(fname, title, cmd, output):
    size = 15
    font = ImageFont.truetype(FONT, size)
    font_bold = ImageFont.truetype(FONT_BOLD, size)
    font_title = ImageFont.truetype(FONT_BOLD, 14)
    font_cmd = ImageFont.truetype(FONT, 14)

    lines = output.splitlines()
    prompt = f"$ {cmd}"
    pad = 18
    bar_h = 34
    gap = 10
    prompt_h = size + gap * 2

    # wrap long command lines
    wrapped = []
    for pl in prompt.splitlines() or [""]:
        while len(pl) > 108:
            wrapped.append(pl[:108])
            pl = " " * 2 + pl[108:]
        wrapped.append(pl)

    line_h = size + 6
    body_h = prompt_h + len(wrapped) * (size + 4) + gap + len(lines) * line_h + pad
    width = 1180
    height = bar_h + body_h

    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)

    # title bar with traffic lights
    d.rectangle([0, 0, width, bar_h], fill=BAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([pad + i * 20, 11, pad + i * 20 + 12, 23], fill=c)
    d.text((width / 2, bar_h / 2), title, font=font_title, fill=TITLE, anchor="mm")

    y = bar_h + pad
    for wl in wrapped:
        d.text((pad, y), wl, font=font_cmd, fill=CYAN)
        y += size + 4
    y += gap

    for line in lines:
        d.text((pad, y), line, font=font, fill=color_for(line))
        y += line_h

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, fname)
    img.save(path, "PNG", optimize=True)
    return path, len(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="substring of the capture filename to regenerate")
    args = ap.parse_args()

    for fname, title, cmd in CAPTURES:
        if args.only and args.only not in fname:
            continue
        out = run(cmd)
        path, n = render(fname, title, cmd, out)
        print(f"{path}  ({n} lines)")


if __name__ == "__main__":
    sys.exit(main())
