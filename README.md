# hybrid-gpu-lab

Build and tear down, repeatably, a set of KVM virtual machines that behave like a small multi-node GPU cluster in which **NVIDIA and AMD GPUs sit in separate servers**, as they do in production: three control-plane VMs and two worker VMs, each worker owning one physical GPU through PCI passthrough.

It emulates the hybrid cluster that [Open Inference Fabric](https://github.com/manmohanbrahma/open-inference-fabric) installs on, from a single server with both GPUs. It is a separate project: it builds machines, not Kubernetes.

| VM | Role | vCPU | Memory | Disk | GPU |
| --- | --- | --- | --- | --- | --- |
| cp1, cp2, cp3 | control plane | 24 | 48 GiB | 500 GiB | none |
| gpu-amd | worker | 48 | 96 GiB | 800 GiB | AMD Radeon PRO W7900 |
| gpu-nvidia | worker | 48 | 96 GiB | 800 GiB | NVIDIA RTX A6000 |

All VMs have one network interface on the same private subnet (libvirt NAT, `192.168.120.0/24` by default) with fixed addresses, ready to form a cluster. The OS is the Ubuntu 26.04 LTS cloud image, pinned to a dated release and checked against its SHA-256 checksum.

## Requirements

- Ubuntu 26.04 host with AMD-V or VT-x and the IOMMU enabled in the BIOS
- Each GPU in an IOMMU group of its own (with its HDMI audio function); `./lab create` checks this
- The GPUs not in use by the host (no display on them)
- Memory and CPU for the VMs (336 GiB and 168 vCPUs with the default sizes), disk space for thin disks

## Use

```bash
cp lab.conf.example lab.conf      # set LAB_STORAGE, the GPU PCI addresses, sizes
./lab plan                        # what create would do; changes nothing
sudo ./lab create                 # host setup on first use, then the network and the VMs
sudo ./lab status
sudo ./lab ssh gpu-nvidia         # or: ssh oif@192.168.120.22 with the admin key
sudo ./lab destroy                # VMs, disks and network gone; host setup and image kept
sudo ./lab recreate               # destroy, then create
sudo ./lab host-clean             # destroy, then undo the host setup
```

## SSH keys

`create` asks once for the **admin's public key** (default: the invoking user's key, or the keys in their `authorized_keys`) and where to put it: **all** VMs, **control**-plane VMs only, or **none**. The answer is kept for later creates; set `LAB_ADMIN_KEY` and `LAB_ADMIN_KEY_ON` in `lab.conf` to skip the question. The lab also puts its own key (`/var/lib/hybrid-lab/ssh/id_ed25519`) on every VM for `./lab ssh` and its readiness checks. The VM user `oif` has passwordless sudo; password login is off.

## What it changes on the host, and how it is undone

| Change | Undone by |
| --- | --- |
| Packages qemu-system-x86, qemu-utils, libvirt, virtinst, ovmf, driverctl, genisoimage (only those missing are installed, and recorded) | `host-clean` removes the recorded ones |
| The listed GPU functions bound to `vfio-pci` with `driverctl` (kept across reboots) | `host-clean` (driverctl unset-override); reboot for a clean driver start |
| libvirt network and VMs (`hl-*`), disks in `LAB_STORAGE` | `destroy` |
| `/var/lib/hybrid-lab` (state, lab key, seeds), base image, `/var/log/hybrid-lab.log` | `host-clean` (the log stays) |

## How the GPUs are passed through

The guest uses UEFI firmware named explicitly (`OVMF_CODE_4M.fd`, secure boot off so the NVIDIA driver loads; on an EPYC host libvirt would otherwise pick the AMD SEV build, which AppArmor refuses), a q35 machine and the host CPU model. Each GPU worker gets every function of its card as a host device, and the firmware gets a 256 GiB 64-bit PCI window (`LAB_MMIO64_MB`) so the cards' 48 GB memory windows fit. Drivers are not installed in the VMs: the cluster installer does that per node.

## Tests

`tests/run.sh` runs shellcheck and renders `./lab plan` from the example settings: well-formed network XML, valid cloud-init with the right keys per role, one `virt-install` per VM with both functions of each GPU.

## License

Apache-2.0. NVIDIA, AMD, Radeon and Ubuntu are trademarks of their owners.
