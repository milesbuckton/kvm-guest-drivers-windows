# KVM/QEMU Windows guest drivers (virtio-win) #

[![Build viogpu3d ARM64 Driver](https://github.com/milesbuckton/kvm-guest-drivers-windows/actions/workflows/build-arm64.yml/badge.svg)](https://github.com/milesbuckton/kvm-guest-drivers-windows/actions/workflows/build-arm64.yml)
[![clang-format check](https://github.com/milesbuckton/kvm-guest-drivers-windows/actions/workflows/clang-format.yml/badge.svg)](https://github.com/milesbuckton/kvm-guest-drivers-windows/actions/workflows/clang-format.yml)

This repository is a personal fork of
[virtio-win/kvm-guest-drivers-windows][upstream], which contains KVM/QEMU
Windows guest drivers for both paravirtual and emulated hardware. The
upstream code builds and ships as part of the virtio-win RPM on Fedora and
Red Hat Enterprise Linux, and the binaries are also available in the form of
distribution-neutral ISO and VFD images. If all you want is use virtio-win in
your Windows virtual machines, go to the
[Fedora virtIO-win documentation][fedora-virtio]
for information on obtaining the binaries.

On top of upstream, this fork carries **`viogpu3d`**, a 3D-accelerated WDDM
driver for the VirtIO GPU, and a GitHub Actions workflow that builds it for
**Windows 11 ARM64** guests on Apple Silicon hosts. See [viogpu3d](#viogpu3d).
These additions are not part of the official Fedora or Red Hat virtio-win
packages and are not supported by those projects.

If you'd like to build virtio-win from sources, clone this repo and
follow the instructions in [Building the Drivers][wiki-building].
Note that the drivers you build will be either unsigned or test-signed
with Tools/VirtIOTestCert.cer, which means that Windows will not load
them by default. See [Microsoft's driver signing page][ms-signing]
for more information on test-signing.

If you want to build cross-signed binaries (like the ones that ship in
the Fedora RPM), you'll need your own code-signing certificate.
Cross-signed drivers can be used on all versions of Windows except for
the latest Windows 10 with secure boot enabled. However, systems with
cross-signed drivers will not receive Microsoft support.

If you want to produce Microsoft-signed binaries (fully supported,
like the ones that ship in the Red Hat Enterprise Linux RPM), you'll
need to submit the drivers to Microsoft along with a set of test
results (so called WHQL process). If you decide to WHQL the drivers,
make sure to base them on commit eb2996de or newer, since the GPL
license used prior to this commit is not compatible with WHQL.
Additionally, we ask that you make a change to the Hardware IDs so
that your drivers will *not* match devices exposed by the upstream
versions of KVM/QEMU. This is especially important if you plan to
distribute the drivers with Windows Update, see the
[Microsoft publishing restrictions][ms-publishing] for more details.

## viogpu3d

The VirtIO GPU (`PCI\VEN_1AF4&DEV_1050`) has two kernel-mode drivers in
[`viogpu/`](viogpu). Install one or the other:

- **`viogpudo`** is upstream's WDDM *display-only* driver. It handles
  modesetting and scanout, with no 3D acceleration.
- **`viogpu3d`** is a full WDDM driver with 3D acceleration. It carries
  graphics work to the host GPU over virgl and Venus, without dedicating a
  physical GPU to the guest. Its user-mode drivers come from a
  [Mesa fork][mesa]: a Direct3D 10/11 UMD (`viogpu_d3d10.dll`), an OpenGL ICD
  (`viogpu_wgl.dll`) and the Venus Vulkan ICD (`libvulkan_virtio.dll`).

Both packages also ship `vgpusrv.exe` and `viogpuap.exe`, a user-mode service
and agent that apply resolution changes inside the interactive session.

**Status:** alpha. It may crash or hang the guest; only use it in disposable
test VMs.

### Components

| Component | Repository | Purpose |
| --- | --- | --- |
| Windows KMD | This repository | WDDM device, memory, scheduling and display integration |
| Mesa UMD | [miles.buckton/mesa, `main`][mesa] | Direct3D, Vulkan and OpenGL user-mode drivers |
| QEMU (Apple Silicon) | [milesbuckton/qemu][qemu] | Cocoa GL scanout and blob support under HVF |
| Guest setup | [windows-desktop-vm][wdvm] | Windows 11 ARM64 guests on Apple Silicon using this package |

On Linux/KVM hosts with x64 guests, see [Yttrium][yttrium] for the matching
QEMU and virglrenderer builds.

### Windows 11 ARM64 package

[`.github/workflows/build-arm64.yml`](.github/workflows/build-arm64.yml)
builds and test-signs the ARM64 driver package:

* **How it is built:** MSVC cross-compiles Mesa from a pinned commit of
  [Mesa `main`][mesa] on the `windows-2022` runner, using the `x64_arm64`
  toolchain plus the WDK. The workflow then builds `viogpu3d.sln` with the
  `Win11 Release|ARM64` configuration and signs the result with
  `build\VirtIOTestCert.pfx`. To build against a different Mesa repository or
  commit, change `DEFAULT_MESA_REPO` and `DEFAULT_MESA_REF` in the workflow.
* **ARM64X:** Windows on ARM runs native ARM64 processes and, under emulation,
  x64 ones, and no plain ARM64 DLL serves both. Mesa is therefore built a
  second time for arm64ec, and each user-mode driver ships behind an ARM64X
  front DLL that keeps the plain name, so x64-emulated applications can load
  it too. This step is best effort: if it fails, the package ships native
  ARM64 user-mode drivers only, and the release notes say so. 32-bit (x86)
  applications are not covered; they would need a separate x86 Mesa build.
* **Releases:** published only by a manual run of the workflow
  (`workflow_dispatch`) on `master`. Each release is tagged
  `viogpu3d-arm64-<yyyyMMdd.HHmmss>` (UTC), lists the Mesa commit it was built
  from, and has two assets: `viogpu3d-arm64-win11.zip` and its `.sha256`.
  Only the newest release is kept: once it is published, older releases and
  their tags are deleted. Stable download link:
  `https://github.com/milesbuckton/kvm-guest-drivers-windows/releases/latest/download/viogpu3d-arm64-win11.zip`.
  Pull requests to `master` only build the package and upload it as a
  workflow artifact; pushes don't trigger the workflow.
* **Apple Silicon:** Apple Silicon hosts use 16 KiB memory pages, and HVF maps
  guest memory in whole host pages. `viogpu3d` places mappable blobs at
  16 KiB-aligned offsets in the shared memory window and creates mappable host
  blobs with 16 KiB-rounded sizes (`VIOGPU_HOST_PAGE_ALIGN` in
  `viogpu/viogpu3d/viogpu_allocation.h`). Hosts with 64 KiB pages are not
  handled yet.

For local builds, including x64 and Mesa itself, see
[`viogpu/viogpu3d/BUILDING.md`](viogpu/viogpu3d/BUILDING.md).

### Installing

The package is test-signed, not Microsoft-signed. The certificate's private
key (`build\VirtIOTestCert.pfx`) is public, so anything signed with it is
trusted by the guest.

1. Disable Secure Boot in the VM's UEFI settings, enable test signing and
   reboot:

   ```bat
   bcdedit /set testsigning on
   ```

2. Trust `VirtIOTestCert.cer` (included in the package) in **both** machine
   stores:

   ```bat
   certutil -addstore Root VirtIOTestCert.cer
   certutil -addstore TrustedPublisher VirtIOTestCert.cer
   ```

3. Disable hibernation, which also turns off Fast Startup. Fast Startup can
   restore stale graphics-driver state after the host has started fresh,
   causing resource-allocation failures on the next boot:

   ```bat
   powercfg /hibernate off
   ```

4. Install the package from its directory, then reboot:

   ```bat
   pnputil /add-driver viogpu3d.inf /install
   ```

   If an older `viogpu3d` is installed, uninstall it first and delete its
   driver package.

The [Vulkan Runtime Installer](https://vulkan.lunarg.com/sdk/home) provides
the `vulkan-1.dll` loader and `vulkaninfo`.

### Host setup

Vulkan/Venus needs host-shared memory and a VirtIO GPU with blob resources
and Venus enabled, for example on an x64 Linux/KVM host:

```sh
-object memory-backend-memfd,id=mem1,size=8G,share=on \
-machine q35,memory-backend=mem1 \
-device virtio-vga-gl,hostmem=4G,blob=on,venus=on
```

On Apple Silicon, use the [QEMU fork][qemu] (`virtio-gpu-gl-pci` on the
`virt` machine); [windows-desktop-vm][wdvm] has a complete configuration.

### Troubleshooting

- **An x64-emulated app fails to load the UMD on ARM64** (for example,
  `ERROR_BAD_EXE_FORMAT`): the package holds native ARM64 user-mode drivers
  only. Check the release notes for the ARM64X line.
- **`pnputil` reports that the certificate chain is not trusted:** the test
  certificate must be in both the `Root` and `TrustedPublisher` machine
  stores.
- **The display freezes and QEMU logs `ctrl 0x208, error 0x1200`:** the host
  rejected a blob mapping; on Apple Silicon, make sure the guest runs a driver
  with 16 KiB blob alignment and the host runs the [QEMU fork][qemu].

## Licensing

This fork retains the upstream copyright and BSD-3-Clause notices.
`viogpu3d` changes from Yttrium are additionally covered by MPL-2.0 where
marked in the source files. Individual file headers are authoritative.

## Contributing

This fork does not accept external issues or pull requests; see
[contributing.md](contributing.md). Forks are welcome. Upstream driver changes
belong in [virtio-win/kvm-guest-drivers-windows][upstream].

## Credits

- [virtio-win/kvm-guest-drivers-windows][upstream]: the drivers this fork is
  based on, including the original `viogpu3d` driver by Max R
  ([PR #943](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/943)).
- [Yttrium][yttrium] by arehnman: the Direct3D/Venus `viogpu3d` work, Mesa
  user-mode drivers and host stack this fork started from.
- [utmapp/viogpu-wddm, `neptune`][neptune] by osy, with contributions from
  Kaede and lurenJBD: many driver fixes and the ARM64X user-mode driver
  packaging are ported from it.

[upstream]:https://github.com/virtio-win/kvm-guest-drivers-windows
[yttrium]:https://github.com/arehnman/yttrium-virtio-gpu
[neptune]:https://github.com/utmapp/viogpu-wddm/tree/neptune
[mesa]:https://gitlab.freedesktop.org/miles.buckton/mesa/-/tree/main
[qemu]:https://gitlab.com/milesbuckton/qemu
[wdvm]:https://github.com/milesbuckton/windows-desktop-vm
[fedora-virtio]:https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/index.html
[wiki-building]:https://virtio-win.github.io/Development/Building-the-drivers-using-Windows-11-24H2-EWDK
[ms-signing]:https://docs.microsoft.com/en-us/windows-hardware/drivers/install/installing-test-signed-driver-packages
[ms-publishing]:https://docs.microsoft.com/en-us/windows-hardware/drivers/dashboard/publishing-restrictions
