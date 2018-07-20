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

$image_name='Win10_1803_EnglishInternational_x64'
$image_edition='Core'
$image_capture_date=((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
$image_key=('{0}-{1}-{2}' -f $image_name, $image_edition, $image_capture_date)

$aws_region='us-west-2'
$s3_bucket='windows-ami-builder'
$s3_vhd_key=('vhd/{0}-{1}.vhdx' -f $image_name, $image_edition)

$iso_url=('https://s3-{0}.amazonaws.com/{1}/iso/{2}.iso' -f $aws_region, $s3_bucket, $image_name)
$iso_path=('.\{0}.iso' -f $image_name)

$vhd_path=('.\{0}-{1}.vhdx' -f $image_name, $image_edition)

Set-ExecutionPolicy RemoteSigned
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name AWSPowerShell

$aws_creds=(Invoke-WebRequest -Uri 'http://169.254.169.254/latest/meta-data/iam/security-credentials/windows-ami-builder' -UseBasicParsing | ConvertFrom-Json)
$env:AWS_ACCESS_KEY_ID = $aws_creds.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $aws_creds.SecretAccessKey
$env:AWS_SESSION_TOKEN = $aws_creds.Token
Set-AWSCredential -AccessKey $aws_creds.AccessKeyId -SecretKey $aws_creds.SecretAccessKey -StoreAs WindowsAmiBuilder
Initialize-AWSDefaultConfiguration -ProfileName WindowsAmiBuilder -Region $aws_region

# download the iso file if it is not on the local filesystem
if (-not (Test-Path -Path $iso_path -ErrorAction SilentlyContinue)) {
  (New-Object Net.WebClient).DownloadFile($iso_url, $iso_path)
}

if (-not (Test-Path -Path './Convert-WindowsImage.ps1' -ErrorAction SilentlyContinue)) {
  (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1', '.\Convert-WindowsImage.ps1')
}

# create the vhd(x) file if it is not on the local filesystem
if (-not (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue)) {
  . .\Convert-WindowsImage.ps1
  Convert-WindowsImage -SourcePath $iso_path -VHDPath $vhd_path -Edition $image_edition
}

# upload the vhd(x) file if it is not in the s3 bucket
if (-not (Get-S3Object -BucketName $s3_bucket -Key $s3_vhd_key -Region $aws_region)) {
  Write-S3Object -BucketName $s3_bucket -File $vhd_path -Key $vhd_key
}