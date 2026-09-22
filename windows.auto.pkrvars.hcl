// VM hardware specs
vm_name                          = "hybrid-minikube-windows-server"
vm_cpus                          = "2"
vm_memory                        = "4096"
vm_disk_size                     = "65536"
switch_name                      = "Default Switch"
dynamic_memory                   = "true"
secure_boot                      = "false"
tpm                              = "true"
generation                       = "2"
headless                         = "false"
skip_export                      = "false"
enable_virtualization_extensions = "false"
guest_additions_mode             = "disable"

// Use the NAT Network
// vm_network      = "VMnet8"

// WinRM 
winrm_username = "Administrator"
winrm_password = "password"


kubernetes_version = "v1.37.0"
windows_version    = "2025"
containerd_version = "2.2.3"


win_iso_urls = {
  "2022" = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
  "2025" = "https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us"
}

win_iso_checksums = {
  "2022" = "3E4FA6D8507B554856FC9CA6079CC402DF11A8B79344871669F0251535255325"
  "2025" = "7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51"
}
