# Screenshots

## These are historical, not live

Every `NN-*.png` here was rendered from real cluster output at the time it was
captured, by a script that has since been removed. The pod names, node names
and timestamps in them are genuine, but the cluster they came from **has been
deleted**, along with its ECR repositories and every other resource.

They are kept as evidence, not as documentation of a running system. Anything
below that describes current behaviour should be treated as "this is what
happened", not "this is what you will get".

To capture fresh ones after rebuilding, run the same commands by hand -- the
generator was a thin wrapper around these, and the table below lists what each
image shows.

| File | Shows |
|---|---|
| `01-nodes.png` | node status and versions |
| `02-node-capacity.png` | the 512Mi allocatable ceiling per node |
| `03-pods.png` | all pod phases including any evictions |
| `04-deployments.png` | 11/12 ready; `shipping` is the one that will not fit |
| `05-ingress.png` | public ALB address |
| `06-services.png` | `web` is `ClusterIP`, not `LoadBalancer` |
| `07-pvc.png` | Redis volume `Bound` via the CSI driver |
| `08-helm.png` | both releases and revisions |
| `09-storageclass.png` | inert in-tree `gp2` next to the working `ebs.csi.aws.com` |
| `10-addons.png` | `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver` |
| `11-nodegroup.png` | `t3.micro`, `maxSize: 7` |
| `12-ecr.png` | all ten repositories and their tags |
| `13-loadbalancers.png` | exactly one ALB, `internet-facing` |
| `14-irsa-trust.png` | trust policy scoped by `sub` |
| `15-storefront.png` | `HTTP 200` through the ALB |

---

## GUI captures: please add these yourself

The CLI output above covers the state of the system, but not what the
interfaces look like. I cannot produce those -- Lens and the AWS Console are
GUI applications on your desktop, and I only have shell access. Rather than
commit images I did not take, here is exactly what to capture, where to find
it, and the filename to use. Drop the files in this directory and commit them.

Use a consistent name: `lens-NN-<slug>.png` or `console-NN-<slug>.png`.
Crop to the panel, keep browser chrome out of the shot, and avoid anything with
your account ID or email visible.

### Lens IDE

| File | What to show | Where in Lens |
|---|---|---|
| `lens-01-cluster-added.png` | the cluster listed and connected | `Catalog > Clusters` |
| `lens-02-nodes.png` | node list with version and status | `Cluster > Nodes` |
| `lens-03-node-capacity.png` | the memory that makes or breaks scheduling | `Cluster > Nodes`, select a node, Capacity section |
| `lens-04-pods.png` | workload list across all namespaces | `Workloads > Pods (All namespaces)` |
| `lens-05-pvc.png` | the Redis claim and its bound volume | `Storage > Persistent Volume Claims` |
| `lens-06-ingress.png` | the ALB address in the UI | `Network > Ingresses` |
| `lens-07-helm-releases.png` | both releases and revisions | `Apps > Helm Releases` |
| `lens-08-pod-logs.png` | a container log stream | `Workloads > Pods > web`, Logs tab |

The node capacity shot is the most valuable one. It is the clearest way to show
that a `t3.micro` advertises far more RAM than it can actually give a pod.

### AWS Console

| File | What to show | Where in the console |
|---|---|---|
| `console-01-eks-overview.png` | cluster status, version, OIDC issuer URL | `EKS > Clusters > wisdom-eks > Overview` |
| `console-02-compute.png` | the node group and its capacity | `EKS > wisdom-eks > Compute` |
| `console-03-addons.png` | all four add-ons active | `EKS > wisdom-eks > Add-ons` |
| `console-04-ecr-repos.png` | the ten `robot-shop/rs-*` repositories | `ECR > Repositories` |
| `console-05-ecr-images.png` | tags on one repository | `ECR > robot-shop/rs-web > Images` |
| `console-06-iam-oidc.png` | the OIDC identity provider | `IAM > Identity providers` |
| `console-07-iam-role-trust.png` | the trust policy with both `aud` and `sub` | `IAM > Roles > AmazonEKSLoadBalancerControllerRole > Trust relationships` |
| `console-08-ec2-instances.png` | the running `t3.micro` nodes | `EC2 > Instances`, filter `tag:eks:cluster-name = wisdom-eks` |
| `console-09-loadbalancer.png` | the single ALB and its DNS name | `EC2 > Load Balancers` |
| `console-10-vpc.png` | the VPC with public and private subnets | `VPC > Your VPCs` |

The IAM trust policy shot is worth taking deliberately. Compare it against what
`14-irsa-trust.png` shows: if the console's version is missing the `sub` key,
that is issue 9 in [`troubleshooting.md`](../troubleshooting.md) reproduced in the
UI.

### The storefront

Not in either tool -- just a browser:

| File | What to show |
|---|---|
| `store-01-home.png` | the Robot Shop homepage loaded through the ALB |
| `store-02-catalogue.png` | a category page, proving the service chain `web -> catalogue -> mongodb` works |
| `store-03-cart.png` | the cart, proving `web -> cart -> redis` |
| `store-04-orders.png` | the orders page. Read the note below first. |

**On the orders page.** Placing an order needs the full chain
`web -> payment -> rabbitmq -> dispatch -> mysql`. With `shipping` at `0/1` and
`dispatch` needing RabbitMQ round-trips, order placement may not complete on this
cluster. If it does not work, that is a real limitation, not a mistake in your
screenshot -- say so in the commit message rather than leaving a reader to think
it is supposed to work.
