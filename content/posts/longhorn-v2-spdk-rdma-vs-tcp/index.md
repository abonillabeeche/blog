---
title: "Longhorn v2 and SPDK: TCP closes the bandwidth gap, RDMA wins on latency"
date: 2026-10-12
draft: true
tags: ["longhorn", "spdk", "rdma", "nvme-of", "kubernetes", "storage", "benchmark"]
summary: "I benchmarked Longhorn's SPDK-based v2 data engine over NVMe/TCP and over RDMA on two clusters. On 25 GbE both transports fill the wire, so bandwidth ties. RDMA's advantage is latency: queue-depth-1 writes finish in half the time."
# canonicalURL: ""
---

Longhorn's v2 data engine replaces the original iSCSI-and-sparse-file data path with
[SPDK](https://spdk.io/): a user-space, polling NVMe stack. Replicas talk to each other
and to the volume engine over NVMe over Fabrics (NVMe-oF). Today that fabric is
NVMe/TCP. For a few months I've been working on a second transport, RDMA over
Converged Ethernet (RoCEv2), and this post shares what my benchmarks show about when
each one matters.

My short answer: **SPDK over TCP is already fast enough to fill a 25 GbE link, so RDMA
adds no bandwidth there. RDMA wins on latency, by a wide margin.**

## Why Longhorn 1.14 matters for v2

Longhorn 1.14 is still in development, with a target date of January 2027, but its
milestone reads like a coming-of-age release for the v2 engine. Planned items include:

- NVMe reservations, which enable v2 ReadWriteMany block volumes for VM clustering
  ([#14274](https://github.com/longhorn/longhorn/issues/14274),
  [#12055](https://github.com/longhorn/longhorn/issues/12055)).
- I/O control and throttling for v2 volumes
  ([#9265](https://github.com/longhorn/longhorn/issues/9265)).
- Delta replica rebuilding, so a returning replica copies only changed data
  ([#9489](https://github.com/longhorn/longhorn/issues/9489)).
- CPU tuning for SPDK and the NVMe/TCP initiator
  ([#14190](https://github.com/longhorn/longhorn/issues/14190)), plus fixes for
  interrupt mode, which lets SPDK stop burning a core when idle.
- Per-node overrides for v2 resource sizing
  ([#13844](https://github.com/longhorn/longhorn/issues/13844)).
- **RDMA (RoCEv2) transport, experimental**
  ([#13796](https://github.com/longhorn/longhorn/issues/13796)). This is the work I've
  been contributing. Pull requests are open across five repositories and still in
  review, so names and settings below may change before release.

All numbers in this post come from 1.14.0-dev builds with my RDMA branches applied.

## Test setup

I ran the same suite on two three-node clusters:

| | Cluster A | Cluster B |
|---|---|---|
| Servers | Ampere Altra (arm64) | x86 |
| OS / Kubernetes | SLES 16, RKE2 | SLES 15 SP7, RKE2 |
| Disks | Kioxia CM6 NVMe | Kioxia CM5 NVMe |
| Storage network | one 25 GbE RoCE port per node | 100 GbE ConnectX-4, lossless RoCEv2 (PFC + ECN) |

On both clusters, each test leg works like this:

1. Create a fresh 100 GiB v2 block volume with three replicas, one per node (cluster A
   also has a one-replica "remote" leg: a single replica on another node, which isolates
   the transport).
2. Precondition it with a full sequential write, so every read hits real data.
3. Run fio from a pod on the engine node, pinned away from SPDK's reactor cores, three
   times:
   - `seqread` / `seqwrite`: 1 MiB blocks, queue depth 32, 4 jobs.
   - `randread` / `randwrite`: 4 KiB blocks, queue depth 64, 4 jobs.
   - `latread` / `latwrite`: 4 KiB blocks, queue depth 1, 1 job. Each I/O waits for the
     previous one, so this measures round-trip latency.
4. Record disk byte counters on all three nodes and NIC counters on the engine node
   around every run.

Step 4 matters more than it looks. Counters prove which path each test took: every TCP
leg moved 0 bytes over RDMA, every RDMA leg moved 0 bytes over the kernel network stack,
and disk reads always matched or exceeded fio reads, so nothing came from cache.

In my RDMA work, only engine-to-replica traffic uses RDMA. Pods still attach to the
engine over local NVMe/TCP; an RDMA front end would be a later phase.

## Results on 25 GbE: bandwidth ties, latency doesn't

Cluster A, three replicas, mean of three runs:

| Test | TCP | RDMA | Change |
|---|--:|--:|--:|
| Sequential read | 4,288 MiB/s | 9,336 MiB/s | see below |
| Sequential write | 1,476 MiB/s | 1,446 MiB/s | tie |
| Random read | 212 kIOPS | 295 kIOPS | +39% |
| Random write | 137 kIOPS | 187 kIOPS | +36% |
| Read latency (QD1) | 199 µs | 123 µs | −38% |
| Write latency (QD1) | 157 µs | 72 µs | −54% |

And with one remote replica, where every I/O must cross the wire:

| Test | TCP | RDMA | Change |
|---|--:|--:|--:|
| Sequential read | 2,953 MiB/s | 2,908 MiB/s | tie |
| Sequential write | 2,739 MiB/s | 2,904 MiB/s | +6% |
| Random read | 220 kIOPS | 284 kIOPS | +29% |
| Random write | 280 kIOPS | 253 kIOPS | −10% |
| Read latency (QD1) | 196 µs | 140 µs | −29% |
| Write latency (QD1) | 144 µs | 81 µs | −44% |

### Why bandwidth ties

When I first saw TCP and RDMA tie on bandwidth, I suspected a bug in my branch. It was
the network. Raw `iperf3` over TCP reaches 24.7 Gb/s and raw `ib_write_bw` over RDMA
reaches 24.5 Gb/s: both are already at line rate. So:

- **One-replica sequential tests** cap at about 2.9 GiB/s, which is 25 Gb/s, on both
  transports.
- **Three-replica writes** cap at about 1.45 GiB/s, because the engine node sends every
  write to two remote replicas through the same single port.
- **Three-replica sequential read "doubling"** isn't a wire win. Disk counters show the
  RDMA leg read about 70% of its data from the engine node's local replica, while the
  TCP leg spread reads evenly across all three. Local reads never touch the network.

If your network is the bottleneck, NVMe/TCP on SPDK already uses all of it. In that
sense SPDK has closed the gap: you don't need RDMA hardware to get full bandwidth.

### Why latency doesn't tie

Queue-depth-1 tests are pure round trips, and that's where the kernel TCP stack costs
the most. Measured raw, a 4 KiB round trip takes about 105 µs over kernel TCP and about
15 µs over RDMA. RDMA moves data between registered memory and the NIC with no
socket, no copy and no kernel involvement on the data path. Longhorn's write path adds replication on top, but the gap
survives: **write latency drops by 44 to 54%**, and random IOPS rise about 30% when the
wire has headroom.

## Results on 100 GbE: wire headroom changes the picture

Cluster B, three replicas, mean of three runs:

| Test | TCP | RDMA | Change |
|---|--:|--:|--:|
| Sequential read | 4,216 MiB/s | 6,366 MiB/s | +51% |
| Sequential write | 2,378 MiB/s | 2,507 MiB/s | +5% |
| Random read | 259 kIOPS | 243 kIOPS | −6% |
| Random write | 197 kIOPS | 217 kIOPS | +10% |
| Read latency (QD1) | 149 µs | 134 µs | −10% |
| Write latency (QD1) | 125 µs | 57 µs | **−54%** |

With four times the bandwidth, TCP throughput rises too: random reads reach
259 kIOPS, and three-replica sequential writes climb about 60%. Write latency still halves with RDMA.

Two details explain the odd results:

- **RDMA sends local-replica traffic through the NIC as well.** During the
  preconditioning fill, RDMA transmitted 305 GiB (three replicas × 100 GiB) versus
  202 GiB for TCP (two remote replicas), because TCP keeps the local replica on kernel
  loopback. That hairpin spreads reads across all three replicas, which helps
  sequential reads (+51%) but adds NIC work.
- **Random read is the one test where RDMA trails** (−6%). My working theory is that
  the NVMe/TCP front end and the 8 SPDK reactor cores are the limit there, with the
  hairpin adding load. That's next on my list to profile.

## Trying RDMA yourself

Until the PRs merge you'd need images built from my branches, so treat this as a
preview. With them installed, enabling RDMA takes a StorageClass parameter:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-v2-rdma
provisioner: driver.longhorn.io
parameters:
  dataEngine: "v2"
  dataEngineTransport: "rdma"   # "tcp" is the default
  numberOfReplicas: "3"
```

You also need:

- A storage network that carries RoCEv2 between nodes. I use Longhorn's
  `storageNetwork` setting with a Multus network attached to the RoCE port.
- The `v2-data-engine-rdma-device-resource` setting, which tells instance managers
  which RDMA device resource to request.
- A lossless fabric for anything beyond a lab: PFC on the RoCE priority, plus ECN.

A volume's transport can change only while the volume is detached.

## Lessons learned the hard way

- **Benchmark the wire before the storage.** Five minutes with `iperf3` and
  `ib_write_bw` would have saved me a day of hunting a "bug" that was a 25 GbE ceiling.
- **Pin perftest to the NIC's NUMA node.** Unpinned, `ib_write_bw` on the Ampere nodes
  reported 1.28 Gb/s with huge `rx_discards_phy` counts. Under
  `taskset` on the NIC's node it ran at line rate. It also needs root for locked memory.
- **Check that PFC survives a reboot.** On my DPU-based NICs, PFC settings didn't
  persist: after a reboot every priority showed PFC off, and RoCE quietly ran lossy.
- **Watch for stripped RDMA libraries in custom images.** A recent change to Longhorn's
  instance-manager image removes build dependencies with `zypper remove --clean-deps`,
  which also strips `rdma-core`, `libibverbs` and `librdmacm` unless you install them
  explicitly.

## Which transport should you use?

- **Default to NVMe/TCP.** On SPDK it fills a 25 GbE link and needs no special NICs or
  switch configuration. With 1.14 planning reservations, throttling and delta rebuilds,
  v2 over TCP is shaping up as a strong default.
- **Choose RDMA when latency is the metric**: databases, VM boot disks, anything doing
  synchronous small writes. Halving write latency is a gain no amount of bandwidth buys.
- **Add bandwidth before RDMA if throughput is the metric.** On cluster A, each node's
  second, unused 25 GbE port would raise the ceiling more than switching transports would.

Next, I'll profile the random-read case on 100 GbE, and look at an RDMA front end so
pods can reach the engine without NVMe/TCP.
