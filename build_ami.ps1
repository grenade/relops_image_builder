if (-not (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processStartInfo.FileName = 'powershell.exe'
  $processStartInfo.Arguments = @('-NoProfile', '-File', $myInvocation.MyCommand.Definition)
  $processStartInfo.Verb = 'RunAs'
  $processStartInfo.WindowStyle = 'Hidden'
  $processStartInfo.CreateNoWindow = $true
  $processStartInfo.RedirectStandardError = $true
  $processStartInfo.RedirectStandardOutput = $true
  $processStartInfo.UseShellExecute = $false
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processStartInfo
  $process.Start() | Out-Null
  $process.StandardOutput.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode) {
    $process.StandardError.ReadToEnd()
    ('process exit code: {0}' -f $process.ExitCode)
  }
  exit
}
$iso_url='https://software-download.microsoft.com/pr/Win10_1803_EnglishInternational_x64.iso?t=080ddbfb-902c-4c57-beb8-bc1c57378ed5&e=1531303905&h=265b8b68c521570bc0fb860c7a5f3590'
$iso_path='.\Win10_1803_EnglishInternational_x64.iso'
$vhd_path='.\Win10_1803_EnglishInternational_x64.vhdx'
(New-Object Net.WebClient).DownloadFile($iso_url, $iso_path)
(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1', '.\Convert-WindowsImage.ps1')
. .\Convert-WindowsImage.ps1
Convert-WindowsImage -SourcePath $iso_path -VHDPath $vhd_path -Edition Core
