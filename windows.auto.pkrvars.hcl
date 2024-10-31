// VM hardware specs
vm_name         = "GI-W11-001"
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

// Removeable media
win_iso         = "c:/iso/SERVER_EVAL_x64FRE_en-us.iso"
// In Powershell use the "Get-FileHash" command to find the checksum of the ISO
win_checksum    = "3E4FA6D8507B554856FC9CA6079CC402DF11A8B79344871669F0251535255325"