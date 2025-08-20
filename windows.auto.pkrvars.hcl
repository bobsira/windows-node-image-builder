// VM hardware specs
vm_name         = "hybrid-minikube-windows-server"
vm_cpus         = "2"
vm_memory       = "4096"
vm_disk_size    = "65536"
switch_name     = "Default Switch"
dynamic_memory  = "true"
secure_boot     = "false"
tpm             = "true"
generation      = "2" 
headless        = "false"
skip_export     = "false"
enable_virtualization_extensions = "false"
guest_additions_mode = "disable"

// Use the NAT Network
// vm_network      = "VMnet8"

// WinRM 
winrm_username  = "Administrator"
winrm_password  = "password"

// server 2022
// win_iso         = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
// server 2025
win_iso = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
// In Powershell use the "Get-FileHash" command to find the checksum of the ISO
// server 2022
//win_checksum    = "3E4FA6D8507B554856FC9CA6079CC402DF11A8B79344871669F0251535255325"
// server 2025
win_checksum = "D0EF4502E350E3C6C53C15B1B3020D38A5DED011BF04998E950720AC8579B23D"

windows_version = "2025"
kubernetes_version = "v1.33.1"

win_iso_urls = {
  "2022" = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
  "2025" = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
}

win_iso_checksums = {
  "2022" = "3E4FA6D8507B554856FC9CA6079CC402DF11A8B79344871669F0251535255325"
  "2025" = "D0EF4502E350E3C6C53C15B1B3020D38A5DED011BF04998E950720AC8579B23D"
}