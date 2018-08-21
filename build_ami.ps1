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

$ec2_key_pair = 'mozilla-taskcluster-worker-gecko-t-win10-64'
$ec2_security_groups = @('ssh-only', 'rdp-only')

$manifest = (Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/grenade/relops_image_builder/master/manifest.json?{0}' -f [Guid]::NewGuid()) -UseBasicParsing | ConvertFrom-Json)
$config = @($manifest | Where-Object {
  $_.os -eq 'Windows' -and
  $_.build.major -eq 10 -and
  $_.build.release -eq 17134 -and
  $_.version -eq 1803 -and
  $_.edition -eq 'Professional' -and
  $_.language -eq 'en-US'
})[0]

$image_capture_date = ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
$image_description = ('{0} {1} ({2}) - edition: {3}, language: {4}, partition: {5}, captured: {6}' -f $config.os, $config.build.major, $config.version, $config.edition, $config.language, $config.partition, $image_capture_date)

$aws_region = 'us-west-2'
$aws_availability_zone = ('{0}a' -f $aws_region)

$cwi_url = 'https://raw.githubusercontent.com/grenade/relops_image_builder/master/Convert-WindowsImage.ps1'
$cwi_path = ('.\{0}' -f [System.IO.Path]::GetFileName($cwi_url))
$ua_path = ('.\{0}' -f [System.IO.Path]::GetFileName($config.unattend))
$iso_path = ('.\{0}' -f [System.IO.Path]::GetFileName($config.iso.key))
$vhd_path = ('.\{0}' -f [System.IO.Path]::GetFileName($config.vhd.key))

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
    Copy-S3Object -BucketName $config.iso.bucket -Key $config.iso.key -LocalFile $iso_path -Region $aws_region
    Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f $iso_path, $config.iso.bucket, $config.iso.key) -ForegroundColor White
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

# download the unattend file if not on the local filesystem
if (-not (Test-Path -Path $ua_path -ErrorAction SilentlyContinue)) {
  try {
    (New-Object Net.WebClient).DownloadFile($config.unattend, $ua_path)
    Write-Host -object ('downloaded {0} to {1}' -f $config.unattend, $ua_path) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('unattend file detected at: {0}' -f $ua_path) -ForegroundColor DarkGray
}

# create the vhd(x) file if it is not on the local filesystem
if (-not (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue)) {
  try {
    . .\Convert-WindowsImage.ps1
    Convert-WindowsImage -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $config.edition -UnattendPath (Resolve-Path -Path $ua_path).Path -RemoteDesktopEnable:$true
    if (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue) {
      Write-Host -object ('created {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor White
    } else {
      Write-Host -object ('failed to create {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor Red
    }
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }
} else {
  Write-Host -object ('vhd detected at: {0}' -f $vhd_path) -ForegroundColor DarkGray
}

# mount the vhd and create a temp directory
$mount_path = (Join-Path -Path $env:SystemDrive -ChildPath ([System.Guid]::NewGuid().Guid))
New-Item -Path $mount_path -ItemType directory -force
Mount-WindowsImage -ImagePath $vhd_path -Path $mount_path -Index 1

# download package files if not on the local filesystem
foreach ($package in $config.packages) {
  $local_path = ('.\{0}' -f [System.IO.Path]::GetFileName($package.key))
  if (-not (Test-Path -Path $local_path -ErrorAction SilentlyContinue)) {
    try {
      Copy-S3Object -BucketName $package.bucket -Key $package.key -LocalFile $local_path -Region $aws_region
      Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f (Resolve-Path -Path $local_path), $package.bucket, $package.key) -ForegroundColor White
    } catch {
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      throw
    }
  } else {
    Write-Host -object ('package file detected at: {0}' -f (Resolve-Path -Path $local_path)) -ForegroundColor DarkGray
  }
  $mount_path_package_target = (Join-Path -Path $mount_path -ChildPath $package.target)
  try {
    if ($package.extract) {
      Expand-Archive -Path $local_path -DestinationPath $mount_path_package_target
      Write-Host -object ('extracted {0} to {1}' -f (Resolve-Path -Path $local_path), $mount_path_package_target) -ForegroundColor White
    } else {
      Copy-Item -Path (Resolve-Path -Path $local_path) -Destination $mount_path_package_target
      Write-Host -object ('copied {0} to {1}' -f (Resolve-Path -Path $local_path), $mount_path_package_target) -ForegroundColor White
    }
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }
}
# unmount the vhd, save it and remove the mount point
try {
  Dismount-WindowsImage -Path $mount_path -Save
  Write-Host -object ('dismount of {0} from {1} complete' -f $vhd_path, $mount_path) -ForegroundColor White
  Remove-Item -Path $mount_path -Force
} catch {
  Write-Host -object $_.Exception.Message -ForegroundColor Red
  throw
}

# upload the vhd(x) file if it is not in the s3 bucket
if (-not (Get-S3Object -BucketName $config.vhd.bucket -Key $config.vhd.key -Region $aws_region)) {
  try {
    Write-S3Object -BucketName $config.vhd.bucket -File $vhd_path -Key $config.vhd.key
    Write-Host -object ('uploaded {0} to bucket {1} with key {2}' -f $vhd_path, $config.vhd.bucket, $config.vhd.key) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('vhd detected in bucket {0} with key {1}' -f $config.vhd.bucket, $config.vhd.key) -ForegroundColor DarkGray
}

# import the vhd as an ec2 snapshot
$import_task_status = @(Import-EC2Snapshot -DiskContainer_Format $config.format -DiskContainer_S3Bucket $config.vhd.bucket -DiskContainer_S3Key $config.vhd.key -Description $image_description)[0]
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

  $snapshots = @(Get-EC2Snapshot -Filter (New-Object -TypeName Amazon.EC2.Model.Filter -ArgumentList @('description', @(('Created by AWS-VMImport service for {0}' -f $import_task_status.ImportTaskId)))))
  Write-Host -object ('{0} snapshot{1} extracted from {2}' -f  $snapshots.length, $(if ($snapshots.length -gt 1) { 's' } else { '' }), $config.format) -ForegroundColor White
  Write-Host -object ($snapshots | Format-Table | Out-String) -ForegroundColor DarkGray

  # create an ec2 volume for each snapshot
  $volumes = @()
  foreach ($snapshot in $snapshots) {
    $snapshot = (Get-EC2Snapshot -SnapshotId $snapshot.SnapshotId)
    while ($snapshot.State -ne 'completed') {
      Write-Host -object 'waiting for snapshot availability' -ForegroundColor DarkGray
      Start-Sleep -Seconds 1
      $snapshot = (Get-EC2Snapshot -SnapshotId $snapshot.SnapshotId)
    }
    Write-Host -object ('snapshot id: {0}, state: {1}, progress: {2}, size: {3}gb' -f $snapshot.SnapshotId, $snapshot.State, $snapshot.Progress, $snapshot.VolumeSize) -ForegroundColor White
    $volume = (New-EC2Volume -SnapshotId $snapshot.SnapshotId -Size $snapshot.VolumeSize -AvailabilityZone $aws_availability_zone -VolumeType 'gp2' -Encrypted $false)
    Write-Host -object ('volume creation in progress. volume id: {0}, state: {1}' -f  $volume.VolumeId, $volume.State) -ForegroundColor White

    # wait for volume creation to complete
    while ($volume.State -ne 'available') {
      $last_volume_state = $volume.State
      $volume = (Get-EC2Volume -VolumeId $volume.VolumeId)
      if ($last_volume_state -ne $volume.State) {
        Write-Host -object ('volume creation in progress. volume id: {0}, state: {1}' -f $volume.VolumeId, $volume.State) -ForegroundColor White
      }
      Start-Sleep -Milliseconds 500
    }
    $volumes += $volume
    Write-Host -object ($volume | Format-List | Out-String) -ForegroundColor DarkGray
  }
  $volume_zero = $volumes[0].VolumeId

  # create a new ec2 linux instance instantiated with a pre-existing ami
  $amazon_linux_ami_id = (Get-EC2Image -Owner 'amazon' -Filter @((New-Object -TypeName Amazon.EC2.Model.Filter -ArgumentList @('description', @(('Amazon Linux 2 AMI * HVM gp2'))))))[0].ImageId
  $instance = (New-EC2Instance -ImageId $amazon_linux_ami_id -AvailabilityZone $aws_availability_zone -MinCount 1 -MaxCount 1 -InstanceType 'c4.4xlarge' -KeyName $ec2_key_pair -SecurityGroup $ec2_security_groups).Instances[0]
  $instance_id = $instance.InstanceId
  Write-Host -object ('instance {0} created with ami {1}' -f  $instance_id, $amazon_linux_ami_id) -ForegroundColor White
  while ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -ne 'running') {
    Write-Host -object 'waiting for instance to start' -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
  }
  $device_zero = (Get-EC2Instance -InstanceId $instance_id).Instances[0].BlockDeviceMappings[0].DeviceName
  Stop-EC2Instance -InstanceId $instance_id -ForceStop
  while ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -ne 'stopped') {
    Write-Host -object 'waiting for instance to stop' -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
  }

  # detach and delete volumes and associated snapshots
  foreach ($block_device_mapping in (Get-EC2Instance -InstanceId $instance_id).Instances[0].BlockDeviceMappings) {
    try {
      $detach_volume = (Dismount-EC2Volume -InstanceId $instance_id -Device $block_device_mapping.DeviceName -VolumeId $block_device_mapping.Ebs.VolumeId -ForceDismount:$true)
      Write-Host -object $detach_volume -ForegroundColor DarkGray
      Write-Host -object ('detached volume {0} from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor White
    } catch {
      Write-Host -object ('failed to detach volume {0} from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor Red
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      exit
    }
    while ((Get-EC2Volume -VolumeId $block_device_mapping.Ebs.VolumeId).State -ne 'available') {
      Start-Sleep -Milliseconds 500
    }
    Remove-EC2Volume -VolumeId $block_device_mapping.Ebs.VolumeId -PassThru -Force
  }

  # attach volume from vhd import (todo: handle attachment of multiple volumes)
  try {
    $attach_volume = (Add-EC2Volume -InstanceId $instance_id -VolumeId $volume_zero -Device $device_zero -Force)
    Write-Host -object $attach_volume -ForegroundColor DarkGray
    Write-Host -object ('attached volume {0} to {1}{2}' -f $volume_zero, $instance_id, $device_zero) -ForegroundColor White
  } catch {
    Write-Host -object ('failed to attach volume {0} to {1}{2}' -f  $volume_zero, $instance_id, $device_zero) -ForegroundColor Red
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    exit
  }

  try {
    Edit-EC2InstanceAttribute -InstanceId $instance_id -EnaSupport $true
    Write-Host -object ('enabled ena support attribute on instance {0}' -f $instance_id) -ForegroundColor DarkGray
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }

  Start-EC2Instance -InstanceId $instance_id
  $screenshot_folder_path = ('.\{0}' -f $instance_id)
  New-Item -ItemType Directory -Force -Path $screenshot_folder_path
  while (@(Get-ChildItem -Path ('{0}\*.jpg' -f $screenshot_folder_path)).length -lt 20) {
    try {
      $screenshot_path = ('{0}\{1}.jpg' -f $screenshot_folder_path, [DateTime]::UtcNow.ToString("yyyyMMddHHmmss"))
      [io.file]::WriteAllBytes($screenshot_path, [convert]::FromBase64String((Get-EC2ConsoleScreenshot -InstanceId $instance_id -ErrorAction Stop).ImageData))
      Write-Host -object ('screenshot saved to {0}' -f $screenshot_path) -ForegroundColor DarkGray
    } catch {
      Write-Host -object $_.Exception.Message -ForegroundColor Red
    }
    Start-Sleep -Seconds 60
  }

  # todo:
  # - configure ec2config: enable userdata execution
  # - shut down instance and capture an ami
  # - delete instances, snapshots and volumes created during vhd import
}