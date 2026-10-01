# AWS Load Balancer Controller

Without this, the Ingress object in `EKS/helm/ingress.yaml` is inert Kubernetes
plumbing. With it, a controller pod watches Ingresses and calls the AWS APIs to
build a real Application Load Balancer.

## What it provisions

`EKS/helm/ingress.yaml`:

```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 8080
```

- `internet-facing` -- public, so the storefront is reachable from a browser
- `target-type: ip` -- the ALB registers **pod IPs** directly, no NodePort hop

## Prerequisites

The OIDC provider and `AmazonEKSLoadBalancerControllerRole` from
[03-oidc-IAM.md](03-oidc-IAM.md). The role's `sub` must be
`system:serviceaccount:kube-system:aws-load-balancer-controller`.

## 1. IAM policy

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

This is a **customer-managed** policy. It is not in the AWS-managed `iam::aws:`
namespace, so `arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy` will
not resolve.

## 2. Attach it to the role

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy
```

Skip this if you attached the policy at role-creation time.

## 3. Install the controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

VPC_ID=$(aws eks describe-cluster --name wisdom-eks --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wisdom-eks \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

`serviceAccount.create=false` tells Helm **not** to create the ServiceAccount,
because the one in `kube-system` already exists and carries the IRSA annotation.
If Helm creates its own, the pod gets no AWS permissions at all and the Ingress
will never resolve.

`VPC_ID` is discoverable in the console at `EKS > wisdom-eks > Networking`.

## 4. Verify

```bash
kubectl get deploy -n kube-system aws-load-balancer-controller
# NAME                             READY   UP-TO-DATE   AVAILABLE
# aws-load-balancer-controller     2/2     2            2

kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | tail
```

The controller logs its AWS identity on startup. An `AccessDenied` or
`WebIdentityErr` there points at the trust policy in
[03-oidc-IAM.md](03-oidc-IAM.md) #3.

## 5. Create the Ingress

```bash
kubectl apply -f EKS/helm/ingress.yaml
kubectl get ingress -n robot-shop -w
```

```
NAME         CLASS    HOSTS   ADDRESS                                                                  PORTS   AGE
robot-shop   alb      *       k8s-robotsho-robotsho-bbf1f25197-365575556.us-east-1.elb.amazonaws.com   80      45s
```

`ADDRESS` is the public URL. First creation takes 2-4 minutes.

Confirm in the console at `EC2 > Load Balancers` -- a single ALB, scheme
`internet-facing`. `EKS > wisdom-eks > Resources > Ingresses` shows the same
address.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<address>/
```

## Only one load balancer

If `EC2 > Load Balancers` shows **two** entries for this app, `web-service.yaml`
is still rendering `type: LoadBalancer` and you have an extra NLB. This chart is
changed to `ClusterIP`; the ALB targets pod IPs directly and does not need it.

With `web` as `LoadBalancer` you get:

| | From Service | From Ingress |
|---|---|---|
| Type | NLB (`network`) | ALB (`application`) |
| Scheme | `internal` | `internet-facing` |
| Targets | `instance` (via NodePort) | `ip` (pod IPs) |
| Reachable externally | no | yes |

The NLB lands in `internal` because the nodes are in private subnets, so it was
unreachable from outside the VPC while still billing ~$25/month. The fix is in
`EKS/helm/templates/web-service.yaml`:

```yaml
{{ if .Values.nodeport }}
  type: NodePort
  {{ else }}
  type: ClusterIP
  {{ end }}
```

Applying it:

```bash
helm upgrade robot-shop ./EKS/helm -n robot-shop --reuse-values
```

`--reuse-values` is important -- without it Helm reverts `image.repo` and
`image.version` to the defaults in `values.yaml` and every pod goes
`ImagePullBackOff`. Watch `EC2 > Load Balancers` drop from two to one.

## Troubleshooting

**Ingress stuck `pending`, ADDRESS empty**

```bash
kubectl describe ingress -n robot-shop robot-shop | tail -20
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

`AccessDenied` is an IAM problem -- check the role's trust policy and attached
policy. `unable to resolve` usually means the controller cannot reach the
internet; nodes in private subnets need the NAT gateway from the VPC creation.

**503 from the ALB**

The load balancer is healthy but has no healthy targets. Check the backend:

```bash
kubectl get endpoints -n robot-shop web
```

Empty means no ready `web` pod -- see
[`../docs/troubleshooting.md`](../docs/troubleshooting.md) #7 for the nginx
upstream resolution trap.
