# Windows Node Image Builder

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7, running as Administrator.
- Hyper-V enabled, its management tools installed, and a working `Default Switch`
  (or change `switch_name` in the var-file).
- The [Windows ADK Deployment Tools](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
  The build script adds the standard `amd64` and `x86` Oscdimg locations to its
  process PATH. Packer creates the unattended-install CD automatically; AnyBurn
  and manually mounting an answer ISO are not needed.
- Packer, and Azure CLI if publishing. With Chocolatey already installed:

```powershell
choco install packer azure-cli -y
```

The self-hosted GitHub Actions runner needs the same prerequisites and an
appropriately privileged service account. Install Chocolatey on the runner once
if the workflow should install missing Packer/Azure CLI packages. The workflow
does not display UAC prompts or interactively enable Windows features.

## Build locally

Use the shared entry point rather than invoking `packer build` directly. It
initializes plugins, validates the effective configuration, builds the VM, and
verifies the exported disk. A failed native command stops subsequent stages.

```powershell
git clone https://github.com/bobsira/windows-node-image-builder.git
Set-Location .\windows-node-image-builder

$result = .\scripts\Build-WindowsImage.ps1
$result.DiskPath
```

Optional version overrides work for both validation and the build:

```powershell
$result = .\scripts\Build-WindowsImage.ps1 `
    -WindowsVersion '2022' `
    -KubernetesVersion 'v1.37.0' `
    -ContainerdVersion '1.7.25'
```

Omitted or blank version overrides use `windows.auto.pkrvars.hcl`, not the latest
release. Use `-VarFile` for another var-file. The base VM name defaults to
`hybrid-minikube-windows-server`; `-VmName` overrides that base (and the var-file's
`vm_name`), but the unique build suffix is always appended.

To initialize and validate without creating a VM, taking the host build lock, or
publishing:

```powershell
.\scripts\Build-WindowsImage.ps1 -ValidateOnly
```

The template sends the DVD boot key immediately and retries it ten times, rather
than relying on one delayed keystroke. Packer requires `boot_wait = "-1s"` to
disable the delay; `"0s"` selects its default ten-second wait. Installation then
uses `setup\Autounattend.xml`.

## Build identity and isolation

| Resource | Naming |
|----------|--------|
| GitHub build ID | `<run-id>-<run-attempt>` |
| Local build ID | UTC timestamp plus a random suffix |
| Temporary VM | `hybrid-minikube-windows-server-<build-id>` |
| Run directory | `%ProgramData%\WindowsNodeImageBuilder\builds\<build-id>` |
| Export directory | `<run-directory>\output` |
| Logs and result | `<run-directory>\logs` |
| Published disk | `hybrid-minikube-windows-server.vhdx` (or `.vhd` for an actual VHD) |

`-ArtifactRoot` overrides the parent directory of all run directories. The default
is outside the checkout so a later GitHub checkout cannot erase failed-run
evidence. `-BuildId` allows an explicit unique ID; reusing an existing directory
fails rather than overwriting it. Builds do not use `-force`.

Only the current run's exact export directory is searched. It must contain
exactly one nonempty, readable, detached, independent VHD/VHDX with a matching
extension. `logs\result.json` records the build status, VM name, exact disk path,
format, size, and retained VM details when available.

Both local and CI builds hold the same exclusive file lock at
`%ProgramData%\WindowsNodeImageBuilder\build.lock`. A competing build fails
explicitly. The lock is released when its owner exits; the file remaining on disk
does not mean it is still locked. Do not delete the lock file to bypass it.
Elevated Administrators and the runner's SYSTEM account must have access to this
shared directory; do not relocate the lock per user or checkout.

The entry point also rejects an already-running `packer build` for this template,
including older builds that did not acquire the lock. It never terminates them.
All new builds must use the shared entry point: raw Packer commands can bypass
the host lock, even though the template now requires a build ID and output path.

## Publication

Local builds do not publish automatically. To publish a successful result, set
`AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_KEY`, and `AZURE_CONTAINER_NAME` in the
process environment using your normal secret-management mechanism, then run:

```powershell
.\scripts\Publish-WindowsImage.ps1 `
    -ResultPath (Join-Path $result.LogDirectory 'result.json')
```

Publication rechecks the successful build result and its disk. The canonical
Azure blob name is independent of the temporary VM name. Local exported files
and VM configuration are not renamed; create or import the final VM with the
name `hybrid-minikube-windows-server`. Changing a `.vhdx` extension to `.vhd` is
not a disk-format conversion.

Publishers coordinate through a 60-second Azure lease on the canonical blob,
renewed every 15 seconds during upload. This includes publishers on other hosts
and local invocations. A competing publisher fails explicitly rather than
waiting. The upload carries the lease ID, so a lost lease cannot commit over
another publisher. Cleanup releases ownership; after a crashed publisher stops
renewing, the finite lease expires. Do not break an active lease.

An absent destination is conditionally created as an empty block blob before
lease acquisition. A failed first publication can leave that zero-byte blob;
it is not a completed image. An existing image is never replaced by an empty
placeholder. Both `.vhdx` and `.vhd` are published as **block-blob file artifacts**,
not Azure VM page-blob disks.

Credentials are supplied through environment variables, not logged command-line
arguments. `publication.json`, `publication.log`, and `publication-lease.log`
are saved alongside the build result. The successful publication manifest and
verified nonempty disk distinguish a completed image from an initial placeholder.

## GitHub Actions

The workflow calls the same build and publication scripts. Its optional version
inputs retain the var-file defaults when left blank. A branch-independent
concurrency group prevents this repository's workflows from overlapping without
cancelling the active build. The host lock also covers local builds, and the
storage lease protects publication across hosts.

Publication runs only after a successful build. The workflow always attempts to
upload the run's logs as `packer-log-<run-id>-<run-attempt>`, including publication
diagnostics when that stage ran. If a failure happens before the build entry
point can create its log directory, inspect the workflow step's own log.

## Diagnosing failures and cleanup

Packer runs with `-on-error=abort`. The failed VM and its associated files are
preserved, and a new run cannot reuse their unique identity. Logs include
`console.log` (native stdout/stderr), `packer-debug.log`, `host.log`, and
`result.json`. Validation-only results are marked `Validated`, never `Succeeded`,
and cannot be published.

Before retrying, inspect the error and any active workflow/Packer process. For
boot failures, inspect the VM console and DVD boot prompt. For provisioning
failures, check the exact retained VM's IP, WinRM listener on TCP 5985, and guest
events at the failure time. Two controllers acting on the same VM can cause
download file locks and competing restarts.

After collecting diagnostics and confirming no build is using the resource,
remove only the failed VM identified by `RetainedVM.Id` and the exact associated
paths recorded in its result. VM disks may still be in Packer's temporary build
directory rather than the export directory. Do not delete other VMs, broad
`output*` paths, the shared build root, or an active lock. Logs can contain
sensitive machine details; keep their filesystem and artifact access restricted.

## Script checks

Run both test suites with one command (Pester 4.9.0 must be installed):

```powershell
.\scripts\Test-WindowsImage.ps1
```

The runner imports the required Pester version and finds the tests relative to
its own location, so it also works when invoked by absolute path from another
directory. It prints the test results and returns exit code `0` on success or `1`
on test failure, missing tests, or a runner error. To run it in a fresh Windows
PowerShell process:

```powershell
powershell.exe -NoProfile -File .\scripts\Test-WindowsImage.ps1
```

Check Packer formatting separately:

```powershell
packer fmt -check .\windows.json.pkr.hcl
```

The script tests use mocks for provisioning and Azure operations; they do not
start a VM or publish an image.

### Default password

| OS | Username | Password |
|----|----------|----------|
| Windows | Administrator | password |
