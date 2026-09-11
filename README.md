# Windows Node Image Builder

## Prerequisites

- Make sure the Hyper-V role is enabled
- Install the Windows Assessment and Deployment Kit (32-bit version). <https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install#download-the-adk-for-windows-11-version-22h2>
- Add the following location to the system PATH environment variable: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg

### Run the following steps in PowerShell as Administrator

1. Clone the repo

```powershell
git clone https://github.com/bobsira/windows-node-image-builder.git
```

1. Change the current directory to `windows-node-image-builder`:

```powershell
cd windows-node-image-builder
```

1. Install packer using the command below

```powershell
choco install packer
```

1. Download and install AnyBurn from [here](https://www.anyburn.com/download.php) to generate the `./setup/auto-install.iso` file. Then load/run auto-install.iso.

2. Then run the following commands:

```powershell
packer -v 
packer plugins install github.com/hashicorp/hyperv
packer init windows.json.pkr.hcl
packer fmt --var-file=./windows.auto.pkrvars.hcl windows.json.pkr.hcl
packer validate .
packer build -force -var-file="windows.auto.pkrvars.hcl" "windows.json.pkr.hcl"
```

To override versions locally:
Add -var 'windows_version=2022' -var 'kubernetes_version=v1.37.0' -var 'containerd_version=1.7.25' (or your desired values) to your Packer commands:

```powershell
packer build -force -var-file="windows.auto.pkrvars.hcl" -var 'windows_version=2022' -var 'kubernetes_version=v1.37.0' -var 'containerd_version=1.7.25' "windows.json.pkr.hcl"
```

## Pipeline version overrides

The workflow's optional version inputs override values in
`windows.auto.pkrvars.hcl`. Leave an input blank to use its var-file value, not to
resolve the latest release.

## Diagnosing pipeline failures

The GitHub Actions workflow attempts to upload the `packer-log` artifact even when
the build fails, warning if no log was created. Packer runs with `-on-error=abort`,
leaving the VM and build files in place after a provisioning failure so they can
be inspected on the self-hosted Hyper-V runner.

Before starting another run, download the log and inspect the failed VM's console,
IP address, WinRM listener (TCP 5985), and Windows System/Windows Update events
around the failure time. The workflow uses `-force`, so a subsequent run can remove
preserved build output or conflict with the retained VM. After collecting
diagnostics, manually remove only the failed build's VM and associated files.

### Default password

|OS|username|password|
|--|--------|--------|
|Windows|Administrator|password|
