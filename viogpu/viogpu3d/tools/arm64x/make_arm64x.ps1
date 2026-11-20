<#
.SYNOPSIS
  Assemble the ARM64X viogpu3d user-mode drivers from the arm64 and arm64ec
  Mesa builds.

.DESCRIPTION
  Windows 11 on ARM64 runs x64 applications under emulation as ARM64EC
  processes. They cannot load the native arm64 Mesa DLLs, so every user-mode
  DLL the OS or an x64 app loads by name ships as an ARM64X image whose two
  views lead to an arm64 and an arm64ec payload:

    viogpu_d3d10_arm64x.dll      pure ARM64X forwarder (installed as viogpu_d3d10.dll)
      native view -> viogpu_d3d10_arm64.dll     (Mesa arm64 build)
      EC view     -> viogpu_d3d10_arm64ec.dll   (Mesa arm64ec build)
    viogpu_wgl_arm64x.dll        pure ARM64X forwarder (installed as viogpu_wgl.dll)
      native view -> viogpu_wgl_arm64.dll
      EC view     -> viogpu_wgl_arm64ec.dll
    libvulkan_virtio_arm64x.dll  ARM64X loader stub (installed as libvulkan_virtio.dll)
      native view -> libvulkan_virtio_arm64.dll
      EC view     -> libvulkan_virtio_arm64ec.dll

  The forwarders follow osy's make-arm64x.bat, the Vulkan stub Kaede's
  make-arm64x-vk.bat (see vk_arm64x_stub.c for why it is not a forwarder).

  OutDir receives the six files the driver package needs on top of the
  native build: the three *_arm64x.dll front DLLs and the three *_arm64ec.dll
  payloads. The *_arm64.dll payloads are the native Mesa DLLs the package
  already stages. Run from an MSVC environment targeting arm64 (cl, link,
  lib and dumpbin on PATH; vcvarsall x64_arm64 or arm64).

.PARAMETER NativeDir
  Directory with the arm64 builds: viogpu_d3d10.dll, viogpu_wgl.dll and
  libvulkan_virtio.dll (the Mesa arm64 install's bin directory).

.PARAMETER EcDir
  Directory with the arm64ec builds under the same three names.

.PARAMETER OutDir
  Output directory (MESA_ARM64X_DIR for the viogpu3d build).
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$NativeDir,

  [Parameter(Mandatory = $true)]
  [string]$EcDir,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$MachineAmd64 = 0x8664
$MachineArm64 = 0xAA64

# Front DLL names, the payload names the INF installs next to them, and
# whether the front DLL is a forwarder (UMDs) or the Vulkan loader stub.
$Modules = @(
  @{ Name = 'viogpu_d3d10'; Kind = 'forwarder' },
  @{ Name = 'viogpu_wgl'; Kind = 'forwarder' },
  @{ Name = 'libvulkan_virtio'; Kind = 'vkstub' }
)
$VulkanIcdExports = @(
  'vk_icdGetInstanceProcAddr',
  'vk_icdGetPhysicalDeviceProcAddr',
  'vk_icdNegotiateLoaderICDInterfaceVersion'
)

function Get-PeInfo([string]$Path) {
  $b = [System.IO.File]::ReadAllBytes($Path)
  if ($b.Length -lt 64 -or [BitConverter]::ToUInt16($b, 0) -ne 0x5a4d) {
    throw "Not a PE image: $Path"
  }
  $pe = [BitConverter]::ToInt32($b, 60)
  if ($pe -lt 64 -or $pe -gt $b.Length - 264 -or
      [BitConverter]::ToUInt32($b, $pe) -ne 0x4550) {
    throw "Not a PE image: $Path"
  }
  $machine = [BitConverter]::ToUInt16($b, $pe + 4)
  $sectionCount = [BitConverter]::ToUInt16($b, $pe + 6)
  $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
  $characteristics = [BitConverter]::ToUInt16($b, $pe + 22)
  $opt = $pe + 24
  $magic = [BitConverter]::ToUInt16($b, $opt)
  $dllChars = 0
  $chpe = [uint64]0
  if ($magic -eq 0x20b) {
    $dllChars = [BitConverter]::ToUInt16($b, $opt + 70)
    # Data directory 10: load configuration. Its CHPEMetadataPointer (offset
    # 0xC8) is set for ARM64EC and ARM64X images only.
    $lcRva = [BitConverter]::ToUInt32($b, $opt + 112 + 10 * 8)
    if ($lcRva) {
      $sections = $opt + $optSize
      for ($i = 0; $i -lt $sectionCount; $i++) {
        $s = $sections + 40 * $i
        $va = [BitConverter]::ToUInt32($b, $s + 12)
        $vsize = [Math]::Max([BitConverter]::ToUInt32($b, $s + 8), [BitConverter]::ToUInt32($b, $s + 16))
        if ($lcRva -ge $va -and ([uint64]$lcRva - $va) -lt $vsize) {
          $off = [uint64][BitConverter]::ToUInt32($b, $s + 20) + ([uint64]$lcRva - $va)
          if ($off + 0xD0 -le [uint64]$b.Length -and [BitConverter]::ToUInt32($b, [int]$off) -ge 0xD0) {
            $chpe = [BitConverter]::ToUInt64($b, [int]$off + 0xC8)
          }
          break
        }
      }
    }
  }
  [pscustomobject]@{
    Machine  = [int]$machine
    IsDll    = ($characteristics -band 0x2000) -ne 0
    Pe32Plus = $magic -eq 0x20b
    GuardCF  = ($dllChars -band 0x4000) -ne 0
    HasChpe  = $chpe -ne 0
  }
}

function Assert-Payload([string]$Path, [string]$Kind) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing $Kind payload: $Path"
  }
  $info = Get-PeInfo $Path
  if (-not $info.IsDll -or -not $info.Pe32Plus) {
    throw "$Kind payload is not a 64-bit DLL: $Path"
  }
  switch ($Kind) {
    'arm64' {
      if ($info.Machine -ne $MachineArm64 -or $info.HasChpe) {
        throw ("Expected a plain ARM64 DLL (machine AA64, no CHPE metadata), got machine {0:X4} CHPE={1}: {2}" -f $info.Machine, $info.HasChpe, $Path)
      }
    }
    'arm64ec' {
      # An ARM64EC image reports the x64 machine type and carries CHPE
      # metadata; a plain x64 build would not.
      if ($info.Machine -ne $MachineAmd64 -or -not $info.HasChpe) {
        throw ("Expected an ARM64EC DLL (machine 8664 with CHPE metadata), got machine {0:X4} CHPE={1}: {2}" -f $info.Machine, $info.HasChpe, $Path)
      }
    }
  }
  if (-not $info.GuardCF) {
    Write-Warning "$Path is not a Control Flow Guard image; strict-CFG processes will not load it."
  }
  Write-Host ("  {0}: machine {1:X4}, CHPE={2}, CFG={3}" -f $Path, $info.Machine, $info.HasChpe, $info.GuardCF)
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
  Write-Host "> $Exe $($Arguments -join ' ')"
  & $Exe @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

function Get-DllExports([string]$Path) {
  $lines = & dumpbin /nologo /exports $Path
  if ($LASTEXITCODE -ne 0) { throw "dumpbin /exports failed for $Path" }
  $names = New-Object System.Collections.Generic.List[string]
  $inTable = $false
  foreach ($line in $lines) {
    if (-not $inTable) {
      if ($line -match '^\s*ordinal\s+hint\s+RVA\s+name\s*$') { $inTable = $true }
      continue
    }
    if ($line -match '^\s*Summary\s*$') { break }
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+(?:[0-9A-Fa-f]{8}\s+)?(\S+)') {
      $name = $Matches[1]
      if ($name.StartsWith('[')) {
        throw "Ordinal-only export in ${Path}: $line"
      }
      $names.Add($name)
    }
  }
  if ($names.Count -eq 0) { throw "No exports found in $Path" }
  return ,@($names | Sort-Object -CaseSensitive -Unique)
}

# The MSVC lib\arm64 directories serve both views once the ARM64EC build
# tools are installed, so the arm64 environment links ARM64X as is.
function Invoke-Arm64xLink([string[]]$Arguments) {
  Write-Host "> link $($Arguments -join ' ')"
  & link @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "link /machine:arm64x failed with exit code $LASTEXITCODE" }
}

function Assert-Arm64x([string]$Path) {
  $info = Get-PeInfo $Path
  $headers = (& dumpbin /nologo /headers $Path) -join "`n"
  $machineLine = ($headers -split "`n" | Where-Object { $_ -match 'machine \(' } | Select-Object -First 1)
  Write-Host "  $Path : $machineLine"
  if ($info.Machine -ne $MachineArm64 -or -not ($info.HasChpe -or $headers -match 'ARM64X')) {
    throw ("Not an ARM64X image (machine {0:X4}, CHPE={1}): {2}" -f $info.Machine, $info.HasChpe, $Path)
  }
  if (-not $info.GuardCF) {
    Write-Warning "$Path is not a Control Flow Guard image; strict-CFG processes will not load it."
  }
}

foreach ($tool in @('cl', 'link', 'lib', 'dumpbin')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool not found on PATH; run from an MSVC arm64 developer environment."
  }
}

$NativeDir = (Resolve-Path -LiteralPath $NativeDir).Path
$EcDir = (Resolve-Path -LiteralPath $EcDir).Path
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
if (-not $WorkDir) {
  $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('viogpu-arm64x-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$stubSource = Join-Path $PSScriptRoot 'vk_arm64x_stub.c'
if (-not (Test-Path -LiteralPath $stubSource -PathType Leaf)) {
  throw "Missing Vulkan stub source: $stubSource"
}

# Never leave a partial set behind: the package build only enables ARM64X
# when all six outputs exist.
foreach ($m in $Modules) {
  foreach ($suffix in @('_arm64x.dll', '_arm64ec.dll')) {
    Remove-Item -LiteralPath (Join-Path $OutDir ($m.Name + $suffix)) -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'Checking payloads...'
foreach ($m in $Modules) {
  Assert-Payload (Join-Path $NativeDir "$($m.Name).dll") 'arm64'
  Assert-Payload (Join-Path $EcDir "$($m.Name).dll") 'arm64ec'
}

$staged = @()
foreach ($m in $Modules) {
  $name = $m.Name
  $nativeDll = Join-Path $NativeDir "$name.dll"
  $ecDll = Join-Path $EcDir "$name.dll"
  $dir = Join-Path $WorkDir $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $front = Join-Path $dir "$name.dll"
  Write-Host ""
  Write-Host "=== $name ($($m.Kind)) ==="

  $nativeExports = Get-DllExports $nativeDll
  $ecExports = Get-DllExports $ecDll
  $diff = @(Compare-Object -CaseSensitive -ReferenceObject $nativeExports -DifferenceObject $ecExports)
  if ($diff.Count -ne 0) {
    $detail = ($diff | ForEach-Object { "$($_.InputObject) ($(if ($_.SideIndicator -eq '<=') { 'arm64 only' } else { 'arm64ec only' }))" }) -join ', '
    throw "arm64 and arm64ec builds of $name export different symbols: $detail"
  }
  Write-Host "$($nativeExports.Count) export(s): $($nativeExports -join ', ')"

  if ($m.Kind -eq 'forwarder') {
    $natDef = Join-Path $dir 'forward_native.def'
    $ecDef = Join-Path $dir 'forward_ec.def'
    $natLines = @('EXPORTS') + @($nativeExports | ForEach-Object { "    $_ = ${name}_arm64.$_" })
    $ecLines = @('EXPORTS') + @($ecExports | ForEach-Object { "    $_ = ${name}_arm64ec.$_" })
    [System.IO.File]::WriteAllLines($natDef, [string[]]$natLines, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllLines($ecDef, [string[]]$ecLines, (New-Object System.Text.UTF8Encoding($false)))

    $empty = Join-Path $dir 'empty.c'
    [System.IO.File]::WriteAllText($empty, "void viogpu_arm64x_forwarder_stub(void) {}`r`n")
    $objNative = Join-Path $dir 'empty_arm64.obj'
    $objEc = Join-Path $dir 'empty_ec.obj'
    $libNative = Join-Path $dir 'forward_native.lib'
    $libEc = Join-Path $dir 'forward_ec.lib'

    # /guard:cf: strict-CFG processes refuse DLLs without it, and the
    # forwarder is the file the D3D runtime / opengl32 load first.
    Invoke-Tool 'cl' @('/nologo', '/c', '/guard:cf', "/Fo$objNative", $empty)
    Invoke-Tool 'cl' @('/nologo', '/c', '/guard:cf', '/arm64EC', "/Fo$objEc", $empty)
    Invoke-Tool 'lib' @('/nologo', '/machine:arm64', "/def:$natDef", "/out:$libNative")
    Invoke-Tool 'lib' @('/nologo', '/machine:x64', "/def:$ecDef", "/out:$libEc")
    Invoke-Arm64xLink @('/nologo', '/dll', '/noentry', '/guard:cf', '/machine:arm64x',
      "/defArm64Native:$natDef", "/def:$ecDef", $objNative, $objEc,
      "/out:$front", $libNative, $libEc)
  } else {
    foreach ($export in $VulkanIcdExports) {
      if ($nativeExports -notcontains $export) {
        throw "$nativeDll does not export $export"
      }
    }
    $extra = @($nativeExports | Where-Object { $VulkanIcdExports -notcontains $_ -and $_ -ne 'vk_icdEnumerateAdapterPhysicalDevices' })
    if ($extra.Count -ne 0) {
      Write-Warning "$name exports symbols the ARM64X stub does not provide: $($extra -join ', ')"
    }
    $objNative = Join-Path $dir 'stub_arm64.obj'
    $objEc = Join-Path $dir 'stub_ec.obj'
    Invoke-Tool 'cl' @('/nologo', '/c', '/O2', '/MT', '/W3', '/guard:cf', "/Fo$objNative", $stubSource)
    Invoke-Tool 'cl' @('/nologo', '/c', '/O2', '/MT', '/W3', '/guard:cf', '/arm64EC', "/Fo$objEc", $stubSource)
    Invoke-Arm64xLink @('/nologo', '/dll', '/guard:cf', '/machine:arm64x',
      "/out:$front", $objNative, $objEc)
  }

  Assert-Arm64x $front
  $frontExports = Get-DllExports $front
  Write-Host "front DLL native-view exports: $($frontExports -join ', ')"
  & dumpbin /nologo /exports $front | Out-Host

  $staged += @{ Source = $front; Destination = Join-Path $OutDir "${name}_arm64x.dll" }
  $staged += @{ Source = $ecDll; Destination = Join-Path $OutDir "${name}_arm64ec.dll" }
}

foreach ($f in $staged) {
  Copy-Item -LiteralPath $f.Source -Destination $f.Destination -Force
}
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "ARM64X user-mode drivers written to ${OutDir}:"
Get-ChildItem -LiteralPath $OutDir -Filter '*.dll' | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }
