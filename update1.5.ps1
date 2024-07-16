#!/usr/bin/env powershell

param ([string[]]$machines, [switch]$nowebhooks, [switch]$version, [switch]$v)

#------------------------------------------------------------------------------------------------------------------------
$SCRIPT_NAME = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$SCRIPT_VERSION = '1.0.5'

$SCRIPT_PATH = [System.IO.Path]::GetDirectoryName((Get-Item -Path $PSCommandPath).FullName)
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

# Define a list of machines with their details
$machinesList = @(
  #@{ Name = "TonyVM1"; IP = "127.0.0.1"; Port = 2201 },
  #@{ Name = "Parrot"; IP = "127.0.0.1"; Port = 2202 },
 @{ Name = "Kali"; IP = "127.0.0.1"; Port = 2203 },
 @{ Name = "AlmaLinux"; IP = "127.0.0.1"; Port = 2204 }
 # @{ Name = "ParrotOS"; IP = "127.0.0.1"; Port = 2205 }
 #@{ Name = "vm6"; IP = "127.0.0.1"; Port = 2206 },
 #@{ Name = "vm7"; IP = "127.0.0.1"; Port = 2207 }
  # Add more machines as needed
  # Add more machines as needed
)

# Define paths and settings
$webhookUrl = "https://btgroupcloud.webhook.office.com/webhookb2/4cb9bd2a-bb60-4c8a-83d4-6a1d995bf9b6@a7f35688-9c00-4d5e-ba41-29f146377ab0/IncomingWebhook/b7639a42f7a641a08be50060241a5008/4ee6e47a-44fc-498e-bd85-72cacf489e6c"
$vboxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$plinkPath = "$SCRIPT_PATH\plink.exe"
$updateScriptPath = "$SCRIPT_PATH\update.sh"
$maxRetries = 30
$sleepSeconds = 10

#------------------------------------------------------------------------------------------------------------------------

# Function to check if the VBoxManage executable exists
function Test-VBoxManagePath {
  if (-Not (Test-Path "$vboxManagePath")) {
    Write-Host "VBoxManage.exe not found at path: $vboxManagePath" -ForegroundColor Red
    exit 1
  }
}

# Function to download plink.exe if it does not exist
function Install-Plink {
  if (-Not (Test-Path "$plinkPath")) {
    Write-Host "Downloading plink.exe..."
    Invoke-WebRequest -Uri "https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe" -OutFile "$plinkPath"
    if (-Not (Test-Path "$plinkPath")) {
      Write-Host "Failed to download plink.exe." -ForegroundColor Red
      exit 1
    }
    Write-Host "plink.exe downloaded successfully."
  }
}

# Function to check if plink executable exists
function Test-PlinkPath {
  if (-Not (Test-Path "$plinkPath")) {
    Write-Host "plink.exe not found at path: '$plinkPath'." -ForegroundColor Red
    exit 1
  }
}

# Function to validate specific inputs
function Validate-Input {
  param (
    [string]$machineUsername,
    [string]$machinePassword,
    [string]$machineIP,
    [int]$port
  )

  # Validate username and password for invalid characters
  if ($machineUsername -match "[`'`"`]") {
    Write-Host "Username contains invalid characters."
    return $false
  }

  if ($machinePassword -match "[`'`"`]") {
    Write-Host "Password contains invalid characters."
    return $false
  }

  # Validate IP address
  if (-not [System.Net.IPAddress]::TryParse($machineIP, [ref]([System.Net.IPAddress]::Any))) {
    Write-Host "Invalid IP address."
    return $false
  }

  # Validate port number
  if ($port -lt 1 -or $port -gt 65535) {
    Write-Host "Invalid port number."
    return $false
  }

  return $true
}

# Function to check if the machine exists
function Test-MachineExists {
  param (
    [string]$machineName
  )
  $result = & "$vboxManagePath" list vms | Select-String -Pattern "`"$machineName`""
  if ($result) {
    Write-Host "Machine $machineName exists."
    return $true
  } else {
    Write-Host "Machine $machineName does not exist." -ForegroundColor Red
    return $false
  }
}

# Function to check if the machine is running
function Test-MachineState {
  param (
    [string]$machineName
  )
  $result = & "$vboxManagePath" showvminfo "$machineName" --machinereadable | Select-String 'VMState='
  if ($result -match 'VMState="running"') {
    return $true
  }
  return $false
}

# Function to start the machine
function Start-Machine {
  param (
    [string]$machineName,
    [int]$maxRetries,
    [int]$sleepSeconds
  )
  Write-Host "Starting machine..."
  $startResult = & "$vboxManagePath" startvm "$machineName" --type headless
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to start machine $machineName." -ForegroundColor Red
    $global:LASTEXITCODE = $LASTEXITCODE
    return $false
  }
  Write-Host "Machine started. Waiting $(3 * $sleepSeconds) seconds for machine to boot up..."
  Start-Sleep -Seconds $(3 * $sleepSeconds)
  $global:LASTEXITCODE = 0
  return $true
}

# Function to check if the machine is ready for SSH connections
function Wait-ForSSHConnectivity {
  param (
    [string]$machineIP,
    [string]$machineUsername,
    [string]$machinePassword,
    [int]$port,
    [int]$maxRetries,
    [int]$sleepSeconds
  )

  for ($i = 0; $i -lt $maxRetries; $i++) {
    Write-Host "Checking SSH connectivity at address $machineIP and port $port... Attempt $($i + 1) of $maxRetries"

    # Attempt SSH connection using plink
    $plinkCommand = "`"$plinkPath`" -batch -ssh `"$machineUsername`"@`"$machineIP`" -P $port -pw `"$machinePassword`" exit"
    $result = & cmd /c "$plinkCommand" 2>&1
    $global:LASTEXITCODE = $LASTEXITCODE
    $resultString = $result -join " "

    if ($global:LASTEXITCODE -eq 0) {
      Write-Host "Machine is ready for SSH connections."

      # Define the command to check sudo privileges using sudo whoami
      $whoamiCommand = "`"$plinkPath`" -batch -ssh `"$machineUsername`"@`"$machineIP`" -P $port -pw `"$machinePassword`" `"echo '$machinePassword' | sudo -S whoami >/dev/null 2>&1 && sudo -n whoami && echo success`""      
      $whoamiResult = & cmd /c "$whoamiCommand" 2>&1
      $whoamiResultString = $whoamiResult -join " "

      # Check if the result indicates that the user has sudo privileges
      if ($whoamiResultString -notmatch "\broot\b") {
          Write-Host ""
          Write-Host "User does not have sudo privileges or sudoers file has a timeout set to zero." -ForegroundColor Red
          $global:LASTEXITCODE = 1
          return
      }
      return
    } elseif ($resultString -ilike "*FATAL ERROR: No supported authentication methods available*") {
      Write-Host ""
      Write-Host "Connection failed. SSH with password authentication may not be enabled." -ForegroundColor Red
      $global:LASTEXITCODE = 1
      return
    } elseif ($resultString -ilike "*FATAL ERROR: Configured password was not accepted*") {
      Write-Host ""
      Write-Host "Connection failed. SSH credentials were not accepted and may be incorrect." -ForegroundColor Red
      $global:LASTEXITCODE = 1
      return
    } elseif ($resultString -ilike "*FATAL ERROR: Cannot confirm a host key in batch mode*") {
      Write-Host ""
      Write-Host "Host key not cached for machine at $machineIP. Please verify the key fingerprint." -ForegroundColor Blue
      Write-Host "Press <y> followed by <ENTER> to cache the key, and <ENTER> again to start the session." -ForegroundColor Blue
      Write-Host ""
      Start-Sleep -Seconds 2
      & cmd /c "`"$plinkPath`" -ssh `"$machineUsername`"@`"$machineIP`" -P $port -pw `"$machinePassword`" exit"

      # Check if host key was accepted
      $result = & cmd /c "`"$plinkPath`" -batch -ssh `"$machineUsername`"@`"$machineIP`" -P $port -pw `"$machinePassword`" -v exit" 2>&1
      $resultString = $result -join " "
      if ($resultString -ilike "*The host key is not cached for this server*" -or $resultString -ilike "*The host key does not match the one Plink has cached for this server*") {
        Write-Host ""
        Write-Host "Host key was not cached. Skipping machine..." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
      }
    } else {
      Start-Sleep -Seconds $sleepSeconds
    }

    if ($i -eq $maxRetries - 1) {
      Write-Host ""
      Write-Host "Machine is not ready for SSH connections after $maxRetries attempts." -ForegroundColor Red
      $global:LASTEXITCODE = 1
      return
    }
  }
}

# Function to read the update script from the file
function Get-UpdateScript {
  param (
    [string]$path
  )
  if (Test-Path $path) {
    return Get-Content -Path $path -Raw
  } else {
    Write-Host "Update script file not found at path: $path" -ForegroundColor Red
    exit 1
  }
}

# Function to execute update script within the guest OS using plink
function Execute-UpdateScript {
  param (
    [string]$machineName,
    [string]$machineUsername,
    [string]$machinePassword,
    [string]$machineIP,
    [int]$port,
    [string]$updateScript
  )

  Write-Host "Executing update script on machine $machineName..."
  $singleLineScript = ConvertToSingleLine -script "$updateScript"
  $updateCommand = "echo '$machinePassword' | sudo -S whoami >/dev/null 2>&1 && echo -e '$singleLineScript' | sudo bash"

  # Write the command to a temporary script file
  $tempScriptPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "update_tmp.sh")
  Set-Content -Path $tempScriptPath -Value "$updateCommand" -Force

  # Create the plink command
  $plinkCommand = "`"$plinkPath`" -batch -ssh `"$machineUsername`"@`"$machineIP`" -P `"$port`" -pw `"$machinePassword`" -m `"$tempScriptPath`""

  # Define a temporary file to store the process output
  $tempOutputFile = [System.IO.Path]::GetTempFileName()
  $tempErrorFile = [System.IO.Path]::GetTempFileName()

  # Start the process and capture the output
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = "cmd.exe"
  $processInfo.Arguments = "/c `"$plinkCommand`""
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo
  $process.Start() | Out-Null

  # Read and display the standard output while also saving it to a temporary file
  $outputStream = $process.StandardOutput
  $errorStream = $process.StandardError

  # Display and capture the output stream
  while (!$outputStream.EndOfStream) {
    $line = $outputStream.ReadLine()
    Write-Host $line
    Add-Content -Path $tempOutputFile -Value $line
  }

  # Display and capture the error stream
  while (!$errorStream.EndOfStream) {
    $line = $errorStream.ReadLine()
    Write-Host $line
    Add-Content -Path $tempErrorFile -Value $line
  }

  $process.WaitForExit()
  $global:LASTEXITCODE = $process.ExitCode
  Write-Host ""

  # Append error messages to the corresponding array if the process fails
  if ($global:LASTEXITCODE -ne 0) {
    $errorOutput = Get-Content -Path $tempErrorFile
    if ($errorOutput -ne $null -and $errorOutput.Length -gt 0) {
      $lineNumber = 1
      $global:machineErrors += ""
      $global:machineErrors += "$machineName errors:"
      foreach ($line in $errorOutput) {
        $global:machineErrors += "&nbsp;&nbsp;&nbsp;&nbsp;$lineNumber) $line"
        $lineNumber++
      }
    }

    # Clean up all temporary files
    Remove-Item -Path @($tempScriptPath, $tempOutputFile, $tempErrorFile) -Force

    Write-Host "Update script failed on machine $machineName with exit code $global:LASTEXITCODE." -ForegroundColor Red
  } else {
    # Clean up all temporary files
    Remove-Item -Path @($tempScriptPath, $tempOutputFile, $tempErrorFile) -Force

    Write-Host "Update script executed successfully on machine $machineName." -ForegroundColor Green
  }
}

# Function to shut down the machine
function Shut-DownMachine {
  param (
    [string]$machineName
  )

  Write-Host "Attempting to gracefully shut down machine..."
  $shutdownResult = & "$vboxManagePath" controlvm "$machineName" acpipowerbutton >$null 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to send ACPI power button signal to $machineName." -ForegroundColor Red
  } else {
    Start-Sleep -Seconds $sleepSeconds

    # Wait for the machine to shut down, checking periodically
    for ($i = 0; $i -lt $maxRetries; $i++) {
      $currentState = & "$vboxManagePath" showvminfo "$machineName" --machinereadable | Select-String -Pattern "VMState=" | ForEach-Object { $_.ToString().Split('=')[1].Trim('"') }
      if ($currentState -eq "poweroff") {
        Write-Host "Machine $machineName has shut down gracefully."
        $global:LASTEXITCODE = 0
        return $true
      }
      Start-Sleep -Seconds 4
    }
  }

  # Force power off
  Write-Host "Machine $machineName did not shut down gracefully, forcing power off..."
  $shutdownResult = & "$vboxManagePath" controlvm "$machineName" poweroff >$null 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to forcefully shut down machine $machineName." -ForegroundColor Red
    $global:LASTEXITCODE = $LASTEXITCODE
    return $false
  }

  Write-Host "Machine $machineName has been forcefully shut down."
  $global:LASTEXITCODE = 0
  return $true
}

# Function to escape and convert multiline script to single line with \n
function ConvertToSingleLine {
  param (
    [string]$script
  )
  $escapedScript = $script -replace "`r`n", "`n" -replace "`n", "\n" -replace "'", "'\''"
  return $escapedScript
}

# Function to convert SecureString to plain text
function ConvertFrom-SecureStringToPlainText {
  param (
    [System.Security.SecureString]$secureString
  )
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
  try {
    return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  }
  finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

# Function to construct message to send, JSON payload, and headers
function Construct-MessageAndPayload {
  param (
    [string[]]$machineOutcomes,
    [string[]]$machineErrors,
    [string]$webhookUrl
  )

  # Define the message to send
  $message = ($machineOutcomes -join "<br>")

  # Colourise OK in green
  $message = $message -replace "OK", "<font color=`"green`">OK</font>"

  # Colourise FAIL in red
  $message = $message -replace "FAIL", "<font color=`"red`">FAIL</font>"

  # Add machine errors to message
  if ($machineErrors -and $machineErrors.Length -gt 0) {
    $message += "<br>" + ($machineErrors -join "<br>")
  }

  # Construct the JSON payload
  $jsonPayload = @{
    text = $message
  } | ConvertTo-Json -Compress

  # Define headers
  $headers = @{
    "Content-Type" = "application/json"
  }

  return $jsonPayload, $headers
}

# Display script version if flag is used
if ($version -or $v) {
  Write-Host "$SCRIPT_NAME version $SCRIPT_VERSION"
  exit
}

# Filter machines based on provided VM names
if ($machines -and $machines.Length -gt 0) {
  $filteredMachines = $machines -split ','
  $machinesList = $machinesList | Where-Object { $filteredMachines -contains $_.Name }
}

# Check if VBoxManage and plink paths are valid
Test-VBoxManagePath
Install-Plink

# Load the update script content
$updateScript = Get-UpdateScript -path "$updateScriptPath"

# Multiline variable to store machine outcomes
$machineOutcomes = @()

# Multiline variable to store machine errors
$machineErrors = @()

# Iterate through all the machines in the array
foreach ($machine in $machinesList) {
  $machineName = $machine.Name
  Write-Host ""

  # Retrieve credentials from the Credential Manager
  $credential = Get-StoredCredential -Target "$machineName"
  if (-not $credential) {
    Write-Host "Failed to retrieve credentials for machine $machineName." -ForegroundColor Red
    $machineOutcomes += "$machineName FAIL"
    continue
  }
  $machineUsername = $credential.UserName
  $machinePassword = ConvertFrom-SecureStringToPlainText -secureString $credential.Password
  $machineIP = $machine.IP
  $port = $machine.Port

  # Validate inputs
  $isValid = Validate-Input -machineUsername "$machineUsername" -machinePassword "$machinePassword" -machineIP "$machineIP" -port "$port"

  # Check if machine IP address exists
  if (-not $machineIP) {
    Write-Host "Failed to retrieve IP address for machine $machineName." -ForegroundColor Red
    $machineOutcomes += "$machineName FAIL"
    continue
  }

  # Check if machine exists
  if (-Not (Test-MachineExists -machineName "$machineName")) {
    Write-Host "Skipping machine $machineName as it does not exist." -ForegroundColor Red
    $machineOutcomes += "$machineName FAIL"
    continue
  }

  # Check if machine is already running
  $machineWasStarted = $false
  if (Test-MachineState -machineName "$machineName") {
    Write-Host "Machine is already running."
  } else {
    # Start machine and wait for it to be accessible
    $machineWasStarted = Start-Machine -machineName "$machineName" -maxRetries $maxRetries -sleepSeconds $sleepSeconds
    if (-not $machineWasStarted) {
      $machineOutcomes += "$machineName FAIL"
      continue
    }
  }

  # Wait for SSH connectivity
  Wait-ForSSHConnectivity -machineIP "$machineIP" -machineUsername "$machineUsername" -machinePassword "$machinePassword" -port $port -maxRetries $maxRetries -sleepSeconds $sleepSeconds
  if ($global:LASTEXITCODE -ne 0) {
    Shut-DownMachine -machineName "$machineName" >$null
    $machineOutcomes += "$machineName FAIL"
    continue
  }

  # Execute the update script
  Execute-UpdateScript -machineName "$machineName" -machineUsername "$machineUsername" -machinePassword "$machinePassword" -machineIP "$machineIP" -port $port -updateScript $updateScript
  $exitCode = $global:LASTEXITCODE
  if ($exitCode -ne 0) {
    Shut-DownMachine -machineName "$machineName" >$null
    $machineOutcomes += "$machineName FAIL"
    continue
  }

  # Shut down the machine
  $shutDownResult = Shut-DownMachine -machineName "$machineName"

  # Check the result of the shutdown operation
  if (-not $shutDownResult) {
    $machineOutcomes += "$machineName FAIL"
    continue
  }

  $machineOutcomes += "$machineName OK"
}

# Execute the request if webhook sending is enabled
Write-Host ""
if (-not $nowebhooks.IsPresent) {
  Write-Host "Attempting to send webhook..."
  if ($machineOutcomes.Count -gt 0) {
    $jsonPayload, $headers = Construct-MessageAndPayload -machineOutcomes $machineOutcomes -machineErrors $global:machineErrors -webhookUrl "$webhookUrl"
    $response = Invoke-WebRequest -Uri "$webhookUrl" -Method Post -Body $jsonPayload -Headers $headers
    if ($response.StatusCode -eq 200) {
      Write-Host "Webhook sent successfully." -ForegroundColor Green
    } else {
      Write-Host "Failed to send webhook. Response status code: $($response.StatusCode)." -ForegroundColor Red
    }
  } else {
    Write-Host "Nothing to send."
  }
} else {
    Write-Host "Webhook sending is disabled." -ForegroundColor Blue
}
