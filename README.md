#------------------------------------------------------------------------------------------------------------------------
<#
1. **Install the Credential Manager module**:
        powershell Install-Module -Name CredentialManager -Force

2. **Store the credentials**:
    # Run this command for each machine to securely store its credentials in the Windows Credential Manager, ensuring to replace <VMNAME>, <USERNAME> and <PASSWORD>
        powershell New-StoredCredential -Target "<VMNAME>" -UserName "<USERNAME>" -Password "<PASSWORD>" -Persist LocalMachine

3. **Update the machinesList array with the relevant details of each machine**:
    # The "Name =" value should correspond to the name of the VM in VirtualBox, as well as the "-Target" value in step 2
        e.g.
            $machinesList = @(
              @{ Name = "vm1"; IP = "127.0.0.1"; Port = 2201 },
              @{ Name = "vm2"; IP = "127.0.0.1"; Port = 2202 }
              # Add more machines as needed
            )

4.  **Run script on all machines**:
        powershell -ExecutionPolicy bypass -File .\update.ps1

    **Run script on specific machines**:
        powershell -ExecutionPolicy bypass -File .\update.ps1 -Machines vm1,vm2
#>
#------------------------------------------------------------------------------------------------------------------------
