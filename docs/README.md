# Documentation

Start with the [README](../README.md) for the architecture and a deploy
walkthrough. Everything else is reference material for when something does not
work, or you need to know why something is the way it is.

## Deployment, in order

| Document | Covers |
|---|---|
| [EKS/01-prerequisites.md](../EKS/01-prerequisites.md) | the four CLIs, AWS auth, kubeconfig, Lens |
| [EKS/02-eks-cluster-setup.md](../EKS/02-eks-cluster-setup.md) | cluster and node group, the two settings that matter, verifying `maxPods` |
| [EKS/03-oidc-IAM.md](../EKS/03-oidc-IAM.md) | OIDC provider, IRSA roles, why the `sub` condition is not optional |
| [EKS/04-alb-configuration.md](../EKS/04-alb-configuration.md) | ALB controller, and why there is only one load balancer |
| [EKS/05-ebs-csi-driver.md](../EKS/05-ebs-csi-driver.md) | EBS CSI driver, the `gp2` StorageClass trap |

## Reference

| Document | Covers |
|---|---|
| [EKS/helm/README.md](../EKS/helm/README.md) | every chart value, image naming, and the `ClusterIP` decision |
| [probes.md](probes.md) | the verified health-endpoint matrix, and why liveness is off by default |
| [building.md](building.md) | building the images, and why `ratings` cannot be built |
| [screenshots/README.md](screenshots/README.md) | historical cluster captures, and a guide for adding GUI screenshots |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | what CI enforces and why, conventions, commit style |

## When something is broken

[troubleshooting.md](troubleshooting.md). Nine issues, each with the real error
text, in the order they are likely to bite:

1. **Node group rolls back, cluster is ACTIVE with no nodes** — the instance
   type is not free-tier eligible
2. **Add-ons stuck `DEGRADED` with "Too many pods"** — prefix delegation is off,
   so every node advertises `maxPods=4`
3. **Pods `Pending` with "Insufficient memory"** — a request larger than any
   node's allocatable memory, which no amount of scaling can fix
4. **shipping `OOMKilled`** — the JVM's `-Xmx` exceeds the container limit
5. **`CrashLoopBackOff` with "not found"** — a shell-form `CMD` in a Dockerfile
6. **PVC `Pending` with "no topology key"** — transient, wait for the node label
7. **nginx "host not found in upstream"** — fixed in the `web` image; see below
8. **The whole cluster `NotReady` under load** — memory pressure, and the ASG
   reports "Healthy" while kubelets are dead
9. **An IRSA role is more permissive than intended** — the trust policy is
   missing its `sub` condition

## What has been fixed here, and what has not

The documentation records both, because knowing which is which saves time.

**Fixed:** issue 5 (`dispatch` `CMD`), issue 7 (nginx resolving upstreams at
request time), the PSP templates, the duplicate load balancer, the IRSA `sub`
conditions, the MySQL root password, and the reproducible Go build.

**Not fixed, by decision:** the `ratings` build. Bumping `php:7.4-apache` means
running PHP 8 against code only ever tested on 7.4, which needs the
application run to confirm. See [building.md](building.md).

**Not fixed, by choice:** liveness probes are not enabled, because on this
hardware they would make things worse. See [probes.md](probes.md).

**Still a real limitation:** twelve microservices do not fit on four
`t3.micro` nodes. `README.md` has the arithmetic, and issue 8 in
`troubleshooting.md` has what happened when it was ignored.

## A note on the screenshots

The captures in [screenshots/](screenshots/) are **historical**. The cluster
they came from has been deleted along with its ECR repositories, so the pod
names, node names and timestamps in them no longer correspond to anything
running. They are kept as evidence for the numbers quoted in the README, not
as documentation of a current system. Take fresh ones after rebuilding.
