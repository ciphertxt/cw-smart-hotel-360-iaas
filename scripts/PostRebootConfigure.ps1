Function Set-VMNetworkConfiguration {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='DHCP',
                   ValueFromPipeline=$true)]
        [Parameter(Mandatory=$true,
                   Position=0,
                   ParameterSetName='Static',
                   ValueFromPipeline=$true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='Static')]
        [String[]]$IPAddress=@(),

        [Parameter(Mandatory=$false,
                   Position=2,
                   ParameterSetName='Static')]
        [String[]]$Subnet=@(),

        [Parameter(Mandatory=$false,
                   Position=3,
                   ParameterSetName='Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory=$false,
                   Position=4,
                   ParameterSetName='Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory=$false,
                   Position=0,
                   ParameterSetName='DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object { $_.ElementName -eq $NetworkAdapter.VMName } 
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }    
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData') 

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters) {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress) {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated("Msvm_GuestNetworkAdapterConfiguration")
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].DefaultGateways = $DefaultGateway
    $NetworkSettings[0].DNSServers = $DNSServer
    $NetworkSettings[0].ProtocolIFType = 4096

    if ($dhcp) {
        $NetworkSettings[0].DHCPEnabled = $true
    } else {
        $NetworkSettings[0].DHCPEnabled = $false
    }

    $Service = Get-WmiObject -Class "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($VM, $NetworkSettings[0].GetText(1))

    if ($setip.ReturnValue -eq 4096) {
        $job=[WMI]$setip.job 

        while ($job.JobState -eq 3 -or $job.JobState -eq 4) {
            start-sleep 1
            $job=[WMI]$setip.job
        }

        if ($job.JobState -eq 7) {
            write-host "Success"
        }
        else {
            $job.GetError()
        }
    } elseif($setip.ReturnValue -eq 0) {
        Write-Host "Success"
    }
}


# Create the NAT network
$natName = "InternalNat"
$nat = Get-NetNat | ? { $_.Name -eq $natName }
if ($nat -eq $null) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 192.168.0.0/24
}

# Create an internal switch with NAT
$switchName = "InternalNATSwitch"
$vmSwitch = Get-VMSwitch | ? { $_.Name -eq $switchName }
if ($vmSwitch -eq $null) {
    New-VMSwitch -Name $switchName -SwitchType Internal
}

$adapter = Get-NetAdapter | ? { $_.Name -like "*$($switchName)*" }
# Create an internal network (gateway first)
$ipAddress = Get-NetIPAddress | ? { $_.IPAddress -eq "192.168.0.1" }
if ($ipAddress -eq $null) {
    New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex
}

# Add a NAT forwarder for Web1 and SQL1 
$web1Nat = Get-NetNatStaticMapping | ? { $_.InternalIPAddress -eq "192.168.0.4" }
if ($web1Nat -eq $null) {
    Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 80 -Protocol TCP -InternalIPAddress "192.168.0.4" -InternalPort 80 -NatName $natName
}    
$sql1Nat = Get-NetNatStaticMapping | ? { $_.InternalIPAddress -eq "192.168.0.6" }
if ($sql1Nat -eq $null) {
    Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 1433 -Protocol TCP -InternalIPAddress "192.168.0.6" -InternalPort 1433 -NatName $natName
}

# Add a firewall rule for Web and SQL
$shRegistrationRule = Get-NetFirewallRule | ? { $_.DisplayName -eq "SmartHotel.Registration Inbound" }
if ($shRegistrationRule -eq $null) {
    New-NetFirewallRule -DisplayName "SmartHotel.Registration Inbound" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
}
$shSQLRule = Get-NetFirewallRule | ? { $_.DisplayName -eq "Microsoft SQL Server Inbound" }
if ($shSQLRule -eq $null) {
    New-NetFirewallRule -DisplayName "Microsoft SQL Server Inbound" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow
}

# Enable Enhanced Session Mode on Host
Set-VMHost -EnableEnhancedSessionMode $true

# Set VM Names.
$vmNameWeb1 = "SmartHotelWeb1"
$vmNameWeb2 = "SmartHotelWeb2"
$vmNameSQL1 = "SmartHotelSQL1"
$opsDir = "F:\VirtualMachines"

New-VM -Name $vmNameWeb1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\$vmNameWeb1\$vmNameWeb1.vhdx" -Path "$opsdir\$vmNameWeb1" -Generation 2 -Switch $switchName
New-VM -Name $vmNameWeb2 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\$vmNameWeb2\$vmNameWeb2.vhdx" -Path "$opsdir\$vmNameWeb2" -Generation 2 -Switch $switchName 
New-VM -Name $vmNameSQL1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\$vmNameSQL1\$vmNameSQL1.vhdx" -Path "$opsdir\$vmNameSQL1" -Generation 2 -Switch $switchName  

Get-VMNetworkAdapter -VMName $vmNameWeb1 | Set-VMNetworkConfiguration -IPAddress "192.168.0.4" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "10.0.0.4"
Get-VMNetworkAdapter -VMName $vmNameWeb2 | Set-VMNetworkConfiguration -IPAddress "192.168.0.5" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "10.0.0.4"
Get-VMNetworkAdapter -VMName $vmNameSQL1 | Set-VMNetworkConfiguration -IPAddress "192.168.0.6" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "10.0.0.4"

# Start the SQL server
Get-VM -Name $vmNameSQL1 | Start-VM
for ($i=30;$i -gt 1;$i--) {
    Write-Progress -Activity "Starting $vmNameSQL1..." -SecondsRemaining $i
    Start-Sleep -s 1
}

# Start the remaining VMs
Get-VM | ? {$_.State -eq 'Off'} | Start-VM

for ($i=120;$i -gt 1;$i--) {
    Write-Progress -Activity "Starting remaining VMs..." -SecondsRemaining $i
    Start-Sleep -s 1
}

# Domain join the VMs and rearm the eval
Write-Output "Configuring VMs..."
$localusername = "Administrator"
$password = ConvertTo-SecureString "demo@pass123" -AsPlainText -Force
$localcredential = New-Object System.Management.Automation.PSCredential ($localusername, $password)
$domainusername = "SH360\demouser"
$domaincredential = New-Object System.Management.Automation.PSCredential ($domainusername, $password)
$vmStopIP = 6

for ($i = 4; $i -le $vmStopIP; $i++) {
    Write-Output "Configuring VM at 192.168.0.$i..."
    Invoke-Command -ComputerName "192.168.0.$i" -ScriptBlock { 
        slmgr.vbs /rearm
        net accounts /maxpwage:unlimited
        Add-Computer -DomainName "sh360.local" -Credential $Using:domaincredential -Restart -Force 
    } -Credential $localcredential
    Write-Output "Configuration complete"
}