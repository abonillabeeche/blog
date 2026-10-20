---
title: "Windows golden images on SUSE Virtualization: sysprep answer files explained"
date: 2026-10-15
draft: false
tags: ["harvester", "suse-virtualization", "windows", "sysprep", "cloudbase-init", "kubevirt"]
summary: "How to turn a Windows Server ISO into a reusable SUSE Virtualization image with an unattended install, VMDP drivers, Cloudbase-Init and sysprep: which answer file to use, how to build from the UI or kubectl, and how to deploy VMs from the result."
images: ["og.jpg"]
# canonicalURL: ""
---

## TL;DR

You need three things:

1. **A Windows Server ISO**, uploaded under **Images**. Server 2022 and 2025 are
   tested, and evaluation ISOs work.
2. **A ready-made answer file** for your version:
   [Server 2022](https://github.com/abonillabeeche/harvester-windows-cloudbase/blob/main/kubectl/Autounattend-selfcontained-2022.xml)
   or
   [Server 2025](https://github.com/abonillabeeche/harvester-windows-cloudbase/blob/main/kubectl/Autounattend-selfcontained-2025.xml).
3. **SUSE Virtualization 1.9**, whose VM create form has a **Windows Unattended &
   Sysprep** section once the VM's OS type is Windows.

Then:

1. Create a VM from the `windows-iso-medium-template` template and attach your ISO.
2. Set the root disk to 36 GiB.
3. In **Advanced Options**, set **OS Type** to **Windows**. That reveals the
   **Windows Unattended & Sysprep Configuration** section: choose **Create New**,
   paste the answer file and create the VM.
4. About 20 minutes later the VM turns itself off. Its disk is your golden image:
   export it to an image and create Windows VMs from it with a cloud-config.

SUSE Virtualization 1.9.1 adds a `windows-image-template` that simplifies that last
step. Everything below explains what happens under the hood and the other ways to
build.

## How it all fits together

A Linux cloud image on SUSE Virtualization (Harvester) personalizes itself on first
boot: you pick the image, add a cloud-config, and the VM comes up with its own
hostname, users and disk size. My
[harvester-windows-cloudbase](https://github.com/abonillabeeche/harvester-windows-cloudbase)
project gives Windows the same experience. You start from a stock Windows ISO, and an
unattended build produces a sysprepped image that any number of VMs can clone.

This post explains each sysprep file in the repo, which one to pick, and the full
path from ISO to running VM.

## What the image contains

- **SUSE VMDP** (Virtual Machine Driver Pack): signed virtio drivers for disk and
  network, plus the QEMU guest agent.
- **Cloudbase-Init**, the Windows counterpart of cloud-init. It reads the cloud-config
  that SUSE Virtualization attaches to each VM and applies the hostname, users,
  passwords and `runcmd` on first boot.
- **A generalized install.** `sysprep /generalize` removes the machine identity, so
  every clone gets its own.
- **Automatic disk growth.** Cloudbase-Init's `ExtendVolumesPlugin` grows `C:` to the
  VM's disk, so one small image serves any disk size.

## How the build works

A build VM boots with four devices: the Windows ISO, the VMDP driver CD, a sysprep CD
holding the answer file, and an empty root disk. From there everything is unattended:

1. **`windowsPE` pass.** Windows Setup finds `autounattend.xml` on the sysprep CD,
   loads the virtio disk drivers from the VMDP CD, partitions the root disk and
   installs the edition named in the answer file.
2. **`specialize` and `oobeSystem` passes.** Setup configures the machine, logs on as
   Administrator and runs the answer file's `FirstLogonCommands`.
3. **Bootstrap.** `FirstLogonCommands` starts `bootstrap.ps1`, which freezes Windows
   Update, the Store and Edge Update, installs VMDP and Cloudbase-Init, deletes build
   files and zeroes free space. It logs to `C:\winbuild.log`.
4. **Generalize.** The script runs `sysprep /generalize /oobe /shutdown` with
   Cloudbase-Init's own unattend file, which re-arms Cloudbase-Init for the next boot.
   The VM powers off after about 20 minutes.

That powered-off root disk is the golden image. You register it as a SUSE
Virtualization image and delete the build VM.

KubeVirt's
[`sysprep` volume](https://kubevirt.io/user-guide/user_workloads/startup_scripts/#sysprep)
provides the sysprep CD: it turns a Kubernetes Secret into an ISO, and every key in the Secret becomes a file
on that ISO.

## Pick your answer file

All files live in the repo's [`kubectl/`](https://github.com/abonillabeeche/harvester-windows-cloudbase/tree/main/kubectl)
folder. There are two layouts:

- **Two-file**: a base answer file plus `bootstrap.ps1` as two keys in the Secret.
  `FirstLogonCommands` searches the CD drives for the script. Use this with `kubectl`
  or Terraform.
- **Self-contained**: a single `autounattend.xml` with `bootstrap.ps1` embedded in it
  as base64. SUSE Virtualization 1.9's UI writes exactly one key, so this is the
  layout for the UI.

| File | Layout | Windows | Status |
|---|---|---|---|
| `Autounattend-2022.xml` | two-file (with `bootstrap.ps1`) | Server 2022 | tested |
| `Autounattend-2025.xml` | two-file (with `bootstrap.ps1`) | Server 2025 | tested |
| `Autounattend-w11.xml` | two-file (with `bootstrap.ps1`) | Windows 11 | experimental |
| `Autounattend-selfcontained-2022.xml` | self-contained | Server 2022 | tested |
| `Autounattend-selfcontained-2025.xml` | self-contained | Server 2025 | tested |
| `Autounattend-selfcontained-w11.xml` | self-contained | Windows 11 | experimental |
| `Autounattend-selfcontained-coriolis-2022.xml` | self-contained | Server 2022 | tested |
| `Autounattend-selfcontained-coriolis-2025.xml` | self-contained | Server 2025 | tested |

Two more files complete the set:

- **`bootstrap.ps1`** is the first-logon script. It's the same for every version.
- **`build-answerfile.py`** builds a self-contained file from a base answer file and
  `bootstrap.ps1`. You need it only after editing either one, or to change the edition.

Windows 11 is experimental because `sysprep` hangs on `Sysprep_Clean_Validate_Opk` in
about half of my runs; the install itself completes. Use the `coriolis` files to build a
worker image for [Coriolis](https://cloudbase.it/coriolis/) migrations into SUSE
Virtualization: they add a WinRM HTTPS listener and make Cloudbase-Init create the user
that Coriolis sends. A real VMware-to-SUSE Virtualization migration passed its worker
login with these images. Use the plain files for everything else.

### Match the edition to your ISO

Each answer file names the Windows edition to install, for example
`Windows Server 2022 SERVERSTANDARD`. Setup compares that string byte for byte with
the images in the ISO's `sources\install.wim`. If it doesn't match, Setup shows the
edition picker and waits for a click that never comes, and the build VM just keeps
running.

Retail and evaluation ISOs use the same names, so the defaults work for both. For
Datacenter, generate a new file:

```console
$ cd kubectl/
$ ./build-answerfile.py -w 2022 --edition 'Windows Server 2022 SERVERDATACENTER'
wrote kubectl/Autounattend-selfcontained-2022.xml (flavor: standard)
  bootstrap.ps1: 19837 bytes -> 26452 base64 chars in 38 chunks
  longest CommandLine: 749 chars (limit 1024)
```

To list the editions in your own ISO, run `wiminfo sources/install.wim` on Linux or
`dism /Get-WimInfo /WimFile:D:\sources\install.wim` on Windows. Server Core isn't
supported, because `bootstrap.ps1` assumes the Desktop Experience.

Watch the last line of that output. Windows rejects the answer file if any
`FirstLogonCommands` command line is longer than 1024 characters, so the generator
splits the embedded script into chunks and checks the limit.

## Before you start

- SUSE Virtualization 1.9 for the UI path; 1.8 works with `kubectl` or Terraform.
- A Windows Server 2022 or 2025 ISO uploaded under **Images**.
- A StorageClass you trust for VM disks. `harvester-longhorn` exists on every cluster.

Find your ISO's short name and its own StorageClass:

```bash
kubectl get virtualmachineimage -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,DISPLAY:.spec.displayName,SC:.status.storageClassName'
```

SUSE Virtualization gives every image a dedicated StorageClass, and the build VM's CD-ROM
volume has to use that class; with any other class, the ISO clone comes up empty and
the VM stops at "No Bootable Device".

## Build from the UI

SUSE Virtualization 1.9 adds a **Windows Unattended & Sysprep** section to the VM
create form.

1. Go to **Virtual Machines → Create**, and choose the
   `windows-iso-medium-template` template. It ships with 1.9 and already has the boot
   CD-ROM, the VMDP driver CD, a virtio root disk and the Hyper-V enlightenments
   described in
   [Windows VMs on SUSE Virtualization](/posts/windows-vms-hyperv-enlightenments/).
2. On the CD-ROM disk, set **Image** to your Windows ISO.
3. Shrink the root disk to **36 GiB**. An exported image keeps the build disk's
   size, and `C:` grows when a VM is deployed, so build small.
4. Under **Advanced Options**, set **OS Type** to **Windows**. Only then does the
   **Windows Unattended & Sysprep Configuration** section appear.
5. Choose **Create New** and paste the whole content of
   `Autounattend-selfcontained-<version>.xml`.
6. Click **Create**, then wait for the VM to stop by itself.

## Build with kubectl

With the two-file layout, `bootstrap.ps1` stays readable in the Secret:

```bash
cd kubectl/
kubectl create secret generic winbuild-unattend \
  --from-file=autounattend.xml=Autounattend-2022.xml \
  --from-file=bootstrap.ps1=bootstrap.ps1

# Edit winbuild-vm.yaml first: ISO image, ISO StorageClass, root disk StorageClass
kubectl apply -f winbuild-vm.yaml
kubectl wait --for=jsonpath='{.status.printableStatus}'=Stopped \
  vm/winbuild --timeout=45m
```

For automation, the repo's `terraform/` folder runs the same build with one `terraform apply` and a
`windows_version` variable (`2022`, `2025` or `w11`).

## Capture the image

Register the stopped root disk as an image:

```yaml
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: win2022
  namespace: default
spec:
  displayName: win2022
  backend: cdi
  sourceType: export-from-volume
  pvcName: winbuild-rootdisk
  pvcNamespace: default
  targetStorageClassName: harvester-longhorn
```

Two details:

- **Always set `targetStorageClassName`.** Without it, the image silently lands on
  the cluster's default StorageClass.
- **Keep `displayName` short and without spaces.** SUSE Virtualization 1.9 copies it
  into a label, and labels can't contain spaces.

This image keeps the full 36 GiB virtual size. For a smaller image, the repo's
[shrink Job](https://github.com/abonillabeeche/harvester-windows-cloudbase/tree/main/shrink-export)
shrinks `C:` to its minimum and uploads a compact qcow2 instead. On Server 2022 that
gave a 12.3 GiB image that takes 9.27 GiB on disk.

Then delete the build VM, its disks and the `winbuild-unattend` Secret.

## Deploy a VM from the image

Create a VM from the new image and give it a cloud-config:

```yaml
#cloud-config
set_hostname: web01
users:
  - name: tux
    passwd: MyStr0ngPass!
    primary_group: Administrators
runcmd:
  - powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
```

On first boot, Cloudbase-Init creates the user, runs the commands and extends `C:` to
the VM's disk. Hostname changes take effect after the next reboot, because the image
doesn't let Cloudbase-Init reboot the VM during first-boot setup (that caused boot
loops).

If you create the cloud-config Secret yourself rather than through the UI, give it
`type: secret` and the label `harvesterhci.io/cloud-init-template: harvester`.
Cloudbase-Init doesn't care, but the UI's **Cloud Config** tab only shows Secrets that
have both.

SUSE Virtualization 1.9.1 adds a `windows-image-template` for exactly this case: a
single root disk from a prepared image, a virtio network card and a cloud-init disk.
It's in the 1.9.1 release candidates now.

## Why the build freezes updates

`sysprep /generalize` fails with error `0x80073cf2` if any Microsoft Store app is
installed for one user but not provisioned for all users. A fresh install is
consistent, but the build VM has internet access. Windows Update, the Store and Edge
Update can each update an app for the logged-on Administrator mid-build, and that
breaks it.

`bootstrap.ps1` therefore disables all three for the build, and the Server 2022 answer
file already stops Edge Update and Windows Update in the `specialize` pass, before
anyone logs on. A `SetupComplete.cmd` script that Windows runs once on every clone
turns them back on, so deployed VMs still get updates.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "No Bootable Device" | ISO volume used a generic StorageClass; use the image's own class |
| Build VM keeps running at the edition picker | Edition string doesn't match `install.wim`; regenerate with `--edition` |
| `Error code: 0xD000A000 - 0x40031` (Server 2025) | Setup didn't load the virtio-scsi driver; use the repo's answer files, which point at the exact VMDP folder |
| "The answer file is invalid" in `oobeSystem` | A `FirstLogonCommands` line is over 1024 characters; regenerate with `build-answerfile.py` |
| `0x80073cf2` in `setuperr.log` | App updated mid-build; rebuild from a fresh root disk with the current files |
| Deployed VM reboots in a loop | Old image without `allow_reboot=false` in Cloudbase-Init's config; rebuild |
| Cloud-config not shown in the UI | Secret lacks `type: secret` or the `cloud-init-template` label |

Windows caches the answer file on the root disk, so after changing it, delete the root
disk and build again; restarting the VM reuses the old copy. See the repo's
[troubleshooting guide](https://github.com/abonillabeeche/harvester-windows-cloudbase/blob/main/docs/troubleshooting.md)
for each case in detail.

## Takeaways

- For the UI, paste `Autounattend-selfcontained-<version>.xml`; for `kubectl`, use the
  base file plus `bootstrap.ps1`.
- Match the edition string to your ISO, and put the ISO volume on the image's own
  StorageClass.
- Build on a 36 GiB disk, set `targetStorageClassName` on export, and keep image names
  short.
- Deploy with a cloud-config, and let Cloudbase-Init handle the hostname, users and
  disk size.
