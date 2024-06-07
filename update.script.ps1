$vboxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$maxRetries = 30
$sleepSeconds = 10

# Function to check if the VBoxManage executable exists
function Test-VBoxManagePath {
    if (-Not (Test-Path $vboxManagePath)) {
        throw "VBoxManage.exe not found at path: $vboxManagePath"
    }
}

# Function to check if the VM is online
function Test-VMOnline {
    param (
        [string]$vmName
    )
    $result = & $vboxManagePath guestproperty get $vmName "/VirtualBox/GuestInfo/OS/LoggedInUsers"
    Write-Host "Test-VMOnline result for $($vmName): $result"
    return $result -match "Value: [1-9]"
}

# Function to start the VM
function Start-VM {
    param (
        [string]$vmName
    )
    Write-Host "Starting VM $vmName..."
    & $vboxManagePath startvm $vmName --type headless
    Write-Host "VM $vmName started."
}

# Function to ensure Guest Additions are running within the guest OS
function Ensure-GuestAdditionsRunning {
    param (
        [string]$vmName,
        [string]$vmUsername,
        [string]$vmPassword
    )
    Write-Host "Ensuring Guest Additions are running on VM $vmName..."
    $checkCommand = "/usr/bin/pgrep -x VBoxService"
    $startCommand = "echo $vmPassword | /usr/bin/sudo -S /etc/init.d/vboxadd-service start"

    $result = & $vboxManagePath guestcontrol $vmName run --username $vmUsername --password $vmPassword --exe "/bin/bash" --wait-stdout --wait-stderr -- -c "$checkCommand"

    if ($result -eq "") {
        Write-Host "Guest Additions service is not running. Starting it..."
        & $vboxManagePath guestcontrol $vmName run --username $vmUsername --password $vmPassword --exe "/bin/bash" --wait-stdout --wait-stderr -- -c "$startCommand"
        Write-Host "Guest Additions service started on VM $vmName."
    } else {
        Write-Host "Guest Additions service is already running on VM $vmName."
    }
}

# Function to execute update command within the guest OS
function Execute-UpdateCommand {
    param ($vmName, $vmUsername, $vmPassword)

    Write-Host "Executing update command on VM $vmName..."
    $updateCommand = "echo $vmPassword | /usr/bin/sudo -S /usr/bin/apt update -y >> /root/update.log"
    & $vboxManagePath guestcontrol $vmName run --username $vmUsername --password $vmPassword --exe "/bin/bash" --wait-stdout --wait-stderr -- -c "$updateCommand"
    Write-Host "Update command executed on VM $vmName."
}

# Function to gracefully shut down the VM
function Shut-DownVM {
    param ($vmName)

    Write-Host "Shutting down VM $vmName..."
    & $vboxManagePath controlvm $vmName poweroff
    Write-Host "VM $vmName shut down."
}

# Check if VBoxManage path is valid
Test-VBoxManagePath

# Define a list of VMs with their details
$vms = @(
    @{ Name = "Parrot"; Username = "Tony"; Password = "Hello001#Rosie" },
    @{ Name = "Kali 2023"; Username = "tony"; Password = "Hello001#Rosie" }
    # Add more VMs as needed
)

foreach ($vm in $vms) {
    $vmName = $vm.Name
    $vmUsername = $vm.Username
    $vmPassword = $vm.Password

    # Start VM
    Start-VM -vmName $vmName

    # Wait for the VM to be accessible
    for ($i = 0; $i -lt $maxRetries; $i++) {
        Write-Host "Checking if VM $vmName is online... Attempt $($i + 1) of $maxRetries"
        if (Test-VMOnline $vmName) {
            Write-Host "VM $vmName is online."
            break
        } else {
            Write-Host "VM $vmName is not online yet. Waiting for $sleepSeconds seconds..."
            Start-Sleep -Seconds $sleepSeconds
        }

        if ($i -eq $maxRetries - 1) {
            throw "VM $vmName is not online after $($maxRetries * $sleepSeconds) seconds."
        }
    }

    # Ensure Guest Additions are running
    Ensure-GuestAdditionsRunning -vmName $vmName -vmUsername $vmUsername -vmPassword $vmPassword

    # Execute the update command on the VM
    Execute-UpdateCommand -vmName $vmName -vmUsername $vmUsername -vmPassword $vmPassword

    # Shut down the VM after update
    Shut-DownVM -vmName $vmName
}









