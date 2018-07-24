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

$image_name = 'Win10_1803_EnglishInternational_x64'
$image_edition = 'Core'
$image_capture_date = ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
$image_key = ('{0}-{1}-{2}' -f $image_name, $image_edition, $image_capture_date)

$aws_region = 'us-west-2'
$s3_bucket = 'windows-ami-builder'
$s3_vhd_key = ('vhd/{0}-{1}.vhdx' -f $image_name, $image_edition)

$iso_url = ('https://s3-{0}.amazonaws.com/{1}/iso/{2}.iso' -f $aws_region, $s3_bucket, $image_name)
$iso_path = ('.\{0}.iso' -f $image_name)

$cwi_url = 'https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1'
$cwi_path = '.\Convert-WindowsImage.ps1'

$vhd_path = ('.\{0}-{1}.vhdx' -f $image_name, $image_edition)

Set-ExecutionPolicy RemoteSigned

# install aws powershell module if not installed
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
  $nugetPackageProvider = (Get-PackageProvider -Name NuGet)
  if ((-not ($nugetPackageProvider)) -or ($nugetPackageProvider.Version -lt 2.8.5.201)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
  }
  Install-Module -Name AWSPowerShell
}

$creds_url = 'http://169.254.169.254/latest/user-data'
$aws_creds=(Invoke-WebRequest -Uri $creds_url -UseBasicParsing | ConvertFrom-Json).credentials.windows_ami_builder
$env:AWS_ACCESS_KEY_ID = $aws_creds.aws_access_key_id
$env:AWS_SECRET_ACCESS_KEY = $aws_creds.aws_secret_access_key
Set-AWSCredential -AccessKey $aws_creds.aws_access_key_id -SecretKey $aws_creds.aws_secret_access_key -StoreAs WindowsAmiBuilder
Initialize-AWSDefaultConfiguration -ProfileName WindowsAmiBuilder -Region $aws_region

# download the iso file if not on the local filesystem
if (-not (Test-Path -Path $iso_path -ErrorAction SilentlyContinue)) {
  try {
    (New-Object Net.WebClient).DownloadFile($iso_url, $iso_path)
    Write-Host -object ('downloaded {0} to {1}' -f $iso_url, $iso_path) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('iso detected at: {0}' -f $iso_path) -ForegroundColor DarkGray
}

# download the vhd conversion script if not on the local filesystem
if (-not (Test-Path -Path $cwi_path -ErrorAction SilentlyContinue)) {
  try {
    (New-Object Net.WebClient).DownloadFile($cwi_url, $cwi_path)
    Write-Host -object ('downloaded {0} to {1}' -f $cwi_url, $cwi_path) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('vhd conversion script detected at: {0}' -f $cwi_path) -ForegroundColor DarkGray
}

# create the vhd(x) file if it is not on the local filesystem
if (-not (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue)) {
  try {
    . .\Convert-WindowsImage.ps1
    Convert-WindowsImage -SourcePath $iso_path -VHDPath $vhd_path -Edition $image_edition
    Write-Host -object ('created {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('vhd detected at: {0}' -f $vhd_path) -ForegroundColor DarkGray
}

# upload the vhd(x) file if it is not in the s3 bucket
if (-not (Get-S3Object -BucketName $s3_bucket -Key $s3_vhd_key -Region $aws_region)) {
  try {
    Write-S3Object -BucketName $s3_bucket -File $vhd_path -Key $s3_vhd_key
    Write-Host -object ('uploaded {0} to bucket {1} with key {2}' -f $vhd_path, $s3_bucket, $s3_vhd_key) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('vhd detected in bucket {0} with key {1}' -f $s3_bucket, $s3_vhd_key) -ForegroundColor DarkGray
}