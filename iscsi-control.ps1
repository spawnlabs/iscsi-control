param(
	[switch] $mount, 
	$mountDriveLetter, # mount iscsi drive
	$mountIqn, # specify iscsi iqn
	$mountServer, # specify iscsi server
	[switch] $unmount, 
	$unmountDriveLetter # specify a drive letter
)

Function ListTargets 
{
	Write-Debug "querying iscsi connections"
	
  	return get-wmiobject -namespace ROOT\WMI -class MSiSCSIInitiator_TargetClass | Select -property TargetName
}

Function ListInitiatorSessions
{
	param(
		$iqns, 
		[switch] $listSessionsWithDrivesInAnyState
	)
	
	Write-Debug "listing initiator sessions"
	
	$sessions = @{}
	
	foreach ($iqn in $iqns)
	{
		$target = $iqn.TargetName
		
		if(!$target) 
		{
			continue;
		}
		
		# this is probably awful.  Basically, iqns can be an array of strings, or an array of ManagementObjects retrieved from get-wmiobject. 
		# this will get me into trouble eventually, I think
		if ($iqn.getType().ToString() -eq "System.String")
		{
			Write-Verbose "string detected"
			$target = $iqn
		}
		
		if ($listSessionsWithDrivesInAnyState) 
		{
			$result = get-wmiobject -namespace ROOT\WMI -class MSiSCSIInitiator_SessionClass -filter "TargetName='$target'" | Select -property LegacyName,SessionId		
		}
		else 
		{
			$result = (get-wmiobject -namespace ROOT\WMI -class MSiSCSIInitiator_SessionClass -filter "TargetName='$target'").Devices | Select -property LegacyName,SessionId
		}
		
		if($result)
		{
			Write-Debug "ListInitiatorSessions found drive: iqn=$iqn result=$result"
		}
		
		
		$sessions.Add($iqn, $result)
	}
	
	return $sessions
}

Function ListIscsiDrives
{
	param(
		$sessions
	)
	
	Write-Debug "listing iscsi drives"
	
	$drives = @{}
	
	foreach($key in $sessions.keys)
	{	
		if($sessions.$key.LegacyName) 
		{
			$legacyName = $sessions.$key.LegacyName
			$replacedLegacyName = $legacyName.Replace("\", "\\")
			
			$result = get-wmiobject -class "Win32_DiskDrive" -filter "DeviceId='$replacedLegacyName'"
			$drives.Add($key, $result);
		}
		else 
		{
			Write-Verbose "ListIscsiDrives: skipping $key"
		}
		
	}
	
	return $drives
}

# given a string like \\.\PhysicalDrive1, return 1 as an int
Function ParsediskNumber()
{
	param(
		$driveName
	)
	
	# driveName looks like \\.\PhysicalDrive1
	
	$suffix = "DRIVE"
	
	$index = $driveName.ToUpper().IndexOf($suffix)
	
	if($index -eq -1) 
	{
		Write-Error "unexpected driveName: $driveName"
		exit 1
	}
	
	return $driveName.Substring($index + $suffix.Length) -as [int]
}

Function GetDriveLetter()
{
	param(
		$diskNumber
	)
	
	$result = get-wmiobject -query "associators of {Win32_DiskPartition.DeviceID='Disk #$diskNumber, Partition #0'} WHERE ResultClass=Win32_LogicalDisk";
	
	$letter = $null
	
	if($result.DeviceId) 
	{
		$index = $result.DeviceId.IndexOf(':')
		
		if($index -gt 0) 
		{
			$letter = $result.DeviceId.Substring(0, $index)
		}
	}
	
	return $letter;
}



Function UnmountVolume
{	
	param(
		$driveLetter = $(throw "-driveLetter required.")			
	)
	
	Write-Debug "unmounting volume behind $driveLetter"
	
	$driveLetterWithColon = $driveLetter + ":"
	Invoke-Expression "mountvol.exe $driveLetterWithColon /D"
}

Function OfflineDisk
{
	param(
		$diskNumber = $(throw "-diskNumber required.")			
	)
	
	# offline the disk now so that we can remove iscsi target later
	$cmd = @()
	$cmd += "select disk $diskNumber"
	$cmd += "offline disk"
	
	Write-Verbose "offlining disk $diskNumber"
	
	RunDiskPart -cmds $cmd
	
	# needed after offlining; iscsicli doesn't immediately detect this
	Start-Sleep -Seconds 1
}

Function RemoveTarget
{
	param(
		$iqn
	)
	
	$iqns = @($iqn)
	
	
	$sessions = ListInitiatorSessions -iqns $iqns -listSessionsWithDrivesInAnyState
    
	$sessionId = $sessions.$iqn.SessionId
	
	if($sessionId)
	{
		Invoke-Expression "iscsicli logouttarget $sessionId"
		Start-Sleep -Seconds 1
	}
	
	Write-Verbose "removing target $iqn"
	Invoke-Expression "iscsicli removetarget $iqn"			
	Start-Sleep -Seconds 1
}

Function AttachTarget
{
	param(
		$iqn = $(throw "-iqn required"),
		$server = $(throw "-server required")
	)
	
	Write-Verbose "adding target $iqn $server"
	Invoke-Expression "iscsicli QAddTarget $iqn $server"
	
	Start-Sleep -Seconds 1
}

Function LoginTarget
{
	param(
		$iqn = $(throw "-iqn required")
	)
	
	Write-Verbose "logging in target $iqn"
	Invoke-Expression "iscsicli QLoginTarget $iqn"
	
	Start-Sleep -Seconds 2	
}

Function HandleUnmount
{
	param(
		$driveLetter = $(throw "-driveLetter required"),
		$iqn = $(throw "-iqn required"), 
		$diskNumber = $(throw "-diskNumber required")
	)
	
	Write-Debug "HandleUnmount starting of drive $driveLetter and iqn $iqn..."
	
    UnmountVolume -driveLetter $driveLetter
	OfflineDisk -diskNumber $diskNumber
	RemoveTarget -iqn $iqn 
}

# if driveLetter not specified, all iscsi controlled mounts are removed
# if driveLetter is specified, only that drive will be removed
Function Unmount 
{
	param(
		$driveLetter
	)
		
	$mounts = GetMountState
	
	foreach($mount in $mounts)
	{
		if($driveLetter)
		{
			# if the mount has a drive letter, and it matches what was supplied by the user, unmount it
			if($mount.driveLetter -and ($mount.driveLetter.ToUpper() -eq $driveLetter.ToUpper()))
			{
				HandleUnmount -driveLetter $driveLetter -iqn $mount.iqn -diskNumber $mount.diskNumber
			}
		}
		else
		{
			# no drive letter specified by caller, so if we find a mount with a drive letter, whack it
			if($mount.driveLetter)
			{
				HandleUnmount -driveLetter 	$mount.driveLetter -iqn $mount.iqn -diskNumber $mount.diskNumber
			}
		}
	}
	
	$mounts = GetMountState
	
	
	# verify that we did indeed unmount the drive
	foreach($mount in $mounts)
	{
		if($driveLetter)
		{
			# if the mount has a drive letter, and it matches what was supplied by the user, unmount it
			if($mount.driveLetter -and ($mount.driveLetter.ToUpper() -eq $driveLetter.ToUpper()))
			{
				throw "found $driveLetter after tryping to unmount it"
			}
		}
		else
		{
			
			if($mount.driveLetter)
			{
				$foundDriveLetter = $mount.driveLetter
				throw "found $foundDriveLetter after trying to unmount all iscsi drives"
			}
		}
	}
	
	
}

Function RunDiskPart
{
	param(
		$cmds = $(throw "-cmds required")
	)
	
	$cmd = ""
	
	for($i = 0; $i -lt $cmds.length; $i++)
	{
		$cmd += $cmds[$i]
		
		if($i -lt $cmds.length - 1)
		{
			$cmd += "`n"
		}
	}
	
	Write-Debug "running disk part command: $cmd"
	
	$cmd | diskpart
}

Function MountDisk
{
	param(
		$diskNumber = $(throw "-diskNumber required"),
		$driveLetter = $(throw "-driveLetter required")
	)	
	
	$cmd = @()
	$cmd += "select disk $diskNumber"
	$cmd += "online disk noerr"
	$cmd += "select part 1"
	$cmd += "assign letter=$driveLetter"
	$cmd += "list volume"
	
	Write-Debug "mounting disk $diskNumber against drive letter $driveLetter"
	
	RunDiskPart -cmds $cmd
	
	Start-Sleep -Seconds 1
}

Function FormatAndMountDisk
{
	param(
		$diskNumber = $(throw "-diskNumber required"),
		$driveLetter
	)
	
	$cmd = @()
	$cmd += "select disk $diskNumber"
	$cmd += "online disk noerr"
	$cmd += "attributes disk clear readonly noerr"
	$cmd += "create partition primary noerr"
	$cmd += "select part 1"
	$cmd += "format fs=ntfs label=iscsi quick"
	
	if($driveLetter)
	{
		$cmd += "assign letter=$driveLetter"
	}

	$cmd += "list volume"

	
	Write-Debug "formating and mounting disk $diskNumber against drive letter $driveLetter"
	
	RunDiskPart -cmds $cmd
	
	Start-Sleep -Seconds 1
}

Function HandleMount
{
	param(	
		$driveLetter = $(throw "-driveLetter required"),			
		$iqn = $(throw "-iqn required."),			
		$server = $(throw "-server required.")			
	)
	
	Write-Debug "attempting to mounte $driveLetter against $iqn and $server"
	
	AttachTarget -iqn $iqn -server $server
	LoginTarget -iqn $iqn
	
	$mounts = GetMountState
	
	$found = $false
	
	# validate that we can find the connection after the fact, and see if we need to format
	foreach($mount in $mounts)
	{
		if($mount.iqn -eq $iqn)
		{
			$found = $true
			if(!$mount.connected)
			{
				throw "iscsi not connected after trying to attach/login the target. server=$server, iqn=$iqn"
			}
			
			if($mount.initialized)
			{
				MountDisk -diskNumber $mount.diskNumber -driveLetter $driveLetter
			}
			else 
			{
				FormatAndMountDisk -diskNumber $mount.diskNumber -driveLetter $driveLetter
			}
		}
	}
	if(!$found)
	{
		throw "unable to find any evidence of iqn after attempting to attach/login the target"
	}
	
	
	# validate that we can find the drive after the fact
	$mounts = GetMountState
	$found = $false
	foreach($mount in $mounts)
	{
		if($mount.iqn -eq $iqn)
		{
			$found = $true
			if(!$mount.driveLetter)
			{
				throw "drive letter not found after trying to mount the disk. server=$server, iqn=$iqn"
			}
		}
	}
	
	if(!$found)
	{
		throw "unable to find any evidence of drive after attempting to mount the disk"
	}
	
}

Function Mounter
{
	param(
		$mountDriveLetter = $(throw "-mountDriveLetter required."),			
		$mountIqn = $(throw "-mountIqn required."),			
		$mountServer = $(throw "-mountServer required.")			
	)
	
	$mounts = GetMountState
	
	# if we need to unmount a previous drive at this location, do so
	foreach($mount in $mounts)
	{
		# if the mount has a drive letter, and it matches what was supplied by the user, unmount it
		if($mount.driveLetter -and ($mount.driveLetter.ToUpper() -eq $mountDriveLetter.ToUpper()))
		{
			Write-Debug "unmounting $mount because we need to make a new mount with $mountIqn"
			HandleUnmount -driveLetter $mountDriveLetter -iqn $mount.iqn -diskNumber $mount.diskNumber
		}
	}
	
	HandleMount -driveLetter $mountDriveLetter -iqn $mountIqn -server $mountServer
}

Function GetMountState 
{
# Procedure: 
#  List all IQNs attached to the machine
#  Find which IQN correspond to drives
#  Find all drives
#  Then correlate the mess

   	#Set-StrictMode -Version 2
   	$VerbosePreference = 'Continue'
   	$DebugPreference = 'Continue'
	$iqns = ListTargets
	$sessions = ListInitiatorSessions -iqns $iqns
	$drives = ListIscsiDrives -sessions $sessions
	
	$mounts = @()
	
	foreach($iqn in $iqns)
	{
		$mount = @{ 
			"iqn" = $iqn.TargetName;
			"connected" = $null;
			"size" = $null;
			"initialized" = $null; 
			"driveLetter" = $null;
			"diskName" = $null;
			"diskNumber" = $null
		}
		
		$mounts += $mount;
		
		# find a iscsi session
		foreach($sessionKey in $sessions.Keys)
		{
			if($iqn -eq $sessionKey) 
			{
				if($sessions.$sessionKey)
				{
					$mount.connected = $true
				
					$session = $sessions.$sessionKey
					# we have an action session; let's correlate the drive now
					foreach($driveKey in $drives.Keys)
					{
						$drive = $drives.$driveKey
						
						if($session.LegacyName.ToUpper() -eq $drive.DeviceID.ToUpper()) 
						{
							$diskNumber = ParsediskNumber -driveName $drive.DeviceId

							$mount.size = $drive.Size
							$mount.initialized = ($drive.Partitions -as [int]) -gt 0
							$mount.diskName = $drive.DeviceId
							$mount.diskNumber = $diskNumber
						
							$driveLetter = GetDriveLetter -diskNumber $diskNumber
							$mount.driveLetter = $driveLetter;
						}
							
						break;	
					}
				}
				else 
				{
					Write-Verbose "no session found for iqn $iqn"
				}
				
				break;
			}
		}

	}

	return $mounts

}

if($mount)
{
	Mounter -mountDriveLetter $mountDriveLetter -mountIqn $mountIqn -mountServer $mountServer
}
elseif($unmount)
{
	Unmount -driveLetter $unmountDriveLetter
}
else 
{
	return GetMountState
}


# iqn.1986-03.com.sun:02:53d9bbce-0836-6928-d631-968c49b46b40
