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

$vhd_format = 'VHD'
$vhd_partition_style = 'MBR'

$image_description = ('{0} edition: {1}, partition style: {2}. captured on {3}' -f $image_name, $image_edition, $vhd_partition_style, $image_capture_date)

$aws_region = 'us-west-2'
$aws_availability_zone = ('{0}a' -f $aws_region)
$s3_bucket = 'windows-ami-builder'
$s3_vhd_key = ('{0}/{1}-{2}-{3}.{0}' -f $vhd_format.ToLower(), $image_name, $image_edition, $vhd_partition_style.ToLower())
$s3_iso_key = ('iso/{0}.iso' -f $image_name)

$iso_path = ('.\{0}.iso' -f $image_name)

$cwi_url = 'https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1'
$cwi_path = '.\Convert-WindowsImage.ps1'

$vhd_path = ('.\{0}-{1}-{2}.{3}' -f $image_name, $image_edition, $vhd_partition_style.ToLower(), $vhd_format.ToLower())

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
    Copy-S3Object -BucketName $s3_bucket -Key $s3_iso_key -LocalFile $iso_path -Region $aws_region
    Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f $iso_path, $s3_bucket, $s3_iso_key) -ForegroundColor White
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
    Convert-WindowsImage -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $vhd_format -VhdPartitionStyle $vhd_partition_style -Edition $image_edition
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

# import the vhd as an ec2 snapshot
$import_task_status = @(Import-EC2Snapshot -DiskContainer_Format $vhd_format -DiskContainer_S3Bucket $s3_bucket -DiskContainer_S3Key $s3_vhd_key -Description $image_description)[0]
Write-Host -object ('snapshot import task in progress with id: {0}, progress: {1}%, status: {2}; {3}' -f $import_task_status.ImportTaskId, $import_task_status.SnapshotTaskDetail.Progress,  $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor White

# wait for snapshot import completion
while (($import_task_status.SnapshotTaskDetail.Status -ne 'completed') -and ($import_task_status.SnapshotTaskDetail.Status -ne 'deleted') -and (-not $import_task_status.SnapshotTaskDetail.StatusMessage.StartsWith('ServerError')) -and (-not $import_task_status.SnapshotTaskDetail.StatusMessage.StartsWith('ClientError'))) {
  $last_status = $import_task_status
  $import_task_status = @(Get-EC2ImportSnapshotTask -ImportTaskId $last_status.ImportTaskId)[0]
  if (($import_task_status.SnapshotTaskDetail.Status -ne $last_status.SnapshotTaskDetail.Status) -or ($import_task_status.SnapshotTaskDetail.StatusMessage -ne $last_status.SnapshotTaskDetail.StatusMessage)) {
    Write-Host -object ('snapshot import task in progress with id: {0}, progress: {1}%, status: {2}; {3}' -f $import_task_status.ImportTaskId, $import_task_status.SnapshotTaskDetail.Progress,  $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor White
  }
  Start-Sleep -Milliseconds 500
} 
if ($import_task_status.SnapshotTaskDetail.Status -ne 'completed') {
  Write-Host -object ('snapshot import failed. status: {0}; {1}' -f $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor Red
  Write-Host -object ($import_task_status.SnapshotTaskDetail | Format-List | Out-String) -ForegroundColor Red
} else {
  Write-Host -object ('snapshot import complete. snapshot id: {0}, status: {1}; {2}' -f $import_task_status.SnapshotTaskDetail.SnapshotId, $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor White
  Write-Host -object ($import_task_status.SnapshotTaskDetail | Format-List | Out-String) -ForegroundColor DarkGray

  # create an ec2 volume for each snapshot
  $snapshots = @(Get-EC2Snapshot -Filter (New-Object -TypeName Amazon.EC2.Model.Filter -ArgumentList @('description', @(('Created by AWS-VMImport service for {0}' -f $import_task_status.ImportTaskId)))))
  foreach ($snapshot in $snapshots) {
    Write-Host -object ('snapshot id: {0}, state: {1}, progress: {2}, size: {3}gb' -f $snapshot.SnapshotId, $snapshot.State, $snapshot.Progress, $snapshot.VolumeSize) -ForegroundColor White
    Write-Host -object ($snapshot | Format-List | Out-String) -ForegroundColor DarkGray
    $volume = (New-EC2Volume -SnapshotId $snapshot.SnapshotId -Size $snapshot.VolumeSize -AvailabilityZone $aws_availability_zone -VolumeType 'gp2' -Encrypted $false)
    Write-Host -object ('volume creation in progress. volume id: {0}, state: {1}' -f  $volume.VolumeId,  $volume.State) -ForegroundColor White

    # wait for volume creation to complete
    while ($volume.State -ne 'available') {
      $last_volume_state = $volume.State
      $volume = (Get-EC2Volume -VolumeId $volume.VolumeId)
      if ($last_volume_state -ne $volume.State) {
        Write-Host -object ('volume creation in progress. volume id: {0}, state: {1}' -f  $volume.VolumeId,  $volume.State) -ForegroundColor White
      }
      Start-Sleep -Milliseconds 500
    }
    Write-Host -object ($volume | Format-List | Out-String) -ForegroundColor DarkGray
  }

  # todo:
  # - create a new ec2 linux instance instatiated with any pre-existing ami
  # - detach volumes and delete them and their associated snapshots
  # - attach volumes created from vhd import
  # - boot instance with an autounattend file or sysprep configuration to complete windows install, set an administrator password
  # - install ec2config, enable userdata execution
  # - shut down instance and capture an ami
  # - delete snapshots and volumes created during vhd import
}