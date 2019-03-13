Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0; 
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0; 

Stop-Process -Name Explorer

Install-WindowsFeature -Name Web-Server -IncludeAllSubFeature 

if ($env:COMPUTERNAME -like "*web*") {
    New-NetFirewallRule -DisplayName "SmartHotel.Registration Inbound" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
} elseif ($env:COMPUTERNAME -like "*app*") {
    New-NetFirewallRule -DisplayName "SmartHotel.Registration.Wcf Inbound" -Direction Inbound -LocalPort 2901 -Protocol TCP -Action Allow
}
