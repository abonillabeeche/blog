---
title: "Longhorn v2 on SPDK: TCP catches up, RDMA still wins on latency (part 1)"
date: 2026-10-12
draft: false
tags: ["longhorn", "spdk", "rdma", "nvme-of", "kubernetes", "storage", "benchmark"]
summary: "Two snapshots of Longhorn's SPDK-based v2 engine on the same three Ampere nodes: 1.12 with my RDMA patches, then 1.14 development builds with a newer SPDK. NVMe/TCP got about 7× lower write latency and now fills a 25 GbE link. RDMA still halves write latency."
# canonicalURL: ""
---

Longhorn's v2 data engine replaces the original iSCSI-and-sparse-file data path with
[SPDK](https://spdk.io/): a user-space, polling NVMe stack. Replicas talk to each other
and to the volume engine over NVMe over Fabrics (NVMe-oF), and today that fabric is
NVMe/TCP. Since August I've been building a second transport, RDMA over Converged
Ethernet (RoCEv2), and benchmarking both along the way.

Two rounds of results, two months apart on the same hardware, tell a clear story:

- **NVMe/TCP caught up on bandwidth.** Between Longhorn 1.12 and the 1.14 development
  builds, TCP write latency fell from about 1.1 ms to 157 µs and sequential reads rose
  from 243 MiB/s to 4,288 MiB/s. On 25 GbE, TCP now fills the wire.
- **RDMA still wins on latency.** Queue-depth-1 writes take about half as long over
  RDMA, and random I/O runs about 30% faster.

This is part 1. RDMA support isn't merged yet, and I'll publish final numbers once it
lands.

## Why Longhorn 1.14 matters for v2

Longhorn 1.14 is still in development, with a target date of January 2027. Its
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
- A newer SPDK: development builds moved from v25.09 (Longhorn 1.12) to v26.05.
- **RDMA (RoCEv2) transport, experimental**
  ([#13796](https://github.com/longhorn/longhorn/issues/13796)). This is the work I've
  been contributing. Pull requests are open across five repositories and still in
  review, so names and settings below may change before release.

## Test setup

![Rack with three 2U Ampere Altra servers with 24 NVMe bays each, above Dell PowerEdge servers](ampere-lab-rack.jpg#portrait)

*Three Ampere Altra nodes (top, 24 NVMe bays each) ran both rounds. Dell PowerEdge
servers below host other lab clusters.*

Both rounds ran on the same three-node cluster:

- 3× Ampere Altra (arm64) servers.
- Kioxia CM6 NVMe drives, one per node for Longhorn.
- One 25 GbE RoCEv2 port per node for storage traffic (NVIDIA ConnectX-6).
- SPDK reactors pinned to 8 cores (`data-engine-cpu-mask=0xff`), plus a 2-core run in
  round 1. fio runs pinned to other cores.
- A v2 block volume with three replicas, one per node, and the engine on the node
  running fio.

Each round compares TCP and RDMA back to back with the same fio suite:

- `seqread` / `seqwrite`: 1 MiB blocks, queue depth 32.
- `randread` / `randwrite`: 4 KiB blocks, queue depth 64.
- `latread` / `latwrite`: 4 KiB blocks, queue depth 1. Each I/O waits for the previous
  one, so this measures round-trip latency.

Read and write tests run 20 seconds after a 3-second ramp; latency tests run 15 seconds.

In my RDMA work, only engine-to-replica traffic uses RDMA. Pods still attach to the
engine over local NVMe/TCP; an RDMA front end would be a later phase.

## Round 1 (August): Longhorn 1.12 with RDMA patches

Stack: Longhorn 1.12.1 with my RDMA patches, SPDK v25.09, Ubuntu 24.04 (kernel 6.8).
For this round I ran a matched matrix: each leg got a fresh 100 GiB volume on a freshly
wiped disk, and I verified through SPDK that all three replica connections used the
intended transport. I ran it twice, first with SPDK on 2 cores and then on 8.

Results with the SPDK aio disk driver (the same driver round 2 uses):

| Test (three replicas) | TCP, 2 cores | RDMA, 2 cores | TCP, 8 cores | RDMA, 8 cores |
|---|--:|--:|--:|--:|
| Write latency (QD1) | 1,476 µs | 511 µs | 1,145 µs | 272 µs |
| Read latency (QD1) | 447 µs | 297 µs | 1,201 µs | 332 µs |
| Sequential write | 105 MiB/s | 191 MiB/s | 77 MiB/s | 329 MiB/s |
| Sequential read | 196 MiB/s | 488 MiB/s | 243 MiB/s | 612 MiB/s |
| Random read | 30.9 kIOPS | 50.7 kIOPS | 47.7 kIOPS | 57.8 kIOPS |
| Random write | 1.8 kIOPS | 3.6 kIOPS | 5.8 kIOPS | 11.6 kIOPS |

Two things stand out:

- **On 1.12, TCP was the bottleneck everywhere.** RDMA led on every test, by 2.5× on
  sequential reads and about 4× on write latency.
- **More cores widened RDMA's lead.** Going from 2 to 8 cores took RDMA's sequential
  write advantage from 1.8× to 4.3×, and its write-latency advantage from 2.9× to
  4.2×. Extra cores helped both transports, but RDMA turned them into throughput far
  more effectively. Random reads went the other way: their gap shrank from 1.6× to
  1.2× once the reactors had room to spare.

One result I can't explain yet: TCP's queue-depth-1 read latency got worse with 8 cores
(447 µs → 1,201 µs). With the native NVMe driver it moved the other way, so treat
round 1 latency numbers as rough.

I repeated the matrix with SPDK's native NVMe driver as well. Absolute numbers moved,
but the transport conclusions didn't, so the disk driver isn't what separates TCP from
RDMA here.

## Round 2 (October): Longhorn 1.14 development builds

Stack: Longhorn 1.14.0-dev with my RDMA branches, SPDK v26.05, SLES 16, SPDK aio disk
driver. Each volume was 100 GiB, preconditioned with a full sequential write, and each
test ran three times.

| Test (three replicas) | TCP | RDMA | RDMA advantage |
|---|--:|--:|--:|
| Write latency (QD1) | 157 µs | 72 µs | 2.2× lower |
| Read latency (QD1) | 199 µs | 123 µs | 1.6× lower |
| Sequential write | 1,476 MiB/s | 1,446 MiB/s | tie |
| Sequential read | 4,288 MiB/s | 9,336 MiB/s | 2.2× |
| Random read | 212 kIOPS | 295 kIOPS | +39% |
| Random write | 137 kIOPS | 187 kIOPS | +36% |

### What changed between rounds

Comparing the 8-core aio results, TCP got dramatically faster from round 1 to round 2:

- Write latency: 1,145 µs → 157 µs (about 7× lower).
- Random read: 47.7 kIOPS → 212 kIOPS (about 4.4×).
- Sequential read: 243 MiB/s → 4,288 MiB/s (about 18×).

RDMA improved too, with write latency falling from 272 µs to 72 µs. RDMA's lead shrank
from 4× to 2× on write latency and disappeared on sequential write, where both
transports now fill the wire.

**One caveat:** this is a before/after on the same hardware, not a controlled
experiment. Besides the Longhorn and SPDK versions, the operating system changed
(Ubuntu 24.04 → SLES 16), and round 1 volumes weren't preconditioned, so round 1
writes also paid for first-write allocation in SPDK's thin volumes. I can't credit the
whole TCP improvement to SPDK alone; part 2 will use one fixed stack.

## Reading the round 2 results

### Sequential write ties because the wire is full

Raw `iperf3` over TCP reaches 24.7 Gb/s on this network, and raw `ib_write_bw` over
RDMA reaches 24.5 Gb/s. Both are at line rate. With three replicas, the engine node
sends every write to two remote replicas through one port, which caps writes near
1.45 GiB/s for either transport. With a single remote replica, both transports top
out near 2.9 GiB/s, which is 25 Gb/s.

Where bandwidth is the bottleneck, NVMe/TCP on SPDK now uses all of it. That's how
far TCP has come since 1.12.

### Sequential read shows RDMA's CPU advantage

RDMA reads 2.2× faster, and disk counters on all three nodes explain why. During one
23-second run:

- **From the two remote replicas**, both transports read about 65 GiB (about
  2.8 GiB/s). That's the 25 GbE ceiling again, so remote reads tie.
- **From the local replica**, TCP read 39.6 GiB (about 1.7 GiB/s) and RDMA read
  147.9 GiB (about 6.4 GiB/s), which is **3.7× faster**.

Network bandwidth can't explain that difference; CPU can. Over TCP, SPDK's reactor cores
spend cycles on socket calls, data copies and checksums for every I/O. RDMA moves data
between registered memory and the NIC without the kernel, which frees those cores for
storage work. When the wire isn't the bottleneck, that CPU cost becomes the limit for
TCP.

### Latency: still RDMA's to lose

Queue-depth-1 tests are pure round trips. Measured raw, a 4 KiB round trip takes about
105 µs over kernel TCP and about 15 µs over RDMA. Longhorn adds replication on top,
but the gap survives every round: write latency over RDMA is about half of TCP's.

## A second opinion on 100 GbE

In October I also ran round 2's suite on a lab cluster with 100 GbE ConnectX-4 NICs,
a lossless RoCEv2 fabric (PFC and ECN), Kioxia CM5 drives and SLES 15 SP7:

| Test (three replicas) | TCP | RDMA | Change |
|---|--:|--:|--:|
| Write latency (QD1) | 125 µs | 57 µs | −54% |
| Read latency (QD1) | 149 µs | 134 µs | −10% |
| Sequential write | 2,378 MiB/s | 2,507 MiB/s | +5% |
| Sequential read | 4,216 MiB/s | 6,366 MiB/s | +51% |
| Random read | 259 kIOPS | 243 kIOPS | −6% |
| Random write | 197 kIOPS | 217 kIOPS | +10% |

With four times the bandwidth, TCP's throughput rises too, and write latency still
halves with RDMA. On this cluster RDMA also sends local-replica traffic out through
the NIC and back. That spreads reads across all three replicas but adds NIC work, and
it may explain why random reads trail by 6%. I'll profile that case in part 2.

## Trying RDMA yourself

Until the pull requests merge you'd need images built from my branches, so treat this
as a preview. With them installed, RDMA is a StorageClass parameter:

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
- Spare cores. SPDK's RDMA transport polls continuously and has no interrupt mode, so
  every core in the mask shows 100% busy even when idle.

A volume's transport can change only while the volume is detached.

## Lessons learned the hard way

- **Benchmark the wire before the storage.** When TCP and RDMA first tied on
  bandwidth, I spent a day hunting a bug that turned out to be the 25 GbE ceiling.
  Five minutes with `iperf3` and `ib_write_bw` would have shown it.
- **Count bytes at the disks and NICs.** Disk and NIC counters around every run proved
  which path each test took, and they exposed the local-replica effect behind the
  sequential read result.
- **Pin perftest to the NIC's NUMA node.** Unpinned, `ib_write_bw` on the Ampere nodes
  reported 1.28 Gb/s with huge `rx_discards_phy` counts. Under `taskset` on the NIC's
  node it ran at line rate. It also needs root for locked memory.
- **Check that PFC survives a reboot.** On my DPU-based NICs, PFC settings didn't
  persist: after a reboot every priority showed PFC off, and RoCE quietly ran lossy.
- **Watch for stripped RDMA libraries in custom images.** A recent change to Longhorn's
  instance-manager image removes build dependencies with `zypper remove --clean-deps`,
  which also strips `rdma-core`, `libibverbs` and `librdmacm` unless you install them
  explicitly.

## Which transport should you use today?

- **NVMe/TCP is now a strong default.** On the 1.14 development builds it fills a
  25 GbE link with no special NICs or switch configuration, and it supports interrupt
  mode for idle efficiency.
- **Choose RDMA when latency or CPU matters**: databases, VM boot disks, anything doing
  synchronous small writes, or nodes where storage competes with workloads for CPU.
- **Add bandwidth before RDMA if throughput is the only metric.** On my cluster, each
  node's second, unused 25 GbE port would raise the ceiling more than switching
  transports would.

## To be continued

Part 2 will come once RDMA support merges, or reaches general availability, in an
official Longhorn release. I'll rerun the same suite on one fixed stack (release
images, one OS, one disk driver) so the TCP and RDMA comparison isolates the transport
alone. I also plan to:

- repeat the 2-core versus 8-core comparison, to see whether RDMA still scales better
  with CPU on the newer SPDK;
- profile random reads on 100 GbE;
- look at an RDMA front end, so pods can reach a remote engine without NVMe/TCP.
