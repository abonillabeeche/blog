---
title: "Harvester CLI: I've taken over the project, and v0.5.0 supports SUSE Virtualization 1.9"
date: 2026-10-18
draft: false
tags: ["harvester", "suse-virtualization", "cli", "kubevirt", "gitops", "open-source"]
summary: "Harvester CLI is a kubectl-style tool for creating and managing VMs on SUSE Virtualization. After the original repository went quiet, I took over the project: three feature releases later, it supports 1.9, has an image catalog, prints GitOps-ready YAML, and installs with Homebrew."
images: ["og.jpg"]
# canonicalURL: ""
---

[Harvester CLI](https://github.com/abonillabeeche/harvester-cli) is a command-line tool
for SUSE Virtualization (Harvester) in the spirit of Multipass or k3d: one short command
creates a VM, migrates it, or opens a shell in it, without writing KubeVirt YAML by
hand.

**I've taken over the project.** Mohamed Belgaied Hassine created it in 2021 and maintained
it for nearly four years, but its last commit landed in March 2025, against a Harvester release that
has since moved on. In May 2026 I picked it up, moved it to
[abonillabeeche/harvester-cli](https://github.com/abonillabeeche/harvester-cli), and
I've shipped three feature releases since. Thank you, Mohamed, for building it; the
design held up well enough that most of my work has been adding to it rather than
rewriting it.

Here's what it looks like against my three-node retail-store lab cluster:

```console
$ harvester vm list
STATE     NAME            NODE      CPU       RAM       IP Address
Stopped   bb-vm-hq                  1         1Gi       
Stopped   prod-web-vm               1         1Gi       
Stopped   stretch-hq-vm             1         1Gi       
Running   vlan-infra      gr6-3     1         12Gi      192.0.2.31
Stopped   windows-rd                1         16Gi      

$ harvester host list
NAME      STATUS    ROLES                       AGE       CPU(cores)   CPU%      MEM USE    MEM%      MEM TOTAL
gr6-1     Ready     etcd,master,control-plane   930d      4553m        30%       49.9 GiB   80%       62.2 GiB
gr6-2     Ready     etcd                        930d      243m         2%        4.9 GiB    17%       28.3 GiB
gr6-3     Ready     etcd,master,control-plane   930d      1662m        11%       30.3 GiB   48%       62.2 GiB
```

## Install

```bash
brew install abonillabeeche/tap/harvester
```

On Linux without Homebrew, use the install script, which picks the right binary for
your OS and architecture:

```bash
curl -fsSL https://raw.githubusercontent.com/abonillabeeche/harvester-cli/main/install.sh | sh
```

Windows binaries are on the
[releases page](https://github.com/abonillabeeche/harvester-cli/releases/latest).

## Connect to a cluster

The CLI reads a kubeconfig from `~/.harvester/config`, from `HARVESTER_CONFIG`, or from
`--harvester-config`. If Rancher manages your cluster, it can fetch one for you:

```bash
harvester login https://<rancher-url> -t <rancher-api-token>
harvester get-config <harvester-cluster-name>     # saved to ~/.harvester/config
```

## What it does

```bash
# VMs
harvester vm create --cpus 2 --memory 4Gi --vm-image-id default/ubuntu-noble \
  --network default/vlan1 --ssh-keyname default/mykey my-vm
harvester vm create --template ubuntu-base:1 --count 3 test-vm
harvester vm migrate --node node-2 my-vm
harvester shell --ssh-user ubuntu my-vm

# Images, volumes, networks, hosts
harvester image create --source https://example.com/os.qcow2 my-image
harvester volume create --sc longhorn --size 20Gi my-data
harvester network list          # VLANs, including trunk ranges
harvester host list             # live CPU and memory from the metrics API
```

## What's new since the takeover

### v0.3: a modern base and real releases

- Updated to current Harvester, KubeVirt and Kubernetes libraries.
- New `network`, `volume` and `host` commands.
- **`--dry-run` on every `create` command:** prints the Kubernetes YAML instead of
  applying it.
- Release pipeline with GoReleaser: macOS, Linux and Windows binaries, a Homebrew tap,
  and an install script.

### v0.4: an image catalog

Finding the right cloud image URL for each distribution is tedious, so the CLI now ships
a curated catalog of cloud-init-ready Linux images: Fedora, CentOS Stream, Debian,
AlmaLinux, Rocky Linux, Ubuntu and openSUSE.

```bash
harvester image catalog list fedora
harvester image catalog create --storage-class longhorn opensuse-leap/16.0
harvester image catalog            # interactive picker
```

Because the catalog is embedded in the binary, it works offline, and `catalog init` can point
it at an internal mirror for air-gapped sites.

```console
$ harvester image catalog list opensuse-leap
Images for openSUSE Leap (opensuse-leap):

VERSION   BUILD     SHORT NAME           URL
16.0      latest    openSUSE Leap 16.0   https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2
15.6      latest    openSUSE Leap 15.6   https://download.opensuse.org/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2
15.5      latest    openSUSE Leap 15.5   https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-Cloud.qcow2
15.4      latest    openSUSE Leap 15.4   https://download.opensuse.org/distribution/leap/15.4/appliances/openSUSE-Leap-15.4-Minimal-VM.x86_64-OpenStack-Cloud.qcow2
```

### v0.5: SUSE Virtualization 1.9

- **CDI image backend:** `image create --backend cdi` places images on third-party CSI
  storage such as Ceph RBD or Longhorn v2. Without the flag, the CLI infers the backend
  from the StorageClass.
- **OVA import:** `import --source-cluster-type ova` pulls OVA files from an HTTP server,
  alongside the existing VMware and OpenStack sources.
- **Delete commands** for images and volumes. `volume delete` refuses a volume that a VM
  still uses unless you pass `--force`.
- **A long list of fixes,** including some that had bitten real users:
  - `--ssh-keyname` is now written into cloud-init; VMs used to boot with no way to log
    in.
  - A flag after the VM name is now rejected instead of silently ignored, so
    `harvester vm create my-vm --dry-run` no longer creates the VM for real.
  - A bare `--memory 4` is caught as 4 bytes up front, instead of failing much later with
    a confusing error.

```console
$ harvester vm create --dry-run -m 4 demo-vm
time="2026-10-19T22:40:26-04:00" level=fatal msg="invalid --memory \"4\", a bare number is read as bytes -- use a unit, such as 4Gi"
```
  - `volume list-storageclass` flags a default StorageClass set only through the
    deprecated beta annotation, which Harvester ignores.

```console
$ harvester volume list-storageclass
NAME                                      DEFAULT                             PROVISIONER             RECLAIM POLICY   BINDING MODE   ALLOW EXPANSION
ceph-rbd                                                                      rbd.csi.ceph.com        Delete           Immediate      true
harvester-longhorn                        (beta only, Harvester ignores it)   driver.longhorn.io      Delete           Immediate      true
longhorn                                                                      driver.longhorn.io      Delete           Immediate      true
netapp-iscsi                                                                  csi.trident.netapp.io   Delete           Immediate      true
netapp-nvme                                                                   csi.trident.netapp.io   Delete           Immediate      true
```

I tested every command in v0.5.0 against three live 1.9 clusters, covering Ceph RBD,
Longhorn v1 and Longhorn v2.

## GitOps with `--dry-run`

`--dry-run` turns the CLI into a manifest generator. Write the YAML to files, commit
them, and let Fleet or Argo CD apply them:

```bash
mkdir -p manifests
harvester volume create --dry-run --sc longhorn --size 50Gi -n prod db-vol > manifests/db-vol.yaml
harvester image create  --dry-run --source https://example.com/os.qcow2 prod-os > manifests/image.yaml
harvester vm create     --dry-run --vm-image-id default/prod-os \
  --network default/vlan1 --cpus 4 --memory 8Gi db-01 > manifests/db-01.yaml
```

Here's the start of what `vm create --dry-run` prints:

```console
$ harvester vm create --dry-run --vm-image-id default/image-gw648 \
    --network default/vlan1 --cpus 2 --memory 4Gi --disk-size 20Gi demo-vm
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
    annotations:
        harvesterhci.io/volumeClaimTemplates: '[{"metadata":{"name":"demo-vm-disk-0-zxw2m","annotations":{"harvesterhci.io/imageId":"default/image-gw648"}},"spec":{"accessModes":["ReadWriteMany"],"resources":{"requests":{"storage":"20Gi"}},"volumeMode":"Block","storageClassName":"longhorn-image-gw648"}}]'
        networks.harvesterhci.io/ips: '[]'
    labels:
        harvesterhci.io/creator: harvester
        harvesterhci.io/vmName: demo-vm
        harvesterhci.io/vmNamePrefix: demo-vm
    name: demo-vm
    namespace: default
spec:
    runStrategy: Always
    template:
        metadata:
            annotations:
                harvesterhci.io/diskNames: '["demo-vm-disk-0-zxw2m"]'
                harvesterhci.io/sshNames: '["abonilla"]'
            labels:
                harvesterhci.io/creator: harvester
                harvesterhci.io/vmName: demo-vm
                harvesterhci.io/vmNamePrefix: demo-vm
        spec:
            affinity:
                podAntiAffinity:
                    preferredDuringSchedulingIgnoredDuringExecution:
                        - podAffinityTerm:
                            labelSelector:
                                matchLabels:
                                    harvesterhci.io/vmNamePrefix: demo-vm
                            topologyKey: kubernetes.io/hostname
                          weight: 1
            domain:
                cpu:
                    cores: 2
                    sockets: 1
                    threads: 1
    # ... devices, networks, volumes and cloud-init follow
```

Each generated VM includes everything SUSE Virtualization expects, such as the
volume-claim-template annotation that ties the disk to its image, which is the part
people most often get wrong by hand.

## Get involved

Now that the project is active again, I review issues and pull requests. If something is
missing or broken for your cluster,
[open an issue](https://github.com/abonillabeeche/harvester-cli/issues) or send a pull
request.
