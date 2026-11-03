---
title: "Stretched SUSE Virtualization cluster: what 50 ms to the witness site does to etcd"
date: 2026-11-03T20:00:00Z
draft: false
tags: ["suse-virtualization", "harvester", "etcd", "rke2", "high-availability", "stretched-cluster", "disaster-recovery"]
summary: "A stretched SUSE Virtualization cluster needs a third site for etcd quorum. I put 25 ms each way between that site and the other two nodes with tc netem and measured the control plane in four scenarios: normal operation, witness as leader, a data center lost, and the worst case with a VM create."
images: ["og.jpg"]
---

![Illustration of a stretched SUSE Virtualization cluster: Harvester nodes running VMs and etcd at site A and site B, linked to an etcd witness at a tiebreaker site over a 50 ms round-trip link](stretched-suse-virtualization-witness-latency.jpg)

**TL;DR**

- A stretched SUSE Virtualization (Harvester) cluster puts one etcd member in each of two data centers and a third, etcd-only member at a quorum site. I delayed the third member's etcd traffic by **25 ms each way (50 ms round trip)** on a 3-node lab cluster and measured the control plane, not the storage.
- **Normal operation: no measurable change.** Write latency stayed at baseline (102.4 ms vs 102.3 ms in my benchmark) because the two data center members form the quorum on their own.
- **One data center lost: about +50–60 ms per API write**, one round trip to the quorum site plus its disk write. **Quorum-site member as etcd leader: about +100 ms per write.** **Worst case (both at once): a VM went from create to Running in 25.3 s instead of 18.2 s**, and `kubectl get` calls took 100–200 ms longer.
- No spurious leader elections in any scenario. RKE2, and therefore SUSE Virtualization, ships etcd with a **500 ms heartbeat and 5000 ms election timeout**, not upstream etcd's 100/1000 ms, so a 50 ms round trip is well inside the timers.
- `etcd_network_peer_round_trip_time_seconds` reported about **100 ms for a 50 ms link**: half the probes open a new TLS connection. Size alerts on that metric accordingly.

![Diagram of a stretched SUSE Virtualization cluster: a management node with etcd, worker nodes and a storage array in each of two data centers about 1 ms apart, and a third site with an etcd-only witness node and a storage witness, connected to both data centers with 25 ms each way](stretched-cluster-three-sites.jpg)

Two data centers a mile apart make a good pair for a stretched cluster: about 1 ms between them, close enough for synchronous storage replication and for etcd. A stretched cluster still needs a third vote, though. Without it, losing the data center that holds the majority stops the cluster, and nothing can tell a site failure from a cut link between the sites. Third sites are rarely next door. A question I got recently was whether a quorum site 25 ms away is acceptable for a SUSE Virtualization cluster, and how much slower things get when that site has to take part in every decision. I tested it.

> [!NOTE] Scope: hypervisor control plane, not storage
> These tests measure the SUSE Virtualization control plane: etcd, the Kubernetes API and the VM lifecycle on top of them. Storage replication latency between the two data centers is a separate budget set by the storage vendor, and I did not measure it here. See the [appendix](#appendix-storage-witness-latency-requirements) for the published vendor limits.

## Design: a stretched cluster with a witness

SUSE Virtualization can span both data centers as one cluster: a management node in each data center, worker nodes in both, and a [witness node](https://docs.harvesterhci.io/v1.6/advanced/witness/) at the third site. A witness node runs only etcd. It holds no VMs and no workloads, so it can be a small machine or a VM at a colocation facility.

etcd commits a write once a majority of members has it on disk. With three members, that means any two:

| State | Members that can commit | Who has to answer for a write |
|---|---|---|
| Normal, leader in a data center | DC1 + DC2 | the other data center, about 1 ms away |
| Witness member is leader | witness + either data center | every write crosses the 25 ms link |
| One data center down | survivor + witness | every write crosses the 25 ms link |
| Witness site down | DC1 + DC2 | nothing changes for writes |

So the witness link only matters in two states: when a data center is gone, and when the witness becomes leader, which etcd allows after any election. Both are worth measuring.

## Lab setup

- **Cluster:** three mini PCs (AMD Ryzen 5 5560U, 6 cores/12 threads, 32 GB RAM, SATA SSD), running a SUSE Virtualization v1.10 release candidate with RKE2 v1.36.5 and etcd 3.6.14. All three nodes sit on the same switch, about 0.5 ms apart.
- **Roles for the test:** node A plays data center 1, node B data center 2, node C the quorum site. All three are full management nodes in this lab, not a dedicated witness, but etcd's quorum maths is the same.
- **Benchmark client:** a script on node B, the surviving data center in every scenario, sends 200 serial `PATCH`es and 200 `GET`s to one ConfigMap through the local kube-apiserver with `curl` and records `time_total`. Each call pays a fresh TLS handshake, so the floor is about 100 ms per request on these nodes. Compare the deltas between scenarios, not the absolute numbers.
- **VM test:** create a VM from a 300 MB openSUSE Leap 16 image on a Longhorn volume, wait for it to reach `Running`, run five rounds of common `kubectl get` commands, and delete it.

### etcd timers on SUSE Virtualization

etcd's [tuning guide](https://etcd.io/docs/v3.6/tuning/) says to set the heartbeat interval close to the round trip between members and the election timeout to at least ten times that. Upstream defaults are a 100 ms heartbeat and a 1000 ms election timeout. RKE2 writes its own, five times larger defaults into the etcd config, and every SUSE Virtualization cluster I checked (v1.9.0 and the v1.10 release candidate) had them:

```console
$ sudo grep -E "heartbeat|election" /var/lib/rancher/rke2/server/db/etcd/config
election-timeout: 5000
heartbeat-interval: 500
```

A 500 ms heartbeat is ten times a 50 ms round trip, and the election timeout is a hundred times. Timers are not what limits the distance to the quorum site, so I left them alone.

## How I added the latency

Linux `tc` with the `netem` queueing discipline delays packets on their way out of an interface. Three requirements shaped the setup:

1. **Only etcd peer traffic.** etcd members talk to each other on TCP port 2380. Each kube-apiserver talks to its local etcd over loopback on port 2379, so it is not affected. Filtering on port 2380 keeps VM traffic, Longhorn replication and image pulls at full speed.
2. **Only the paths to the quorum site.** Node A and node B must stay about 1 ms apart, as two data centers a mile apart would be.
3. **Both directions.** `netem` only acts on egress, so node C delays what it sends to A and B, and A and B delay what they send to C. 25 ms on each side gives a 50 ms round trip.

SUSE Virtualization nodes run an immutable OS without the `tc` binary, but the kernel ships `sch_netem` and `cls_u32`. A privileged DaemonSet on the host network provides the tool:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: netem-tc
  namespace: kube-system
spec:
  selector: {matchLabels: {app: netem-tc}}
  template:
    metadata: {labels: {app: netem-tc}}
    spec:
      hostNetwork: true
      tolerations: [{operator: Exists}]
      containers:
      - name: tc
        image: nicolaka/netshoot:latest
        command: ["sleep", "infinity"]
        securityContext: {privileged: true}
```

On node C (the quorum site), from that node's pod, a `prio` qdisc gets a fourth band that only matching packets reach, `netem` hangs off that band, and `u32` filters send port 2380 traffic for A and B into it. Matching on both destination and source port catches connections in both directions:

```bash
DEV=mgmt-br.2          # interface that carries the node's management IP
tc qdisc add dev $DEV root handle 1: prio bands 4
tc qdisc add dev $DEV parent 1:4 handle 40: netem delay 25ms
for peer in 192.0.2.10 192.0.2.11; do     # node A, node B
  tc filter add dev $DEV parent 1: protocol ip prio 1 u32 \
    match ip dst $peer/32 match ip dport 2380 0xffff flowid 1:4
  tc filter add dev $DEV parent 1: protocol ip prio 1 u32 \
    match ip dst $peer/32 match ip sport 2380 0xffff flowid 1:4
done
```

Nodes A and B get the same rules with node C (192.0.2.12) as the only peer. Removing everything is one command per node: `tc qdisc del dev $DEV root`.

## Verifying the delay

A TCP handshake is exactly one round trip, so `curl`'s `time_connect` from node C is a clean check. Port 2380 shows the 50 ms; port 2379 on the same peer stays at local speed:

```console
192.0.2.10:2380  0.050489 0.050559 0.050489 0.050490 0.050684
192.0.2.10:2379  0.000503 0.000436 0.000477 0.000479 0.000415
```

`tc -s qdisc show` confirmed packets flowing through the `netem` band with no drops.

etcd's own metric disagreed. `etcd_network_peer_round_trip_time_seconds` averaged **102.6 ms** between node C and its peers, while A to B stayed at 3 ms. Over 90 seconds, the histogram split evenly between two buckets:

| Bucket | Probes | Round trips |
|---|---|---|
| 25.6–51.2 ms | 3 | 1: probe on an existing connection |
| 102.4–204.8 ms | 3 | about 3: new TCP connection, TLS 1.3 handshake, request |

etcd runs two probers per peer and both feed the same histogram. One of them opens a new connection for every probe, as reported in [etcd issue #17837](https://github.com/etcd-io/etcd/issues/17837), which was closed as not planned. An older report, [#11781](https://github.com/etcd-io/etcd/issues/11781), found the same metric includes connection setup time. My reading of the buckets is that the slow half pays TCP and TLS setup; I have not traced it in the etcd code.

> [!WARNING] Peer RTT metric reads about 2× on a WAN link
> On a 50 ms link, `etcd_network_peer_round_trip_time_seconds` averaged about 100 ms, and its p99 can approach 150 ms. Alert thresholds on it need that headroom, and the real round trip to a quorum site should be measured with ping or TCP connect time.

## Test scenarios and results

Each scenario ran for three to five minutes with the delay in place. Leader moves used `etcdctl move-leader`; the data center loss was `systemctl stop rke2-server` followed by `rke2-killall.sh` on node A.

| Scenario | Leader | Members up | Write avg | Write p99 | Read avg |
|---|---|---|---|---|---|
| Baseline, no delay | A | 3 | 102.3 ms | 122.6 ms | 97.7 ms |
| 1. Quorum site at 50 ms | A | 3 | 102.4 ms | 113.3 ms | 97.0 ms |
| 2. Quorum-site member is leader | C | 3 | 201.2 ms | 215.2 ms | 264.2 ms |
| 3. Data center 1 lost | B | B + C | 152–163 ms | 175–210 ms | 171–176 ms |
| After cleanup | A | 3 | 103.0 ms | 122.5 ms | 99.4 ms |

What the numbers say, with about 100 ms of `curl` overhead subtracted:

- **Scenario 1, normal operation:** nothing changes. Node A commits with node B's acknowledgement and never waits for node C.
- **Scenario 3, a data center lost:** about **+50–60 ms per write**. Every commit now needs node C: 25 ms out, a disk write on node C, 25 ms back. This is the "network + disk + network" budget people usually sketch for a quorum site.
- **Scenario 2, quorum-site member as leader:** about **+100 ms per write**, two round trips. A write that arrives at node B is forwarded to the leader on node C (25 ms), replicated back to a data center member and acknowledged (50 ms), and the commit reaches node B (25 ms). Reads that must be up to date also confirm leadership across the link, which is why reads rose more than writes.
- **Stability:** etcd changed leader only when I told it to. `etcd_server_heartbeat_send_failures_total` stayed at zero on every member.

### Worst case: witness as leader and a data center down

For the last scenario I combined both bad states: node C as leader, node A killed, and the 50 ms delay in place. Then I created a VM and ran common `kubectl get` commands from node B, and compared them with the same steps on the healthy cluster:

| Operation | Healthy | Worst case | Change |
|---|---|---|---|
| `kubectl get nodes` | 112–127 ms | 235–311 ms | +120–190 ms |
| `kubectl get vm -A` | 101–112 ms | 203–304 ms | +100–190 ms |
| `kubectl get pods -A` | 303–379 ms | 452–545 ms | +150–170 ms |
| `kubectl apply` of the VM | 181 ms | 571 ms | +390 ms |
| PVC bound (image-backed Longhorn volume) | 2.5 s | 6.1 s | +3.6 s |
| **VM `Running`** | **18.2 s** | **25.3 s** | **+7.1 s** |
| VM deleted | 70.0 s | 78.5 s | +8.5 s |

A VM create touches the API many times in sequence (the VM object, its volume claim, the Longhorn volume and replicas, the launcher pod, status updates), so 100 ms per write adds up to seconds, not milliseconds. Everything still worked: the Longhorn volume attached with one node gone, the VM booted on node B, and the cluster recovered cleanly when node A came back.

## Takeaways

- **A 50 ms round trip to the quorum site works** for the SUSE Virtualization control plane with the default RKE2 etcd timers. Nothing failed, and no election fired that I did not trigger.
- **Budget for the degraded states, not the happy path.** With a data center down, every API write pays one round trip to the quorum site plus its disk write. If the quorum-site member is leader, writes pay two round trips.
- **Keep leadership in the data centers.** Alert when the quorum-site member becomes leader and move it back with `etcdctl move-leader`. A dedicated witness node helps here, since it runs nothing else.
- **Watch jitter and loss, not only latency.** A long WAN path is more likely to have jitter spikes, and those trigger elections well before steady latency does. I did not test jitter or loss.
- **Measure the link yourself.** etcd's peer RTT metric reads about twice the real round trip on a WAN link.
- **Check what "25 ms" means.** Ping reports a round trip. If the quorum site is 25 ms round trip rather than each way, every degraded-mode number above roughly halves.

## Limits of this test

- Storage replication latency between the data centers was out of scope; see the appendix.
- Lab disks are faster than a typical quorum-site server: WAL fsync p99 stayed between 2 and 8 ms. A 10 ms disk adds that difference to every degraded-mode write.
- Runs were minutes long, not weeks, and used a full management node as the quorum-site member rather than the witness role.

## Appendix: storage witness latency requirements

A stretched cluster with synchronous storage replication usually has a second quorum at the third site: the storage array's witness. Its limits come from the storage vendor, not from SUSE Virtualization:

| Product | Requirement | Source |
|---|---|---|
| Dell PowerMax SRDF/Metro Virtual Witness (vWitness) | Latency less than 40 ms from each vWitness to both arrays (Dell does not say whether this is round trip or one way). Dell recommends at least two vWitness instances in separate fault domains. With PowerMaxOS 10 it runs as a daemon on a Linux host. | [Dell vWitness configuration guide](https://www.dell.com/support/manuals/en-us/powermax-os-10/srdf_metro_vwitness_configuration_guide/configuration-guidelines?guid=guid-983e8a91-0299-4082-b157-b0e7e7e977f1&lang=en-us), [SRDF/Metro best practices](https://www.dell.com/en-us/infohub/articles/dell-powermax-and-vmax-all-flash-srdf-metro-overview-and-best-practices) |
| NetApp SnapMirror active sync | Inter-cluster round trip less than 10 ms. ONTAP Mediator in a third failure domain for automatic failover. ONTAP Cloud Mediator (ONTAP 9.17.1 and later): ping latency below 200 ms recommended. | [Prerequisites](https://docs.netapp.com/us-en/ontap/snapmirror-active-sync/prerequisites-reference.html), [Cloud Mediator](https://docs.netapp.com/us-en/ontap/snapmirror-active-sync/cloud-mediator-requirements-concept.html) |
| NetApp SnapMirror synchronous | Inter-cluster latency up to 10 ms | [NetApp: choosing a DR solution](https://www.netapp.com/blog/disaster-recovery-solution-for-enterprise-apps/) |
| NetApp MetroCluster IP | ONTAP Mediator round trip less than 75 ms, jitter no more than 5 ms, separate failure domains to each site | [Mediator requirements for MetroCluster IP](https://docs.netapp.com/us-en/ontap-metrocluster/install-ip/concept_mediator_requirements.html) |

Two things stand out when you lay these next to the etcd results. First, the inter-site storage limits (10 ms for NetApp synchronous replication) are much tighter than anything the quorum site needs, so the distance between the two data centers is set by storage, not by etcd. Second, the etcd witness and the storage witness should sit at the same third site with the same network paths, so that after a cut between the data centers both pick the same surviving side.

For asynchronous, active/passive replication between two separate clusters instead of a stretched one, see [NetApp SnapMirror between two ONTAP simulators](/posts/netapp-snapmirror-two-ontap-simulators-suse-virtualization/) and [VM failover and failback with Harvey](/posts/harvey-vm-failover-netapp-snapmirror-suse-virtualization/).
