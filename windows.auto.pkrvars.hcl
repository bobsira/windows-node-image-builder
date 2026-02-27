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


kubernetes_version = "v1.35.0"
windows_version    = "2025"
containerd_version = "1.7.25"


win_iso_urls = {
  "2022" = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
  "2025" = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
}

win_iso_checksums = {
  "2022" = "3E4FA6D8507B554856FC9CA6079CC402DF11A8B79344871669F0251535255325"
  "2025" = "D0EF4502E350E3C6C53C15B1B3020D38A5DED011BF04998E950720AC8579B23D"
}

// 26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso   
// 5.8GB
// "2025" = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
// In Powershell use the "Get-FileHash" command to find the checksum of the ISO
// "D0EF4502E350E3C6C53C15B1B3020D38A5DED011BF04998E950720AC8579B23D" 


// 26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso
// 7.9GB
// "2025" = "https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us"
// In Powershell use the "Get-FileHash" command to find the checksum of the ISO
// "7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51" 