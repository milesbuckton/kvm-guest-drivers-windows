# Building viogpu3d driver

This repository contains the kernel-mode part of the viogpu3d driver. The full driver package is built only when the user-mode driver DLLs are available in the directories pointed to by `MESA_PREFIX_x64` and, for 32-bit compatibility on 64-bit Windows, `MESA_PREFIX_x86`.

## Build mesa
These are general guidelines and may vary depending on the build environment and Mesa options used.

Now inside virtual machine with build tools installed create working directory, then inside it (this assumes use of Powershell):
1. Create mesa prefix dir `mkdir mesa_prefix` and set env `MESA_PREFIX_x64` to its path: `$env:MESA_PREFIX_x64="$PWD\mesa_prefix"`
2. Acquire [modified mesa source code](https://gitlab.freedesktop.org/miles.buckton/mesa/-/tree/main) (branch `main`) and then cd into it `cd mesa`
3. Create build directory `mkdir build && cd build`
4. Configure build `meson setup .. --prefix=$env:MESA_PREFIX_x64  -Dgallium-drivers=virgl -Dgallium-d3d10umd=true -Dgallium-wgl-dll-name=viogpu_wgl -Dgallium-d3d10-dll-name=viogpu_d3d10 -Dvulkan-drivers=virtio -Dzlib=disabled -Dc_std=c11`, build options explained:
  * `--prefix=$env:MESA_PREFIX_x64` set installation path to dir created in step 1
  * `-Dgallium-drivers=virgl` build only virgl driver
  * `-Dgallium-d3d10umd=true` build DirectX 10 user-mode driver (opengl one is build by default)
  * `-Dgallium-d3d10-dll-name=viogpu_d3d10` name of generated d3d10 dll to `viogpu_d3d10.dll`
  * `-Dgallium-wgl-dll-name=viogpu_wgl` name of generated wgl dll to `viogpu_wgl.dll`
  * `-Dvulkan-drivers=virtio` build Vulkan user-mode driver
  * `-Dzlib=disabled` disable ZLIB library
  * `-Dc_std=c11` use c11 standard
  * `-Db_vscrt=mt` may be used with MSVC/clang-cl to select the static Visual Studio CRT; it does not make MinGW runtime libraries static
5. Build and install (to mesa prefix): `ninja install`
6. (optional) Repeat step 1-5 to build x86 Mesa and set `MESA_PREFIX_x86` to that prefix. Keep the installed DLL names as `viogpu_wgl.dll` and `viogpu_d3d10.dll`; the driver package renames them while staging. For MinGW builds that should not depend on MinGW runtime DLLs, add `-Dc_link_args="-static -static-libgcc"` and `-Dcpp_link_args="-static -static-libgcc -static-libstdc++"`.

NOTE: Only mingw w64 clang is supported when building Vulkan driver

## Build driver
Now that Mesa is built and installed into `%MESA_PREFIX_x64%` and optionally `%MESA_PREFIX_x86%`, viogpu3d can be built. If `%MESA_PREFIX_x64%` is not set, the x64 viogpu3d build fails before packaging.
1. Acquire [drivers source code](https://github.com/milesbuckton/kvm-guest-drivers-windows) and cd into it `cd kvm-guest-drivers-windows`
2. Go to viogpu `cd viogpu`
3. (optional, but very useful) setup test code signning from visual studio
4. Call build `.\build_AllNoSdv.bat`

Built driver will be available at `kvm-guest-drivers-windows\viogpu\Install\Win10`.

## Windows 11 ARM64 (this fork)

ARM64 builds need `MESA_PREFIX_ARM64`, which must contain `bin\viogpu_d3d10.dll`
(see `viogpu3d.vcxproj`). Build the `Win11 Release|ARM64` configuration of
`viogpu3d.sln` instead of running `build_AllNoSdv.bat`:

```powershell
msbuild viogpu3d.sln /t:Build /p:Configuration="Win11 Release" /p:Platform=ARM64 /p:MESA_PREFIX_ARM64="$env:MESA_PREFIX_ARM64"
```

The package is written to `viogpu\Install\Win11\ARM64`. For the complete,
working recipe, see [`.github/workflows/build-arm64.yml`](../../.github/workflows/build-arm64.yml).
It covers the MSVC `x64_arm64` cross file, the Meson options, disabling the
`d3d10` test, and test signing. The workflow builds the Vulkan driver with
`-Dvulkan-drivers=virtio` and `/experimental:c11atomics`, then copies the
installed `vulkan_virtio.dll` to `libvulkan_virtio.dll`, the name the package
expects.

### ARM64X user-mode drivers (x64-emulated apps)

x64 apps on Windows 11 ARM64 run emulated as ARM64EC processes and cannot load
the native arm64 Mesa DLLs. The package can additionally carry ARM64X builds of
the D3D UMD, the WGL ICD and the Venus ICD:

1. Build Mesa a second time for ARM64EC (see the "Configure and build Mesa
   (ARM64EC)" step of the workflow): the same options plus `-Dllvm=disabled
   -Degl=disabled -Dgles1=disabled -Dgles2=disabled`, `cl /arm64EC`, the
   regular MSVC `lib\arm64` libraries (they serve ARM64EC once the "MSVC
   ARM64EC build tools" component is installed), `tools\arm64x\msvc_arm64ec_wrap.py` as
   linker/archiver (Meson always passes `/MACHINE:ARM64`), and the patches in
   `.github/patches/arm64ec`.
2. From an arm64 MSVC environment, assemble the ARM64X DLLs:

   ```powershell
   tools\arm64x\make_arm64x.ps1 -NativeDir "$env:MESA_PREFIX_ARM64\bin" -EcDir <dir with the arm64ec viogpu_d3d10.dll, viogpu_wgl.dll, libvulkan_virtio.dll> -OutDir mesa_arm64x
   ```

   This writes `viogpu_d3d10_arm64x.dll`, `viogpu_wgl_arm64x.dll` (pure
   forwarders), `libvulkan_virtio_arm64x.dll` (loader stub, `vk_arm64x_stub.c`)
   and the matching `*_arm64ec.dll` payloads.
3. Add `/p:MESA_ARM64X_DIR=<path to mesa_arm64x>` to the msbuild command.

When all six files are present, the package installs each `*_arm64x.dll` to
System32 under the usual name (`viogpu_d3d10.dll`, `viogpu_wgl.dll`,
`libvulkan_virtio.dll`) next to its `*_arm64.dll` and `*_arm64ec.dll` payloads;
registry entries and the ICD JSON are unchanged. The INF lines are selected by
the `;@NATIVE@` / `;@ARM64X@` tags in `viogpu3d_arm64*.inx`
(`tools\prepare_package_inx.ps1 -Arm64x`). Without `MESA_ARM64X_DIR`, or with
an incomplete set (a build warning), the native ARM64 package is built
unchanged. In CI both ARM64X steps are best effort and never block the native
package.
