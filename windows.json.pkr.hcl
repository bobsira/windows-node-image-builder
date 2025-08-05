packer {
  required_plugins {
    hyperv = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/hyperv"
    }
    windows-update = {
      version = ">= 0.14.0"
      source  = "github.com/rgl/windows-update"
    }
  }
}

locals {
  version = formatdate("YYYY.MM.DD", timestamp())
}

variable "vm_name" {
  type        = string
  description = "Image name"
}

variable "vm_cpus" {
  type        = string
  description = "amount of vCPUs"
}

variable "vm_disk_size" {
  type        = string
  description = "Harddisk size"
}

variable "vm_memory" {
  type        = string
  description = "VM Memory"
}

variable "win_iso" {
  type        = string
  description = "Windows Server ISO location"
}

variable "win_checksum" {
  type        = string
  description = "Windows Server ISO checksum"
}

variable "winrm_username" {
  type        = string
  description = "winrm username"
}

variable "winrm_password" {
  type        = string
  description = "winrm password"
  sensitive   = true
}

variable "switch_name" {
  type        = string
  description = "switch name"
}

variable "dynamic_memory" {
  type        = bool
  description = "Dynamic Memory"
}

variable "secure_boot" {
  type        = bool
  description = "Secure boot"
}

variable "tpm" {
  type        = bool
  description = "TPM"
}

variable "generation" {
  type        = number
  description = "Generation"
}

variable "headless" {
  type        = bool
  description = "Headless"
}

variable "skip_export" {
  type        = bool
  description = "Headless"
}

variable "enable_virtualization_extensions" {
  type        = bool
  description = "enable_virtualization_extensions"
}

variable "guest_additions_mode" {
  type        = string
  description = "switch name"
}

source "hyperv-iso" "windows-server" {
  boot_command = ["a<enter><wait>"]
  boot_wait    = "2s"

  secondary_iso_images              = ["./setup/auto-install.iso"]
  vm_name                          = var.vm_name
  cpus                             = var.vm_cpus
  memory                           = var.vm_memory
  enable_dynamic_memory            = var.dynamic_memory
  disk_size                        = var.vm_disk_size
  skip_export                      = var.skip_export
  switch_name                      = var.switch_name
  iso_checksum                     = lookup( var.win_iso_checksums, var.windows_version)
  iso_url                          = lookup( var.win_iso_urls, var.windows_version)
  generation                       = var.generation
  enable_secure_boot               = var.secure_boot
  guest_additions_mode             = var.guest_additions_mode

  
  communicator     = "winrm"
  winrm_port       = "5985"
  winrm_username   = var.winrm_username
  winrm_password   = var.winrm_password
  winrm_timeout    = "12h"
  shutdown_command = "shutdown /s /t 10 /f"
  cd_files         = ["./setup/*"]
  cd_label         = "scripts"
}

build {
  sources = ["source.hyperv-iso.windows-server"]

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    environment_vars  = [
      "WINDOWS_VERSION=${var.windows_version}"
    ]
    script            = "./setup/bootstrap.ps1"
  }

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    environment_vars  = [
      "KUBERNETES_VERSION=${var.kubernetes_version}"
    ]
    script            = "./setup/configure-vm.ps1"
  }

  provisioner "windows-update" {
     search_criteria = "IsInstalled=0"
     filters = [
       "exclude:$_.Title -like '*Preview*'",
       "include:$true",
     ]
     update_limit = 25
   }

  provisioner "windows-restart" {
    restart_timeout = "1h"
  }

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["./setup/disable-autolog.ps1"]
  }

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["./setup/enable-ssh.ps1"]
  }
}