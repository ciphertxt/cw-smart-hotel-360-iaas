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
New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 192.168.0.0/24

# Create an internal switch with NAT
$switchName = "InternalNATSwitch"
New-VMSwitch -Name $switchName -SwitchType Internal
$adapter = Get-NetAdapter | ? { $_.Name -like "*$($switchName)*" }
# Create an internal network (gateway first)
New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

# Add a NAT forwarder for Web1 and SQL1 
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 80 -Protocol TCP -InternalIPAddress "192.168.0.4" -InternalPort 80 -NatName $natName
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 1433 -Protocol TCP -InternalIPAddress "192.168.0.6" -InternalPort 1433 -NatName $natName

# Add a firewall rule for Web and SQL
New-NetFirewallRule -DisplayName "SmartHotel.Registration Inbound" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Microsoft SQL Server Inbound" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow

# Enable Enhanced Session Mode on Host
Set-VMHost -EnableEnhancedSessionMode $true

# Set VM Name, Switch Name, and Installation Media Path.
$VMNames = "SmartHotelWeb1","SmartHotelWeb2","SmartHotelSQL1"
$opsDir = "F:\VirtualMachines"

New-VM -Name "SmartHotelWeb1" -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\SmartHotelWeb1\SmartHotelWeb1.vhdx" -Path "$opsdir\SmartHotelWeb1" -Generation 2 -Switch $switchName
New-VM -Name "SmartHotelWeb2" -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\SmartHotelWeb2\SmartHotelWeb2.vhdx" -Path "$opsdir\SmartHotelWeb2" -Generation 2 -Switch $switchName 
New-VM -Name "SmartHotelSQL1" -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$opsdir\SmartHotelSQL1\SmartHotelSQL1.vhdx" -Path "$opsdir\SmartHotelSQL1" -Generation 2 -Switch $switchName  

$vmweb1 = Get-VMNetworkAdapter -VMName "SmartHotelWeb1"
$vmweb2 = Get-VMNetworkAdapter -VMName "SmartHotelWeb2"
$vmsql1 = Get-VMNetworkAdapter -VMName "SmartHotelSQL1"

$vmweb1 | Set-VMNetworkConfiguration -IPAddress "192.168.0.4" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
$vmweb2 | Set-VMNetworkConfiguration -IPAddress "192.168.0.5" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
$vmsql1 | Set-VMNetworkConfiguration -IPAddress "192.168.0.6" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"

# Start all the VMs
Get-VM | where {$_.State -eq 'Off'} | Start-VM