# robot-shop Helm chart

Deploys Stan's Robot Shop -- 11 Deployments, 1 StatefulSet, 12 Services, for
the `web` ingress described in [`../02-eks-cluster-setup.md`](../02-eks-cluster-setup.md).

```bash
kubectl create ns robot-shop
helm install robot-shop ./EKS/helm --namespace robot-shop \
  --set image.repo=<account>.dkr.ecr.us-east-1.amazonaws.com/robot-shop \
  --set image.version=2.1.0
kubectl apply -f ingress.yaml
```

## Images

`image.repo` and `image.version` are combined with a per-service suffix:

```yaml
image: "{{ .Values.image.repo }}/rs-web:{{ .Values.image.version }}"
```

| Setting | Renders |
|---|---|
| `image.repo=acme`, `image.version=latest` | `acme/rs-web:latest` (Docker Hub) |
| `image.repo=<acct>.dkr.ecr.us-east-1.amazonaws.com/robot-shop` | `<acct>.../robot-shop/rs-web:2.1.0` (ECR) |

The suffix is **not** always the service name. `mysql/` publishes as
`rs-mysql-db` and `mongo/` as `rs-mongodb`. The repository names in ECR must
match exactly, or pods fail with `ImagePullBackOff`. `scripts/build-push.sh`
encodes this mapping.

`redis` and `rabbitmq` pull public images directly and ignore these settings.

## web Service type

`web.serviceType` (default `ClusterIP`) controls the `web` Service when
`nodeport` is false.

**Keep it `ClusterIP` on EKS.** The public entry point is the ALB created from
`ingress.yaml` with `target-type: ip`, which routes to pod IPs and does not need
a LoadBalancer Service. Setting `LoadBalancer` produces a second, internal NLB
alongside the ALB: it lands in the private subnets, so it is unreachable from
outside the VPC, and it bills roughly $25/month for nothing. Set
`web.serviceType=LoadBalancer` only if you deliberately want a second entry
point.

`nodeport: true` overrides everything with `NodePort`, which is for minikube and
similar.

## Resources

`mysql` and `shipping` are the two services that will not schedule at upstream
settings -- `t3.micro` offers 512Mi allocatable and upstream asks for 700Mi and
500Mi respectively. Both are driven from `values.yaml`:

| Key | request | limit |
|---|---|---|
| `mysql.resources` | 200Mi | 300Mi |
| `shipping.resources` | 150Mi | 300Mi |

Override per environment without editing the chart:

```bash
helm install robot-shop ./EKS/helm -n robot-shop \
  --set mysql.resources.requests.memory=700Mi
```

`shipping`'s JVM flags in its `Dockerfile` must stay consistent with its limit.
The committed values were chosen by measuring the container under a real cgroup
limit, not by guessing -- see
[`../../docs/troubleshooting.md`](../../docs/troubleshooting.md) #4.

All other services hardcode small requests (50-100Mi) in their templates.

## Storage

`redis` is the only StatefulSet and the only consumer of a PVC. It uses
`redis.storageClassName`, default `gp2`, which must resolve to a working
CSI-backed StorageClass -- the in-tree `kubernetes.io/aws-ebs` provisioner was
removed in Kubernetes 1.34. See
[`../05-ebs-csi-driver.md`](../05-ebs-csi-driver.md).

## End-user monitoring

```bash
helm install robot-shop ./EKS/helm -n robot-shop \
  --set eum.key=<key> --set eum.url=https://eum-eu-west-1.instana.io
```

Off by default. The tracing libraries are not installed in the committed
images, so enabling this also requires rebuilding `web` with the agent key.

## Scheduling

`affinity`, `nodeSelector` and `tolerations` are available per workload, for
example:

```yaml
shipping:
  nodeSelector:
    node.kubernetes.io/instance-type: t3.small
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "shipping"
      effect: "NoSchedule"
```

`shipping` and `ratings` are the candidates for isolation on a constrained
cluster. If pods stack onto one node and it hits 100% memory, the kubelet is
starved and the node drops `NotReady` -- that happened here, and it is the
single most important failure mode to design against. Spread constraints are
the real fix and are not currently set.

## OpenShift

`openshift: true` plus `ocCreateRoute: true` render an OpenShift `Route`. Only
relevant on OpenShift, not on EKS.

## Pod Security

There are no `PodSecurityPolicy` or `PodSecurityAdmission` resources in this
chart. PSP was removed from Kubernetes in 1.25 and this cluster runs 1.34, so
the templates that once rendered `policy/v1beta1` could never have applied. They
have been deleted rather than left disabled. For admission control, use
`PodSecurityAdmission` namespaces, which is the supported replacement.
