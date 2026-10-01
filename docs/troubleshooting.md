# Troubleshooting

Every issue here actually happened while building this on a free-tier account.
Error strings are copied from the real output, not paraphrased.

---

## 1. Node group rolls back instantly, cluster is ACTIVE but has no nodes

**Symptom.** `eksctl create cluster` returns, the control plane is `ACTIVE`,
`EKS > Compute` is empty, and `kubectl get nodes` returns nothing.

**Real error** (CloudFormation events on the node group stack):

```
AsgInstanceLaunchFailures: Could not launch On-Demand Instances.
InvalidParameterCombination - The specified instance type is not eligible
for Free Tier.
```

**Cause.** `eksctl create cluster` with no config file defaults the node group
to `m5.large`. This AWS account only permits free-tier-eligible types, so the
ASG launch fails, CloudFormation rolls back, and the node group stack ends in
`ROLLBACK_COMPLETE`. `aws eks list-nodegroups` then returns `[]`.

**Why it is confusing.** the control plane really is fine, so the cluster looks
healthy in the console. Only the compute tier is missing.

**Fix.** Use `t3.micro`. In `eksctl/cluster.yaml` it is set explicitly.

**Note.** `t3.medium` is *also* rejected. It is not a free-tier instance type.

---

## 2. Add-ons stuck DEGRADED with "Too many pods"

**Symptom.** `aws-ebs-csi-driver` reports:

```
InsufficientNumberOfReplicas: 0/2 nodes are available:
2 Too many pods. preemption: 0/2 nodes are available:
2 No preemption victims found for incoming pod.
```

**Cause.** `kubectl describe nodes` shows the real number:

```
Capacity:  pods: 4
Allocatable:
  pods:    4
```

`t3.micro` has 4 ENIs and therefore only 4 pod IP addresses unless the VPC CNI
uses prefix delegation. Both nodes were at 4/4 with `aws-node`, `kube-proxy`,
`coredns` and the ALB controller, so nothing else could ever schedule.

**The trap.** Setting `ENABLE_PREFIX_DELEGATION=true` on an *existing* node
group does nothing. The `--max-pods` flag is passed to the kubelet in the node
group's launch template user-data, which is baked in at first boot. Nodes
recycled in place still come up with `maxPods=4`.

**Fix.** Set it at node group creation time, then create a *new* node group.
`eksctl/cluster.yaml` has the addon under `managedNodeGroups[].addons` for
exactly this reason. After it, `maxPods=34`.

---

## 3. "Insufficient memory" — pods Pending forever, scaling does not help

**Symptom.** `mysql` and `shipping` sit in `Pending` with:

```
0/4 nodes are available: 4 Insufficient memory.
Preemption is not helpful for scheduling.
```

**The arithmetic that matters.** A `t3.micro` advertises 933Mi of RAM but only
**512Mi is allocatable** — the rest goes to kubelet and system daemons. The
upstream chart asks for more than a whole node has:

| Service | request | limit |
|---|---|---|
| mysql | 700Mi | 1024Mi |
| shipping | 500Mi | 1000Mi |
| rabbitmq | 256Mi | 200Mi |

`mysql`'s 700Mi request cannot fit in 512Mi of allocatable memory **on a single
node no matter how many nodes you add.** The scheduler needs one node that can
satisfy the whole request.

**Fix.** Both are now driven from `values.yaml` rather than hardcoded in the
templates:

```yaml
mysql:
  resources: {requests: {cpu: 100m, memory: 200Mi}, limits: {cpu: 200m, memory: 300Mi}}
shipping:
  resources: {requests: {cpu: 100m, memory: 150Mi}, limits: {cpu: 200m, memory: 300Mi}}
```

**Requests control scheduling, limits control OOM-kill.** Lowering the request
lets the pod be placed; lowering the limit means the process dies if it exceeds
it. Both were needed.

---

## 4. shipping gets OOMKilled instead of Pending

**Symptom.** After fixing #3, `shipping` starts and is then killed:

```
Liveness probe failed / OOMKilled
```

**Cause.** The container limit said 300Mi but the JVM was told it could use
768Mi of heap:

```dockerfile
CMD ["java", "-Xmn256m", "-Xmx768m", "-jar", "shipping.jar"]
```

The kernel kills the process the moment RSS crosses the cgroup limit, regardless
of what `-Xmx` says. The chart's resource numbers and the JVM flags have to
agree.

**How the numbers were chosen.** Measured, not guessed. Run the image under the
real limit and watch it plateau:

```bash
docker run --rm --name ship-test --memory=300m --memory-swap=300m \
  -p 8080:8080 -e CART_ENDPOINT=cart:8080 -e DB_HOST=mysql shipping:local
docker stats --no-stream ship-test
```

| Heap flags | Settled usage | Verdict |
|---|---|---|
| `-Xmn96m -Xmx192m -XX:MaxMetaspaceSize=64m` | 270Mi / 300Mi (90%) | works, no headroom |
| `-Xmn64m -Xmx144m -XX:MaxMetaspaceSize=48m` | 214Mi / 300Mi (71%) | **used** |

Sampling once is misleading — the first sample was 238Mi and it kept climbing
for several minutes before plateauing. Wait for a plateau before trusting a
number. `-XX:+ExitOnOutOfMemoryError` turns a thrashing hang into an immediate,
obvious failure.

---

## 5. Pod CrashLoopBackOff: `/bin/sh: 1: [dispatch]: not found`

**Symptom.**

```
kubectl logs -n robot-shop deploy/dispatch
/bin/sh: 1: [dispatch]: not found
```

**Cause.** A Dockerfile edit changed exec form to shell form:

```dockerfile
CMD ['dispatch']    # broken -- shell form, the literal string "['dispatch']" is the command
CMD ["dispatch"]    # correct -- exec form
```

Docker passes `CMD ['dispatch']` to `/bin/sh -c` as the string `['dispatch']`,
which is a syntax error, so the container exits immediately and restarts
forever. The error message quotes the whole line, which makes it look like a
missing binary rather than a quoting mistake.

**Fix.** Double quotes. Checked in `dispatch/Dockerfile`.

---

## 6. `provisioning failed: no topology key found for node ...`

**Symptom.** `data-redis-0` stuck `Pending` with:

```
ProvisioningFailed: error generating accessibility requirements:
no topology key found for node ip-192-168-87-104.ec2.internal
```

**Cause.** Not a real fault. `WaitForFirstConsumer` holds the claim until a pod
is scheduled, and the EBS CSI driver had to read the node's
`topology.ebs.csi.aws.com/zone` label. The node had just joined and did not have
it yet. The label appeared seconds later and provisioning completed on retry.

**Fix.** none. Wait. If it persists, confirm the label exists:
`kubectl get node <node> -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep topology`

---

## 7. nginx `host not found in upstream "catalogue"` on startup

**Symptom.** `web` crashloops with:

```
nginx: [emerg] host not found in upstream "catalogue" in /etc/nginx/conf.d/default.conf:58
```

**Cause.** nginx resolves upstream hostnames **once**, at config load. If
CoreDNS has no ready pod at that instant, nginx cannot start at all. This
happened while nodes were being replaced and both `coredns` replicas were
`Terminating`, leaving DNS briefly unavailable.

**Fix.** The `web` image in this repo no longer has this problem. The
upstream hostnames are now passed to `proxy_pass` through variables, with a
`resolver 127.0.0.11` directive, so nginx resolves them at request time
instead of while parsing its config. An unresolvable upstream now produces a
`502` on the affected route and leaves the rest of the site serving, rather
than preventing the container from starting at all.

Measured, with the same unresolvable hostname in both configs:

| | container | result |
|---|---|---|
| hostname directly in `proxy_pass` | exits, code 1 | `nginx: [emerg] host not found in upstream` |
| hostname via a variable + resolver | stays running | `GET /` 200, `GET /api/catalogue/` 502 |

If you are running an older `rs-web` image, delete the pod once DNS is healthy
and it will come up:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns   # confirm 1/1 Running first
kubectl delete pod -n robot-shop -l service=web
```

**Lesson.** Startup-order dependencies are a real class of bug. A `web` pod
that starts before `catalogue` will never recover on its own when the container
dies at startup rather than retrying. Anything that resolves dependencies
should do it per request, not at load.

---

## 8. Whole cluster went NotReady under full load

**Symptom.** All nodes `NotReady` at once, storefront `HTTP 503`, but EC2 and the
ASG both still report `Healthy`:

```
Ready  Unknown  NodeStatusUnknown  Kubelet stopped posting node status.
```

**Why the console misleads.** ASG health checks look at the EC2 instance, not
the kubelet. The hosts are alive; only kubelet is unresponsive. Nothing
auto-replaces them, so you have to do it by hand.

**Cause.** Memory, not CPU. Before each node died its allocation was:

```
memory  476Mi (92%)
memory  510Mi (99%)
```

A node at 99% memory evicts pods, and under that load kubelet itself gets
starved of CPU and stops posting status within the grace period. Nodes then go
`NotReady` in sequence, ~7 minutes apart, which is the signature of cumulative
resource exhaustion rather than a single event.

**Contributing factor.** `t3.micro` is *burstable*: `T3Unlimited` was not set,
so once CPU credits deplete the instance is throttled to its ~20% baseline.

**Recovery.**

```bash
# 1. scale out first so there is room for the replacements to start
aws eks update-nodegroup-config --cluster-name wisdom-eks \
  --nodegroup-name ng-micro-17 --region us-east-1 \
  --scaling-config minSize=1,maxSize=7,desiredSize=7

# 2. terminate the instances whose kubelets are wedged.
#    --no-should-decrement-desired-capacity keeps desired at 7.
ASG=$(aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'ng-micro-17')].AutoScalingGroupName" --output text)
for id in i-... i-...; do
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$id" --no-should-decrement-desired-capacity --region us-east-1
done
```

Then wait, and clean up the stale node objects the dead instances left behind:

```bash
kubectl get nodes                     # delete any left in NotReady with no backing instance
kubectl delete node ip-192-168-...    # --ignore-not-found
```

**The underlying problem is pod distribution, not node count.** The scheduler
happily stacks `mysql` (200Mi) and `rabbitmq` (256Mi) together and puts a node
over the edge. Adding nodes raises the ceiling; it does not stop the stacking.
On 12 services against nodes with 512Mi each there is very little slack for a
hot spot.

### The fix, which the chart now supports

The chart used to name this fix without providing it. Both mechanisms are now
implemented, opt-in, and off by default:

| Value | Effect |
|---|---|
| `topologySpreadConstraints` | spreads a workload's replicas across nodes. **Use this one.** |
| `antiAffinity` | merges into `affinity` as `podAntiAffinity`, refusing to co-locate |
| `podDisruptionBudgets` | unrelated to memory; see the single-replica warning in `values.yaml` |

For the memory problem, spread constraints are the right tool because they
*redistribute* rather than *refuse*. With `whenUnsatisfiable: ScheduleAnyway`
the scheduler still places a pod when the spread cannot be met, so the
constraint can never wedge a deployment. Using `DoNotSchedule` instead would
turn a memory problem into pods that never schedule, which on a small node
count is strictly worse.

Apply it to the three heaviest services:

```yaml
# values.yaml, or a -f overlay
mysql:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          service: mysql
rabbitmq:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          service: rabbitmq
shipping:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          service: shipping
```

The real fix, though, is not a scheduling constraint. It is nodes with more
than 512Mi of allocatable memory, so that a hot spot has somewhere to go.
These constraints keep the scheduler from concentrating the load; they cannot
create headroom that does not exist.

---

## 9. IRSA role trust policy with no `sub` condition

**Symptom.** Not an error -- a silent over-permission. The role works, so nothing
looks wrong. Created through the AWS Console, the trust policy came out as:

```json
"Condition": { "StringEquals": { "oidc...:aud": "sts.amazonaws.com" } }
```

**Why it matters.** With only `aud` pinned, *any* service account in *any*
namespace in the cluster can obtain a token that satisfies the condition and
assume the role. That defeats the point of IRSA. The `sub` claim is what scopes
the grant to one workload:

```json
"Condition": { "StringEquals": {
  "oidc...:aud": "sts.amazonaws.com",
  "oidc...:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
}}
```

**Verify.**

```bash
aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json
```

Both `aud` and `sub` must be present. If you only see `aud`, add the `sub` entry
by hand.
