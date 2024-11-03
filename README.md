## Requirements

On Powershell Adminstrator complete the following steps 

*packer*

```powershell
choco install packer
```

Then run the following commands:

```powershell
packer -v 
packer init windows.json.pkr.hcl
packer fmt -var-file=windows.auto.pkrvars.hcl windows.json.pkr.hcl
packer validate .
packer build -force -var-file=windows.auto.pkrvars.hcl windows.json.pkr.hcl
```


### Default password

|OS|username|password|
|--|--------|--------|
|Windows|Administrator|password|