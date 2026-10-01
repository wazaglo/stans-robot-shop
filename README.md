# Stan's Robot Shop on AWS EKS

A 12-service microservices storefront deployed to Amazon EKS, with every
container image built from the Dockerfiles in this repo and pushed to a private
Amazon ECR registry. Helm renders the whole application; an AWS Load Balancer
Controller puts a public ALB in front of it.

Upstream: [`iam-veeramalla/three-tier-architecture-demo`](https://github.com/iam-veeramalla/three-tier-architecture-demo),
itself a fork of [`instana/robot-shop`](https://github.com/instana/robot-shop).
Apache 2.0, see [`LICENSE`](LICENSE).

---

## What is in here

| Path | What it is |
|---|---|
| `cart/ catalogue/ dispatch/ mongo/ mysql/ payment/ ratings/ shipping/ user/ web/` | one service per directory, each with its own `Dockerfile` and build context |
| `EKS/helm/` | the Helm chart that deploys the app |
| `EKS/01`–`05-*.md` | the EKS setup steps, as they were actually performed |
| `eksctl/cluster.yaml` | control plane + node group, reproducible from scratch |
| `scripts/build-push.sh` | builds all 10 images and pushes them to ECR |
| `docs/troubleshooting.md` | the nine failures hit while building this, with real error output |

---

## Architecture

```
                      internet
                          │
              ┌───────────▼───────────┐
              │  ALB (internet-facing) │   aws-load-balancer-controller
              │  target-type: ip      │   provisions from EKS/helm/ingress.yaml
              └───────────┬───────────┘
                          │ :8080
              ┌───────────▼───────────┐
              │           web         │   nginx, static AngularJS frontend
              └───────────┬───────────┘
        ┌──────────┬───────┴────┬──────────┬───────────┐
   ┌────▼────┐┌────▼────┐┌──────▼─────┐┌───▼─────┐┌────▼────┐
   │catalogue││   user  ││   cart    ││ payment ││shipping │
   └────┬────┘└────┬────┘└──────┬─────┘└───┬─────┘└────┬────┘
        │          │             │          │           │
   ┌────▼────┐┌────▼────┐   ┌────▼────┐┌───▼──────┐    │
   │ mongodb ││  redis  │   │rabbitmq ││  mysql   │◄───┘
   └─────────┘└─────────┘   └─────────┘└──────────┘
        └──────────────── ratings ─────────────────┘
```

Presentation tier is `web` (nginx). Business tier is the eight Node/Java/Go/PHP
services. Data tier is `mongodb`, `mysql`, `redis` and `rabbitmq`. The chart
models the data tier as a `StatefulSet` for `redis` (it owns a `gp2` PVC) and
`Deployments` for the rest.

`dispatch` and `payment` consume a RabbitMQ queue; `ratings` (PHP/Apache) reads
`mysql`; `catalogue`, `user` and `cart` read `mongodb` and `redis`.

---

## Prerequisites

`kubectl`, `eksctl`, `aws` CLI v2, `helm` v3, `docker`, and a hostname in
`~/.kube/config` pointing at the cluster.

---

## Deploying

### 1. Cluster

```bash
eksctl create cluster -f eksctl/cluster.yaml
aws eks update-kubeconfig --name wisdom-eks --region us-east-1
```

Creates the VPC across two AZs, the control plane, and a `t3.micro` node group
with VPC CNI prefix delegation enabled.

### 2. OIDC provider, ALB controller, EBS CSI driver

These are IRSA roles, so they must be created *after* the control plane exists --
their trust policy embeds the cluster's OIDC issuer. See:

- [`EKS/03-oidc-IAM.md`](EKS/03-oidc-IAM.md)
- [`EKS/04-alb-configuration.md`](EKS/04-alb-configuration.md)
- [`EKS/05-ebs-csi-driver.md`](EKS/05-ebs-csi-driver.md)

```bash
eksctl utils associate-iam-oidc-provider --cluster wisdom-eks --approve
```

### 3. Build and push images

```bash
./scripts/build-push.sh                 # all ten
./scripts/build-push.sh cart web        # just two
TAG=2.1.1 ./scripts/build-push.sh       # different tag
```

The script creates each ECR repository if absent, so it is safe to re-run.

### 4. Deploy

```bash
kubectl create ns robot-shop
helm install robot-shop ./EKS/helm --namespace robot-shop \
  --set image.repo=<account>.dkr.ecr.us-east-1.amazonaws.com/robot-shop \
  --set image.version=2.1.0

kubectl apply -f EKS/helm/ingress.yaml
```

Watch it come up:

```bash
kubectl get pods -n robot-shop -w
kubectl get ingress -n robot-shop      # ADDRESS is the public URL
```

### 5. Verify

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<ALB-DNS-name>/
```

---

## Two design decisions worth knowing

**`web` is a `ClusterIP`, not a `LoadBalancer`.** Upstream `web-service.yaml`
renders `type: LoadBalancer` whenever `nodeport` is false. Combined with
`ingress.yaml` that produces *two* load balancers in front of the same app: an
internal NLB (from the Service) and a public ALB (from the Ingress). The chart
template was changed to `ClusterIP`. The ALB targets pod IPs directly
(`target-type: ip`), so it does not need a LoadBalancer Service, and this halves
the load balancer bill. The internal NLB was unreachable from outside the VPC
anyway, so nothing was lost.

**`mysql` and `shipping` resource requests come from `values.yaml`.** The
upstream templates hardcode `700Mi` and `500Mi` requests. A `t3.micro` only has
512Mi allocatable, so `mysql` could never be scheduled at any node count. Both
are now values-driven, and `shipping`'s JVM flags in its `Dockerfile` were
matched to its new limit. See
[`docs/troubleshooting.md`](docs/troubleshooting.md) #3 and #4.

---

## Capacity: read this before scaling

This was built against a free-tier AWS account, and that is a real constraint,
not a formality. Measured numbers:

- `t3.micro` advertises 933Mi RAM but only **512Mi is allocatable** per node.
- Robot Shop requests **1056Mi** in total; `kube-system` claims roughly
  **175Mi on every node** for `aws-node`, `kube-proxy`, `coredns`,
  `ebs-csi-node` and the ALB controller.
- At 4 nodes that is ~1756Mi of 2048Mi — **86% committed before any CPU is
  considered.** Under that load kubelets starved, nodes went
  `NodeStatusUnknown`, and the storefront returned 503.
- 7 nodes brings it to roughly 64%. That helps, but it does not fix the real
  problem: the scheduler stacks `mysql` and `rabbitmq` together and pushes a
  node to 99% memory, which evicts pods and then starves kubelet.

On a paid account, use `t3.small` or larger and stop fighting this. If staying
on `t3.micro`, add `topologySpreadConstraints` or pod anti-affinity to the chart
so no single node gets overloaded. Cost note: 7 × `t3.micro` is ~5088 instance
hours per month against a 750-hour free allowance, so roughly $40-50/month.

Also relevant: `t3` is burstable. `T3Unlimited` was not enabled here, so once CPU
credits deplete the instance is throttled to its ~20% baseline.

---

## Teardown

```bash
helm uninstall robot-shop -n robot-shop     # keep the cluster
eksctl delete cluster --name wisdom-eks --region us-east-1
```

Deleting the cluster does not delete the ECR repositories. Remove them
separately if you want the account clean:

```bash
for r in cart catalogue dispatch mongodb mysql-db payment ratings shipping user web; do
  aws ecr delete-repository --repository-name robot-shop/rs-$r --region us-east-1 --force
done
```

---

## Credits

Application and original Dockerfiles: [instana/robot-shop](https://github.com/instana/robot-shop),
Apache 2.0. EKS-specific material: [iam-veeramalla/three-tier-architecture-demo](https://github.com/iam-veeramalla/three-tier-architecture-demo).
