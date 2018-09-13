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

$ec2_instance_type = 'c5.4xlarge'
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
$aws_availability_zone = ('{0}c' -f $aws_region)

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

# download the vhd conversion script
if (Test-Path -Path $cwi_path -ErrorAction SilentlyContinue) {
  Remove-Item -Path $cwi_path -Force
}
try {
  (New-Object Net.WebClient).DownloadFile($cwi_url, $cwi_path)
  Write-Host -object ('downloaded {0} to {1}' -f $cwi_url, $cwi_path) -ForegroundColor White
} catch {
  Write-Host -object $_.Exception.Message -ForegroundColor Red
}

# delete the unattend file if it exists
if (Test-Path -Path $ua_path -ErrorAction SilentlyContinue) {
  Remove-Item -Path $ua_path -Force
}
# download the unattend file
try {
  (New-Object Net.WebClient).DownloadFile($config.unattend, $ua_path)
  Write-Host -object ('downloaded {0} to {1}' -f $config.unattend, $ua_path) -ForegroundColor White
} catch {
  Write-Host -object $_.Exception.Message -ForegroundColor Red
}

# download driver files if not on the local filesystem
$drivers = @()
foreach ($driver in $config.drivers) {
  $local_path = ('.\{0}' -f [System.IO.Path]::GetFileName($driver.key))
  if (Test-Path -Path $local_path -ErrorAction SilentlyContinue) {
    Remove-Item $local_path -Force -Recurse
    Write-Host -object ('deleted: {0}' -f $local_path) -ForegroundColor DarkGray
  }
  try {
    Copy-S3Object -BucketName $driver.bucket -Key $driver.key -LocalFile $local_path -Region $aws_region
    Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f (Resolve-Path -Path $local_path), $driver.bucket, $driver.key) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }
  $driver_target = ('.\{0}' -f $driver.target)
  if (Test-Path -Path $driver_target -ErrorAction SilentlyContinue) {
    Remove-Item $driver_target -Force -Recurse
    Write-Host -object ('deleted: {0}' -f $driver_target) -ForegroundColor DarkGray
  }
  try {
    if ($driver.extract) {
      Expand-Archive -Path $local_path -DestinationPath $driver_target
      Write-Host -object ('extracted {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $driver_target)) -ForegroundColor White
    } else {
      Copy-Item -Path (Resolve-Path -Path $local_path) -Destination $driver_target
      Write-Host -object ('copied {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $driver_target)) -ForegroundColor White
    }
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }
  $drivers += (Resolve-Path -Path ('.\{0}' -f $driver.inf)).Path
}

# delete the vhd(x) file if it exists
if (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue) {
  Remove-Item -Path $vhd_path -Force
}
# create the vhd(x) file
try {
  . .\Convert-WindowsImage.ps1
  if ($drivers.length) {
    Convert-WindowsImage -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $config.edition -UnattendPath (Resolve-Path -Path $ua_path).Path -Driver $drivers -RemoteDesktopEnable:$true
  } else {
    Convert-WindowsImage -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $config.edition -UnattendPath (Resolve-Path -Path $ua_path).Path -RemoteDesktopEnable:$true
  }
  if (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue) {
    Write-Host -object ('created {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor White
  } else {
    Write-Host -object ('failed to create {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor Red
  }
} catch {
  Write-Host -object $_.Exception.Message -ForegroundColor Red
  throw
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
      Write-Host -object ('extracted {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $mount_path_package_target)) -ForegroundColor White
    } else {
      Copy-Item -Path (Resolve-Path -Path $local_path) -Destination $mount_path_package_target
      Write-Host -object ('copied {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $mount_path_package_target)) -ForegroundColor White
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

# delete the vhd(x) file from the bucket if it exists
if (Get-S3Object -BucketName $config.vhd.bucket -Key $config.vhd.key -Region $aws_region) {
  try {
    Remove-S3Object -BucketName $config.vhd.bucket -Key $config.vhd.key -Region $aws_region -Force
    Write-Host -object ('removed {0} from bucket {1}' -f $config.vhd.key, $config.vhd.bucket) -ForegroundColor White
  } catch {
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
}

# upload the vhd(x) file
try {
  Write-S3Object -BucketName $config.vhd.bucket -File $vhd_path -Key $config.vhd.key
  Write-Host -object ('uploaded {0} to bucket {1} with key {2}' -f $vhd_path, $config.vhd.bucket, $config.vhd.key) -ForegroundColor White
} catch {
  Write-Host -object $_.Exception.Message -ForegroundColor Red
}

# import the vhd as an ec2 snapshot
$import_task_status = @(Import-EC2Snapshot -DiskContainer_Format $config.format -DiskContainer_S3Bucket $config.vhd.bucket -DiskContainer_S3Key $config.vhd.key -Description $image_description)[0]
Write-Host -object ('snapshot import task in progress with id: {0}, progress: {1}%, status: {2}; {3}' -f $import_task_status.ImportTaskId, $import_task_status.SnapshotTaskDetail.Progress,  $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor White

# wait for snapshot import completion
while (($import_task_status.SnapshotTaskDetail.Status -ne 'completed') -and ($import_task_status.SnapshotTaskDetail.Status -ne 'deleted') -and (-not $import_task_status.SnapshotTaskDetail.StatusMessage.StartsWith('ServerError')) -and (-not $import_task_status.SnapshotTaskDetail.StatusMessage.StartsWith('ClientError'))) {
  $last_status = $import_task_status
  $import_task_status = @(Get-EC2ImportSnapshotTask -ImportTaskId $last_status.ImportTaskId)[0]
  if ($import_task_status.SnapshotTaskDetail.Progress) {
    Write-Progress -Activity 'EC2 Import Snapshot' -Status ('{0}% {1} {2}' -f $import_task_status.SnapshotTaskDetail.Progress, $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -PercentComplete $import_task_status.SnapshotTaskDetail.Progress
  }
  if (($import_task_status.SnapshotTaskDetail.Status -ne $last_status.SnapshotTaskDetail.Status) -or ($import_task_status.SnapshotTaskDetail.StatusMessage -ne $last_status.SnapshotTaskDetail.StatusMessage)) {
    Write-Host -object ('snapshot import task in progress with id: {0}, progress: {1}%, status: {2}; {3}' -f $import_task_status.ImportTaskId, $import_task_status.SnapshotTaskDetail.Progress,  $import_task_status.SnapshotTaskDetail.Status, $import_task_status.SnapshotTaskDetail.StatusMessage) -ForegroundColor White
  }
  Start-Sleep -Milliseconds 500
}
Write-Progress -Activity 'EC2 Import Snapshot' -Completed
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
  $instance = (New-EC2Instance -ImageId $amazon_linux_ami_id -AvailabilityZone $aws_availability_zone -MinCount 1 -MaxCount 1 -InstanceType $ec2_instance_type -KeyName $ec2_key_pair -SecurityGroup $ec2_security_groups).Instances[0]
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
      Write-Host -object ('waiting for volume {0} to detach from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor DarkGray
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
    throw
  }

  # set DeleteOnTermination to true for all attached volumes
  try {
    $block_device_mapping_specifications = @()
    foreach ($block_device_mapping in (Get-EC2Instance -InstanceId $instance_id).Instances[0].BlockDeviceMappings) {
      $block_device_mapping_specifications += (New-Object Amazon.EC2.Model.InstanceBlockDeviceMappingSpecification -Property @{ DeviceName = $block_device_mapping.DeviceName; Ebs = New-Object Amazon.EC2.Model.EbsInstanceBlockDeviceSpecification -Property @{ DeleteOnTermination = $true; VolumeId = $block_device_mapping.Ebs.VolumeId } })
    }
    Edit-EC2InstanceAttribute -InstanceId $instance_id -BlockDeviceMapping $block_device_mapping_specifications
    Write-Host -object 'DeleteOnTermination set to true for attached volumes' -ForegroundColor White
  } catch {
    Write-Host -object 'failed to set DeleteOnTermination for attached volumes' -ForegroundColor Red
    Write-Host -object $_.Exception.Message -ForegroundColor Red
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
  $last_screenshot_time = ((Get-Date).AddSeconds(-60).ToUniversalTime())
  $last_instance_state = ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name)
  $stopwatch =  [System.Diagnostics.Stopwatch]::StartNew()
  while (((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -ne 'stopped') -and ($stopwatch.Elapsed.TotalMinutes -lt 180)) {
    if ($last_screenshot_time -le (Get-Date).ToUniversalTime().AddSeconds(-60)) {
      try {
        $new_screenshot_time = ((Get-Date).ToUniversalTime())
        $screenshot_path = ('{0}\{1}.jpg' -f $screenshot_folder_path, $new_screenshot_time.ToString("yyyyMMddHHmmss"))
        [io.file]::WriteAllBytes($screenshot_path, [convert]::FromBase64String((Get-EC2ConsoleScreenshot -InstanceId $instance_id -ErrorAction Stop).ImageData))
        $last_screenshot_time = $new_screenshot_time
        Write-Host -object ('screenshot saved to {0}' -f (Resolve-Path -Path $screenshot_path).Path) -ForegroundColor DarkGray
      } catch {
        Write-Host -object $_.Exception.Message -ForegroundColor Red
      }
    }
    $new_instance_state = ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name)
    if ($new_instance_state -ne $last_instance_state) {
      Write-Host -object ('instance {0} state change detected. previous state: {1}, current state: {2}' -f $instance_id, $last_instance_state, $new_instance_state) -ForegroundColor White
      $last_instance_state = $new_instance_state
    }
    Start-Sleep -Seconds 1
  }
  if ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -eq 'running') {
    Write-Host -object ('instance failed to stop in {0:n1} minutes. forcing stop...' -f $stopwatch.Elapsed.TotalMinutes) -ForegroundColor Cyan
    Stop-EC2Instance -InstanceId $instance_id -ForceStop
    while ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -ne 'stopped') {
      Write-Host -object 'waiting for instance to stop' -ForegroundColor DarkCyan
      Start-Sleep -Seconds 5
    }
    $local_instance_id = 'i-04332aa3f797e88ed' # todo: pull from local metadata
    $local_devices = @([char[]]([char]'f'..[char]'z')|%{('xvd{0}' -f $_)})
    # detach previous debug volumes
    foreach ($local_block_device_mapping in (Get-EC2Instance -InstanceId $local_instance_id).Instances[0].BlockDeviceMappings) {
      if ($local_devices.Contains($local_block_device_mapping.DeviceName)) {
        try {
          $detach_volume = (Dismount-EC2Volume -InstanceId $local_instance_id -Device $local_block_device_mapping.DeviceName -VolumeId $local_block_device_mapping.Ebs.VolumeId -ForceDismount:$true)
          Write-Host -object $detach_volume -ForegroundColor DarkCyan
          Write-Host -object ('detached volume {0} from {1}{2}' -f  $local_block_device_mapping.Ebs.VolumeId, $local_instance_id, $local_block_device_mapping.DeviceName) -ForegroundColor Cyan
        } catch {
          Write-Host -object ('failed to detach volume {0} from {1}{2}' -f  $local_block_device_mapping.Ebs.VolumeId, $local_instance_id, $local_block_device_mapping.DeviceName) -ForegroundColor Red
          Write-Host -object $_.Exception.Message -ForegroundColor Red
          exit
        }
        while ((Get-EC2Volume -VolumeId $local_block_device_mapping.Ebs.VolumeId).State -ne 'available') {
          Write-Host -object ('waiting for volume {0} to detach from {1}{2}' -f  $local_block_device_mapping.Ebs.VolumeId, $local_instance_id, $local_block_device_mapping.DeviceName) -ForegroundColor DarkCyan
          Start-Sleep -Milliseconds 500
        }
      }
    }
    $i = 0
    foreach ($block_device_mapping in (Get-EC2Instance -InstanceId $instance_id).Instances[0].BlockDeviceMappings) {
      try {
        $detach_volume = (Dismount-EC2Volume -InstanceId $instance_id -Device $block_device_mapping.DeviceName -VolumeId $block_device_mapping.Ebs.VolumeId -ForceDismount:$true)
        Write-Host -object $detach_volume -ForegroundColor DarkCyan
        Write-Host -object ('detached volume {0} from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor Cyan
      } catch {
        Write-Host -object ('failed to detach volume {0} from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor Red
        Write-Host -object $_.Exception.Message -ForegroundColor Red
        exit
      }
      while ((Get-EC2Volume -VolumeId $block_device_mapping.Ebs.VolumeId).State -ne 'available') {
        Write-Host -object ('waiting for volume {0} to detach from {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $instance_id, $block_device_mapping.DeviceName) -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 500
      }
      # attach volume to current instance for access to logs
      try {
        $attach_volume = (Add-EC2Volume -InstanceId $local_instance_id -VolumeId $block_device_mapping.Ebs.VolumeId -Device $local_devices[$i] -Force)
        Write-Host -object $attach_volume -ForegroundColor DarkCyan
        Write-Host -object ('attached volume {0} to {1}{2}' -f $block_device_mapping.Ebs.VolumeId, $local_instance_id, $local_devices[$i]) -ForegroundColor Cyan
      } catch {
        Write-Host -object ('failed to attach volume {0} to {1}{2}' -f  $block_device_mapping.Ebs.VolumeId, $local_instance_id, $local_devices[$i]) -ForegroundColor Red
        Write-Host -object $_.Exception.Message -ForegroundColor Red
        throw
      }
      $i++
    }
  } elseif ((Get-EC2Instance -InstanceId $instance_id).Instances[0].State.Name -eq 'stopped') {
    try {
      $ami_id = (New-EC2Image -InstanceId $instance_id -Name ('{0}-{1}' -f [System.IO.Path]::GetFileNameWithoutExtension($config.vhd.key), $image_capture_date) -Description $image_description)
      Write-Host -object ('ami {0} created from instance {1}' -f $ami_id, $instance_id) -ForegroundColor Green
    } catch {
      Write-Host -object ('failed to create ami from instance {0}' -f  $instance_id) -ForegroundColor Red
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      throw
    }
  }
  # todo:
  # - delete instances, snapshots and volumes created during vhd import
}