# Get the ID and security principal of the current user account
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole)) {
   # We are running "as Administrator" - so change the title and background color to indicate this
   $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)"
   $Host.UI.RawUI.BackgroundColor = "DarkBlue"
   clear-host
} else {
   # We are not running "as Administrator" - so relaunch as administrator
   # Create a new process object that starts PowerShell
   $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";

   # Specify the current script path and name as a parameter
   $newProcess.Arguments = $myInvocation.MyCommand.Definition;

   # Indicate that the process should be elevated
   $newProcess.Verb = "runas";

   # Start the new process
   [System.Diagnostics.Process]::Start($newProcess);

   # Exit from the current, unelevated, process
   exit
}
# the following code runs elevated...
$iso_url='https://software-download.microsoft.com/pr/Win10_1803_EnglishInternational_x64.iso?t=080ddbfb-902c-4c57-beb8-bc1c57378ed5&e=1531303905&h=265b8b68c521570bc0fb860c7a5f3590'
$iso_path='.\Win10_1803_EnglishInternational_x64.iso'
$vhd_path='.\Win10_1803_EnglishInternational_x64.vhd'
(New-Object Net.WebClient).DownloadFile($iso_url, $iso_path)
(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1', '.\Convert-WindowsImage.ps1')
. .\Convert-WindowsImage.ps1
Convert-WindowsImage -SourcePath $iso_path -VHDPath $vhd_path
