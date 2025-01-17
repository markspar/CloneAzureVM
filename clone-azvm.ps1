﻿#Requires -Version 5.0

[CmdletBinding()]
Param(
    # REQUIRED input:
    [Parameter(Mandatory=$true)][string]$sourceResourceGroupName,
    [Parameter(Mandatory=$true)][string]$sourceSubscriptionId,
    [Parameter(Mandatory=$true)][string]$sourceVmName, # VM to be cloned.
    [Parameter(Mandatory=$true)][string]$destinationVNetName, # Existing VNet name. Make sure it's in the same region as destination RG.

    # OPTIONAL input:
    [string]$destinationVNetResourceGroupName = '', # Optional. Leave empty if it's the same as sourceResourceGroupName.
    [string]$destinationSubnetName = '', # Optional. Leave empty if it's the same name as the source subnet name.
    [string]$destinationLocation = '', # Optional. If specified, it overrides the default location which is the location of the destination resource group. If left empty, the destination resource group's location is picked.
    [string]$destinationResourceGroupName = '', # Optional. If specified and non-exiting, it will be created in the same region as the source RG. If left empty, sourceResourceGroupName is used.
    [string]$destinationSubscriptionId = '', # Optional. If left empty, sourceSubscriptionId is used.
    [string]$existingAvailabilitySetName = '', # Relevant only when $useExistingAvailabilitySet is $true. Leave empty to use the source availability set if the destination RG is the same as source RG. Set to an existing availability set's name to add the cloned VM to.
    [string]$sourceVmOsDiskSnapshotName = '', # Optional. If specified, it must be in sourceVmSnapshotResourceGroup. If left empty, a snapshot will be created for every disk. Example: 'snapshot-os-1039651728'.
    [string]$sourceVmDataDiskSnapshotName = '', # Optional. If specified, it must be in sourceVmSnapshotResourceGroup. Specify with sourceVmOsDiskSnapshotName. Example: 'snapshot-data0-1039651728'.
    [string]$sourceVmSnapshotResourceGroup = '', # Optional. If specified, it must be an existing resource group. If left empty, sourceResourceGroupName is used.
    [string]$destinationVmName = '', # Optional. Leave empty to assign a unique name.
    [switch]$keepSourceComputerNameInOsProfile = $false, # Default is $false. Set to $true to keep the computer name the same as the source. The default is to specify a new name (up to 15 characters long).
    [switch]$setAcceleratedNetworking = $false, # Default is $false. Set to $true to force accelerated networking to be set on the cloned NIC(s). If accelerated networking is already configured on the source NIC, then it will be created on the target regardless of this setting.
    [switch]$useExistingAvailabilitySet = $true, # Default is $true. Set to $false to have a new availability set created for the cloned VM. Default is to add the cloned VM to the same availability set as the original VM if the destination RG is same as source or add it to the $existingAvailabilitySetName if destination RG is different and $existingAvailabilitySetName is specified, otherwise create a new availability set in destination RG.
    [switch]$copyTags = $false, # Default is $false. Set to $true to have resource tags copied over to the cloned resource.
    [switch]$SkipRequiredModulesCheck = $true,
    [switch]$stopSourceVMs = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$error.Clear()
$ScriptStartDate=(Get-Date)

### Function Declarations ###

function Install-RequiredModules {
	Write-Output 'Setting PSGallery as a trusted repository...'
	Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted

	Write-Output 'Checking required modules and module versions are installed...'
	$modules=@(@{Name='Az.Profile'; Version='0.7.0'}, @{Name='Az.Resources'; Version='3.5.0'}, @{Name='Az.Compute'; Version='4.12.0'}, @{Name='Az.Network'; Version='4.7.0'})
	foreach($module in $modules) 
	{
		if (!(Get-Module -Name $module["Name"] -ListAvailable) )
		{
			Write-Verbose ("Installing New PowerShell Module {0} ({1})`r`n" -f $module["Name"], $module["Version"])
			Install-Module $module["Name"] -Scope CurrentUser -Force -AllowClobber -RequiredVersion $module["Version"]
		}
		else
		{
			Write-Verbose ("Installing/Upgrading Existing PowerShell Module {0} ({1})`r`n" -f $module["Name"], $module["Version"])
			Install-Module $module["Name"] -Scope CurrentUser -AllowClobber -MinimumVersion $module["Version"]
		}
	}
	Write-Output 'Done checking required modules and module versions are installed.'
}

# Similar to the UniqueString ARM function (Source: https://blogs.technet.microsoft.com/389thoughts/2017/12/23/get-uniquestring-generate-unique-id-for-azure-deployments/).
function Get-UniqueString ([string]$id, $length=13)
{
    $hashArray = (new-object System.Security.Cryptography.SHA512Managed).ComputeHash($id.ToCharArray()) 
    -join ($hashArray[1..$length] | ForEach-Object { [char]($_ % 26 + [byte][char]'a') }) 
}

### Main Script ###

# Install required modules and versions.
if ($SkipRequiredModulesCheck -eq $false)
{
	Install-RequiredModules
}
else
{
	Write-Output "Skipped checking required modules and module versions. Reason: SkipRequiredModulesCheck=$SkipRequiredModulesCheck."
}

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

# Make sure the user is logged in.
Write-Output 'Checking if the user is logged in...'
if (!(Get-AzContext))
{
	Write-Output 'User is not logged in. Attempting to log in...'
	Connect-AzAccount
}

if ($null -eq $sourceSubscriptionId -or $sourceSubscriptionId -eq '')
{
    Write-Host "Error: Source subscription id not specified." -ForegroundColor Red
    exit 1
}

if($null -eq $destinationSubscriptionId -or $destinationSubscriptionId -eq '')
{
    $destinationSubscriptionId = $sourceSubscriptionId
}

Write-Output "Setting a context for Source Subscription Id: $sourceSubscriptionId"
$sourceSubscriptionContext = Set-AzContext -SubscriptionId "$sourceSubscriptionId"
Write-Output "Setting a context for Destination Subscription Id: $destinationSubscriptionId"
$destinationSubscriptionContext = Set-AzContext -SubscriptionId "$destinationSubscriptionId"

# Step 1: Get the source resource group.
$sourceResourceGroup = Get-AzResourceGroup -Name $sourceResourceGroupName -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue
if ($null -eq $sourceResourceGroup)
{
    Write-Host "Error: Resource group '$sourceResourceGroupName' not found: $error" -ForegroundColor Red
    exit 1
}
$sourceResourceGroupName = $sourceResourceGroup.ResourceGroupName

# Step 2: Get destination resource group.
if($null -eq $destinationResourceGroupName -or $destinationResourceGroupName -eq '')
{
    $destinationResourceGroup = $sourceResourceGroup
}
else
{
    $destinationResourceGroup = Get-AzResourceGroup -Name $destinationResourceGroupName -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
    if ($null -eq $destinationResourceGroup)
    {
        Write-Host "Warning: Resource group '$destinationResourceGroupName' not found. It will be created: $error" -ForegroundColor Yellow
        Write-Host "Creating resource group '$destinationResourceGroupName'..."
        $destinationResourceGroup = New-AzResourceGroup -Name $destinationResourceGroupName -AzContext $destinationSubscriptionContext -Location $sourceResourceGroup.Location -Verbose -Force -ErrorAction SilentlyContinue
        if ($null -eq $destinationResourceGroup -or $destinationResourceGroup -eq '')
        {
            Write-Host "Error: Failed to created resource group '$destinationResourceGroupName': $error" -ForegroundColor Red
            exit 1
        }
    }
}
$destinationResourceGroupName = $destinationResourceGroup.ResourceGroupName

# Step 3: Get source VM to be cloned.
$sourceVm = Get-AzVM -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue
if ($null -eq $sourceVm)
{
    Write-Host "Error: VM '$sourceVmName' not found in Resource Group '$sourceResourceGroupName': $error" -ForegroundColor Red
    exit 1
}
if ($stopSourceVMs)
{
    Write-Host "Stopping/de-allocating source VM"
    Set-AzContext -Context $sourceSubscriptionContext
    stop-azvm -id $sourcevm.id -Force
}

# Step 4: Get the VNet.
if ($null -eq $destinationVNetResourceGroupName -or $destinationVNetResourceGroupName -eq '')
{
    $destinationVNetResourceGroupName = $sourceResourceGroupName
}

$destinationVNet = Get-AzVirtualNetwork -Name $destinationVNetName -ResourceGroupName $destinationVNetResourceGroupName -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
if ($null -eq $destinationVNet)
{
    Write-Host "Error: VNet '$destinationVNetName' not found in Resource Group '$destinationVNetResourceGroupName'." -ForegroundColor Red
    exit 1
}

# Location where cloned resources will be created.
if ($null -eq $destinationLocation -or $destinationLocation -eq '')
{
    $destinationLocation = $destinationResourceGroup.Location
    Write-Host "Destination resource group: '$destinationResourceGroupName'. Location: '$destinationLocation'."
}
else
{
    Write-Host "Destination location specified: '$destinationLocation'."
}

# Random number suffix used in unique resource naming.
$randomNumber = Get-Random -Minimum 100000000 -Maximum 999999999

# Step 5: Get existing snapshot or create snapshots now.
$snapshots = @()
if ($null -eq $sourceVmOsDiskSnapshotName -or $sourceVmOsDiskSnapshotName -eq '')
{
    # Compare the destination RG's region to the region of the source VM (which is also the region on the source VM's disks).
    # They must be the same for creating a snapshot in the destination RG.
    if ($destinationLocation -ne $sourceVm.Location)
    {
        $snapshotLocation = $sourceVm.Location
        Write-Host "Snapshots will be created in '$snapshotLocation' since destination RG '$destinationResourceGroupName' is in a different region ('$destinationLocation')."
    }
    else
    {
        $snapshotLocation = $destinationLocation
        Write-Host "Snapshots will be created in destination RG ($destinationResourceGroupName)."
    }

    # Step 5-a-1: Create a snapshot of the OS disk (in the destination Resource Group, in case you have limited IAM in source).
    $osDiskName = $sourceVm.StorageProfile.OsDisk.Name
    Write-Host "OS Disk found: $osDiskName"
    $sourceVmOsDiskSnapshotName = "snapshot-os-$randomNumber"  
    Write-Host "Creating snapshot '$sourceVmOsDiskSnapshotName' in '$destinationResourceGroupName'..."

    $snapshotConfig = New-AzSnapshotConfig -Location $snapshotLocation -AccountType Standard_LRS -OsType $sourceVm.StorageProfile.OsDisk.OsType -CreateOption Copy -EncryptionSettingsEnabled $false -SourceResourceId $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
    if ($null -eq $snapshotConfig)
    {
        Write-Host "Error: Cannot create OS disk snapshot config '$sourceVmOsDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
        exit 1
    }

    $snapshot = New-AzSnapshot -SnapshotName $sourceVmOsDiskSnapshotName -ResourceGroupName $destinationResourceGroupName -Snapshot $snapshotConfig -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
    if ($null -eq $snapshot)
    {
        Write-Host "Error: Cannot create OS disk snapshot '$sourceVmOsDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
        exit 1
    }

    Write-Output 'Snapshot created: ', $snapshot
    $snapshotName = $snapshot.Name
    Write-Host "Snapshot successfully created for OS disk: $snapshotName"
    
    $snapshots += $snapshot

    # Step 5-a-2: For each data disk in the source VM, create a snapshot.
    foreach($disk in $sourceVm.StorageProfile.DataDisks)
    {
        $lun = $disk.Lun
        $diskName = $disk.Name
        Write-Host "Data Disk found (lun $lun): $diskName"
        $sourceVmDataDiskSnapshotName = "snapshot-data$lun-$randomNumber"
        Write-Host "Creating snapshot '$sourceVmDataDiskSnapshotName' in '$destinationResourceGroupName'..."

        $snapshotConfig = New-AzSnapshotConfig -Location $snapshotLocation -AccountType Standard_LRS -CreateOption Copy -EncryptionSettingsEnabled $false -SourceResourceId $disk.ManagedDisk.Id -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
        $snapshot = New-AzSnapshot -SnapshotName $sourceVmDataDiskSnapshotName -ResourceGroupName $destinationResourceGroupName -Snapshot $snapshotConfig -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
        if ($null -eq $snapshot)
        {
            Write-Host "Error: Cannot create data disk snapshot '$sourceVmDataDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
            exit 1
        }

        Write-Output 'Snapshot created: ', $snapshot
        $snapshotName = $snapshot.Name
        Write-Host "Snapshot successfully created for data disk: $snapshotName"

        $snapshots += $snapshot
    }
}
else
{
    if ($null -eq $sourceVmSnapshotResourceGroup -or $sourceVmSnapshotResourceGroup -eq '')
    {
        $sourceVmSnapshotResourceGroup = $sourceResourceGroupName
    }

    # Step 5-b-1: Get the existing snapshot of the source VM's OS disk.
    $snapshot = Get-AzSnapshot -SnapshotName $sourceVmOsDiskSnapshotName -ResourceGroupName $sourceVmSnapshotResourceGroup -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue
    if ($null -eq $snapshot)
    {
        Write-Host "Error: OS disk snapshot '$sourceVmOsDiskSnapshotName' not found in Resource Group '$sourceVmSnapshotResourceGroup'." -ForegroundColor Red
        exit 1
    }

    Write-Host "Snapshot found: $sourceVmOsDiskSnapshotName"
    Write-Output 'Snapshot: ', $snapshot

    $snapshots += $snapshot

    if ($null -ne $sourceVmDataDiskSnapshotName -and $sourceVmDataDiskSnapshotName -ne '')
    {
        # Step 5-b-2: Get the existing snapshot of the source VM's data disk.
        $snapshot = Get-AzSnapshot -SnapshotName $sourceVmDataDiskSnapshotName -ResourceGroupName $sourceVmSnapshotResourceGroup -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue
        if ($null -eq $snapshot)
        {
            Write-Host "Error: Data disk snapshot '$sourceVmDataDiskSnapshotName' not found in Resource Group '$sourceVmSnapshotResourceGroup'." -ForegroundColor Red
            exit 1
        }

        Write-Host "Snapshot found: $sourceVmDataDiskSnapshotName"
        Write-Output 'Snapshot: ', $snapshot

        $snapshots += $snapshot
    }
}

if ($snapshots.Length -eq 0)
{
    Write-Host "Error: No snapshots found or created." -ForegroundColor Red
    exit 1
}

# Step 6: Give the new VM a unique name.
if (($null -eq $destinationVmName -or $destinationVmName -eq '') -and ($sourceSubscriptionId -ne $destinationSubscriptionId))
{
    $destinationVmName = $sourceVmName
}
else
{
    if ($null -eq $destinationVmName -or $destinationVmName -eq '')
    {
        $destinationVmName = "$sourceVmName-clone-$randomNumber"
    }
}
Write-Host "New VMName: $destinationVmName"

# Step 7: Clone the availability set if found, or join an existing one.
$availabilitySetId = ''
if ($null -ne $sourceVm.AvailabilitySetReference)
{
    Write-Host "Found a source AV set"
    $createNewAvailabilitySet = $false
    if ($useExistingAvailabilitySet -eq $true)
    {
        if (($destinationResourceGroupName -eq $sourceResourceGroupName) -and ($null -eq $destinationSubscriptionId -or $sourceSubscriptionId -eq $destinationSubscriptionId))
        {
            Write-Host "Using existing AV set"
            $availabilitySetId = $sourceVm.AvailabilitySetReference.Id
        }
        else
        {
            if ($null -ne $existingAvailabilitySetName -and $existingAvailabilitySetName -ne '')
            {
                $destinationAvailabilitySet = Get-AzAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $existingAvailabilitySetName -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
                if ($null -ne $destinationAvailabilitySet)
                {
                    Write-Host "Found the specified existing availability set '$existingAvailabilitySetName' in '$destinationResourceGroupName'. Assigning VM reference to it."
                    $availabilitySetId = $destinationAvailabilitySet.Id
                }
                else
                {
                    Write-Host "Warning: Failed to get the specified existing availability set '$existingAvailabilitySetName' in '$destinationResourceGroupName'. A new availability set will be created for the VM with source settings." -ForegroundColor Yellow
                    $createNewAvailabilitySet = $true
                }
            }
            else
            {
                $createNewAvailabilitySet = $true
            }
        }
    }
    else
    {
        Write-Host "No source AV set"
        $createNewAvailabilitySet = $true
    }

    if ($createNewAvailabilitySet -eq $true)
    {
        Write-Host "Creating a new AV set"
        # Get existing availability set reference.
        $sourceAvailabilitySetId = $sourceVm.AvailabilitySetReference.Id
        $sourceAvailabilitySet = Get-AzAvailabilitySet -ResourceGroupName $sourceResourceGroupName -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue | Where-Object {$_.Id -eq $sourceAvailabilitySetId}

        # Create a new availability set.
        if (($sourceSubscriptionId -ne $destinationSubscriptionId) -and ($null -ne $sourceAvailabilitySet))
        {
            $availabilitySetName = $sourceAvailabilitySet.Name
        }
        else
        {
            $availabilitySetName = "avset-clone-$randomNumber"
        }
        Write-Host "AV Set Name: $availabilitySetName"

        if ($null -eq $sourceAvailabilitySet)
        {
            Write-Host "Warning: Failed to get the source availability set whose id is '$sourceAvailabilitySet' in '$sourceResourceGroupName'. A new availability set will be created for the VM with default settings." -ForegroundColor Yellow
            $newAvailabilitySet = New-AzAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $availabilitySetName -Location $destinationLocation -AzContext $destinationSubscriptionContext
        }
        else
        {
            $sourceAvailabilitySetName = $sourceAvailabilitySet.Name
            Write-Host "Found the source availability set '$sourceAvailabilitySetName' whose id is '$sourceAvailabilitySet' in '$sourceResourceGroupName'. Copying setting to new availability set '$availabilitySetName'."
            if ($null -eq $destinationSubscriptionId -or $destinationSubscriptionId -eq '')
            {
                $newAvailabilitySet = New-AzAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $availabilitySetName -Location $destinationLocation -PlatformUpdateDomainCount $sourceAvailabilitySet.PlatformUpdateDomainCount -PlatformFaultDomainCount $sourceAvailabilitySet.PlatformFaultDomainCount -Sku $sourceAvailabilitySet.Sku -AzContext $sourceSubscriptionContext
                if ($copyTags -eq $true)
                {
                    $newAvailabilitySet.Tags = $sourceAvailabilitySet.Tags
                    $newAvailabilitySet | Set-AzResource -AzContext $sourceSubscriptionContext -Force -ErrorAction SilentlyContinue
                }
            }
            else
            {
                $newAvailabilitySet = New-AzAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $availabilitySetName -Location $destinationLocation -PlatformUpdateDomainCount $sourceAvailabilitySet.PlatformUpdateDomainCount -PlatformFaultDomainCount $sourceAvailabilitySet.PlatformFaultDomainCount -Sku $sourceAvailabilitySet.Sku -AzContext $destinationSubscriptionContext            
                if ($copyTags -eq $true)
                {
                    $newAvailabilitySet.Tags = $sourceAvailabilitySet.Tags
                    $newAvailabilitySet | Set-AzResource -AzContext $destinationSubscriptionContext -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $availabilitySetId = $newAvailabilitySet.Id
    }
}

# Step 8: Build the clone's parts.
$clonedVmSize = $sourceVm.HardwareProfile.VmSize
if ($availabilitySetId -eq '')
{
    $clonedVm = New-AzVMConfig -VMName $destinationVmName -VMSize $clonedVmSize -Tags $sourceVm.Tags -AzContext $destinationSubscriptionContext
}
else
{
    $clonedVm = New-AzVMConfig -VMName $destinationVmName -VMSize $clonedVmSize -AvailabilitySetId $availabilitySetId -Tags $sourceVm.Tags -AzContext $destinationSubscriptionContext
}

# Step 9: Clone each NIC on the source VM.
[int]$nicIndex = 0
foreach ($nic in $sourceVm.NetworkProfile.NetworkInterfaces)
{
    $enableAcceleratedNetworking = $false
    $enableIPForwarding = $false
    $sourceNicId = $nic.Id
    $sourceNic = Get-AzNetworkInterface -ResourceGroupName $sourceResourceGroupName -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue | Where-Object {$_.Id -eq $sourceNicId}
    if ($null -eq $sourceNic)
    {
        Write-Host "Warning: Failed to get the source NIC whose id is '$sourceNicId' in '$sourceResourceGroupName'." -ForegroundColor Yellow
    }
    else
    {
        $enableAcceleratedNetworking = ($sourceNic.EnableAcceleratedNetworking -eq $true -or $setAcceleratedNetworking -eq $true)
        $enableIPForwarding = $sourceNic.EnableIPForwarding
        
        #TODO: Create an NSG if one exists for the Nics.
        $destinationIpConfigurations = $sourceNic.IpConfigurations

        [int]$ipConfigIndex = 0
        foreach ($ipConfig in $sourceNic.IpConfigurations)
        {
            $ipConfigName = $ipConfig.Name
            $ipConfigId = $ipConfig.Id
            Write-Host "Info: [$ipConfigIndex]: Found IP Configuration. Name: '$ipConfigName'. Id: '$ipConfigId'."
            #$sourceNic.IpConfigurations[$ipConfigIndex]
            
            if ($null -ne $sourceNic.IpConfigurations[$ipConfigIndex].PublicIpAddress)
            {
                $sourcePipId = $sourceNic.IpConfigurations[$ipConfigIndex].PublicIpAddress.Id
                $sourcePublicIpAddress = Get-AzPublicIpAddress -ResourceGroupName $sourceResourceGroupName -AzContext $sourceSubscriptionContext -ErrorAction SilentlyContinue | Where-Object {$_.Id -eq $sourcePipId}
                if ($null -ne $sourcePublicIpAddress)
                {
                    $sourcePipName = $sourcePublicIpAddress.Name
                    Write-Host "Info: [$ipConfigIndex]: IP Configuration '$ipConfigName' has public ip '$sourcePipName'."
                    $clonedPublicIpName = "pip-$sourcePipName-clone-$randomNumber"
                    Write-Host "Creating public IP '$clonedPublicIpName'..."
                    if ($copyTags -eq $true)
                    {
                        $clonedPublicIp = New-AzPublicIpAddress -Name $clonedPublicIpName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -AllocationMethod $sourcePublicIpAddress.PublicIpAllocationMethod -Tag $sourcePublicIpAddress.Tag -AzContext $destinationSubscriptionContext -Sku $sourcePublicIPAddress.Sku.Name -Zone $sourcePublicIpAddress.Zones
                    }
                    else
                    {
                        $clonedPublicIp = New-AzPublicIpAddress -Name $clonedPublicIpName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -AllocationMethod $sourcePublicIpAddress.PublicIpAllocationMethod -AzContext $destinationSubscriptionContext -Sku $sourcePublicIPAddress.Sku.Name -Zone $sourcePublicIpAddress.Zones 
                    }
                    $destinationIpConfigurations[$ipConfigIndex].PublicIpAddress = $clonedPublicIp
                }
                else
                {
                    Write-Host "Warning: [$ipConfigIndex]: Failed to get the source Public IP whose id is '$sourcePipId' in '$sourceResourceGroupName'. Skipping PIP creation for IP Config '$ipConfigName'." -ForegroundColor Yellow
                }
            }

            $sourceSubnetId = $sourceNic.IpConfigurations[$ipConfigIndex].Subnet.Id
            if ($null -ne $sourceSubnetId)
            {
                $sourceSubnetName = $sourceSubnetId.Substring($sourceSubnetId.LastIndexOf('/')+1)
                if ($null -eq $destinationSubnetName)
                {
                    $destinationSubnetName = $sourceSubnetName
                }
                $destinationSubnetConfig = Get-AzVirtualNetworkSubnetConfig -Name $destinationSubnetName -VirtualNetwork $destinationVNet -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
                if ($null -ne $destinationSubnetConfig)
                {
                    $destinationIpConfigurations[$ipConfigIndex].Subnet = $destinationSubnetConfig
                }
                else
                {
                    Write-Host "Warning: [$ipConfigIndex]: Failed to get the destination Subnet config with subnet name '$destinationSubnetName' in VNet '$destinationVNetName' (in RG '$destinationVNetResourceGroupName') ." -ForegroundColor Yellow
                }
            }
            else
            {
                Write-Host "Warning: [$ipConfigIndex]: Failed to get the source Subnet ID." -ForegroundColor Yellow
            }

            $destinationIpConfigurations[$ipConfigIndex].Id = ''
            $destinationIpConfigurations[$ipConfigIndex].Etag = ''
            $ipConfigIndex++
        }
    }

    if ($sourceSubscriptionId -ne $destinationSubscriptionId)
    {
        $clonedNicName = $sourceNic.Name
    }
    else
    {
        $clonedNicName = "nic$nicIndex-clone-$randomNumber"
    }
    Write-Host "Creating NIC '$clonedNicName'..."
    $clonedNic = New-AzNetworkInterface -Name $clonedNicName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -IpConfiguration $destinationIpConfigurations[0] -AzContext $destinationSubscriptionContext
    $clonedNic.IpConfigurations = $destinationIpConfigurations
    if ($copyTags -eq $true)
    {
        $clonedNic.Tag = $sourceNic.Tag
    }
    $clonedNic.Primary = $nic.Primary
    $clonedNic.EnableAcceleratedNetworking = $enableAcceleratedNetworking
    $clonedNic.EnableIPForwarding = $enableIPForwarding
    $clonedNic | Set-AzNetworkInterface -AzContext $destinationSubscriptionContext -ErrorAction SilentlyContinue
    $clonedVm = Add-AzVMNetworkInterface -VM $clonedVm -Id $clonedNic.Id -AzContext $destinationSubscriptionContext
}

# Step Pre-10: If the destination region is different from the source region, create a temp storage account, copy the snapshots to it, and create new snapshots in the destination region.
if ($destinationLocation -ne $sourceVm.Location)
{
    $destinationStagingStorageAccountName = 'stage' + $(Get-UniqueString -id $destinationResourceGroup.ResourceId)
    Write-Host "Creating staging storage account in destination location: $destinationStagingStorageAccountName..."
    $destinationStagingStorageAccount = (Get-AzStorageAccount | Where-Object{$_.StorageAccountName -eq $destinationStagingStorageAccountName})
    # Create the storage account if it doesn't already exist.
    if ($destinationStagingStorageAccount -eq $null) {
        $destinationStagingStorageAccount = New-AzStorageAccount -StorageAccountName $destinationStagingStorageAccountName -Type 'Standard_LRS' -Kind StorageV2 -AccessTier Hot -ResourceGroupName $destinationResourceGroupName -Location "$destinationLocation"
    }

    # Create VHDs container and ignore error if it already exists.
    $storageContainerName = 'vhds'
    New-AzStorageContainer -Name $storageContainerName -StorageAccount $destinationStagingStorageAccount -ErrorAction SilentlyContinue *>&1

    $sasExpiryDuration = "3600"

    for($i=0; $i -lt $snapshots.Length; $i++)
    {
        # Create a VHD for each snapshot (based on: https://docs.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-windows-powershell-sample-create-snapshot-from-vhd).
        $snapshotName = $snapshots[$i].Name
        $destinationSnapshotVhdFileName = "$snapshotName.vhd"
        Write-Host "[snapshot $i] Exporting snapshot '$snapshotName' into VHD '$destinationSnapshotVhdFileName'..."

        # Generate the SAS for the snapshot.
        $sas = Grant-AzSnapshotAccess -ResourceGroupName $sourceResourceGroupName -SnapshotName $snapshotName -DurationInSecond $sasExpiryDuration -Access Read
        # Copy the snapshot to the storage account.
        Write-Host "[snapshot $i] Copying snapshot into VHD using SAS URL..."
        Start-AzureStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestContainer $storageContainerName -DestContext $destinationStagingStorageAccount.Context -DestBlob $destinationSnapshotVhdFileName
    }

    # Wait for the copy operations to finish and create snapshots off of the VHDs. [TODO: This can be optimized to run the status checks and then the snapshot creation in parallel]
    for($i=0; $i -lt $snapshots.Length; $i++)
    {
        $snapshotName = $snapshots[$i].Name
        $destinationSnapshotVhdFileName = "$snapshotName.vhd"
        Write-Host "[snapshot $i] Waiting for copy of blob '$destinationSnapshotVhdFileName' to complete..."
        Get-AzureStorageBlobCopyState -Blob "$destinationSnapshotVhdFileName" -Container "$storageContainerName" -Context $destinationStagingStorageAccount.Context -WaitForComplete

        # Then create a snapshot in the destination region based on the VHD (based on: https://docs.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-windows-powershell-sample-create-snapshot-from-vhd).
        $sourceVhdUri = "https://$destinationStagingStorageAccountName.blob.core.windows.net/$storageContainerName/$destinationSnapshotVhdFileName"
        $destinationSnapshotConfig = New-AzSnapshotConfig -AccountType 'Standard_LRS' -Location $destinationLocation -CreateOption Import -StorageAccountId $destinationStagingStorageAccount.Id -SourceUri $sourceVhdUri -AzContext $destinationSubscriptionContext
        $destinationSnapshotName = "$snapshotName-copy"
        Write-Host "[snapshot $i] Creating destination snapshot '$destinationSnapshotName' from VHD..."
        $snapshot = New-AzSnapshot -Snapshot $destinationSnapshotConfig -ResourceGroupName $destinationResourceGroupName -SnapshotName $destinationSnapshotName -AzContext $destinationSubscriptionContext

        # Overrite the snapshot in the array with the destination snapshot just created.
        Write-Host "[snapshot $i] Successfully created destination snapshot."
        $snapshots[$i] = $snapshot
    }

    # Delete the VHDs container now that the snapshots have been created.
    Write-Host "Cleanup: Deleting the storage container..."
    Remove-AzureStorageContainer -Name "$storageContainerName" -Context $destinationStagingStorageAccount.Context -Force -ErrorAction SilentlyContinue *>&1
}

# Step 10: Create the disk configurations. Creates a uniform configuration based on the OS disk. Does not reflect data disks with a different SKU than the OS.
# TODO: Read disk SKU for each disk.
#$managedDiskAccountType = $sourceVm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType #empty when VM is deallocated
$vmDiskId = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id
$vmDiskName = $vmDiskId.Substring($vmDiskId.LastIndexOf('/')+1)
$vmDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroupName -DiskName "$vmDiskName" -AzContext $sourceSubscriptionContext
$managedDiskAccountType = $vmDisk.Sku.Name
Write-Host "Managed Disk Account Type: '$managedDiskAccountType'"
$managedDiskCreateOption = 'Copy'
$vmDiskCreateOption = 'Attach'

if ($snapshots.Length -eq 1)
{
    # Single snapshot of the OS disk.
    if ($sourceSubscriptionId -ne $destinationSubscriptionId)
    {
        $diskName = $vmDiskName
    }
    else
    {
        $diskName = "osdisk-clone-$randomNumber"
    }
    Write-Host "Creating cloned VM OS disk '$diskName'..."
    $diskConfig = New-AzDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[0].Id -AzContext $destinationSubscriptionContext
    $osDisk = New-AzDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName -AzContext $destinationSubscriptionContext
    if (($null -ne $sourceVm.OSProfile -and $null -ne $sourceVm.OSProfile.WindowsConfiguration) -or $sourceVm.StorageProfile.osDisk.osType -eq "Windows")
    {
        Write-Host "Setting Windows OS disk..."
        $clonedVm = Set-AzVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Windows -AzContext $destinationSubscriptionContext
    }
    else
    {
        Write-Host "Setting Linux OS disk..."
        $clonedVm = Set-AzVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Linux -AzContext $destinationSubscriptionContext
    }
    Set-AzContext -Context $destinationSubscriptionContext
    Write-Host "Removing snapshot '$snapshots[0].Name'..."
    Remove-AzSnapshot -ResourceGroupName $snapshots[0].ResourceGroupName -SnapshotName $snapshots[0].Name -Force
}
else
{
    # A snapshot of each disk.
    for($i=0; $i -lt $snapshots.Length; $i++)
    {
        if ($i -eq 0)
        {
            if ($sourceSubscriptionId -ne $destinationSubscriptionId)
            {
                $diskName = $vmDiskName
            }
            else
            {
                $diskName = "osdisk-clone-$randomNumber"
            }
            Write-Host "Creating cloned VM OS disk '$diskName'..."
            $diskConfig = New-AzDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[$i].Id -AzContext $destinationSubscriptionContext
            $osDisk = New-AzDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName -AzContext $destinationSubscriptionContext

            if (($null -ne $sourceVm.OSProfile -and $null -ne $sourceVm.OSProfile.WindowsConfiguration) -or $sourceVm.StorageProfile.osDisk.osType -eq "Windows")
            {
                Write-Host "Setting Windows OS disk..."
                $clonedVm = Set-AzVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Windows -AzContext $destinationSubscriptionContext
            }
            else
            {
                Write-Host "Setting Linux OS disk..."
                $clonedVm = Set-AzVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Linux -AzContext $destinationSubscriptionContext
            }
        }
        else
        {
            $dataDiskIndex = $i-1
            if ($sourceSubscriptionId -ne $destinationSubscriptionId)
            {
                $diskname = $sourceVm.StorageProfile.DataDisks[$i-1].Name
            }
            else
            {
                $diskName = "datadisk$dataDiskIndex-clone-$randomNumber"
            }
            Write-Host "Creating cloned VM data disk '$diskName'..."
            $diskConfig = New-AzDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[$i].Id -AzContext $destinationSubscriptionContext
            $dataDisk = New-AzDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName -AzContext $destinationSubscriptionContext
            $clonedVm = Add-AzVMDataDisk -VM $clonedVm -Name $diskName -ManagedDiskId $dataDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.DataDisks[$dataDiskIndex].Caching -Lun $sourceVm.StorageProfile.DataDisks[$dataDiskIndex].Lun -AzContext $destinationSubscriptionContext
        }
        Set-AzContext -Context $destinationSubscriptionContext
        Write-Host "Removing snapshot '$snapshots[$i].name'..."
        Remove-AzSnapshot -ResourceGroupName $snapshots[$i].ResourceGroupName -SnapshotName $snapshots[$i].Name -Force
    }
}

# Step 11: Clone the Plan if found.
if ($null -ne $sourceVm.Plan)
{
    $clonedVm.Plan = $sourceVm.Plan
}

# Step 12: Create the VM clone.
Write-Host "Creating cloned VM '$destinationVmName' in '$destinationResourceGroupName'..."
if ($copyTags -eq $true)
{
    New-AzVM -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -VM $clonedVm -Tag $sourceVm.Tags -AzContext $destinationSubscriptionContext -Verbose -ErrorVariable CreateVmErrors
}
else
{
    New-AzVM -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -VM $clonedVm -AzContext $destinationSubscriptionContext -Verbose -ErrorVariable CreateVmErrors
}

if ($CreateVmErrors)
{
    Write-Host "Failed to create cloned VM '$destinationVmName'." -ForegroundColor Red
    exit 1
}
else
{
    Write-Host "Successfully created cloned VM '$destinationVmName'." -ForegroundColor DarkGreen
}

$ScriptEndDate=(Get-Date)
Write-Output '', 'Script Duration:'
New-TimeSpan -Start $ScriptStartDate -End $ScriptEndDate

Write-Output '', 'Deployment completed successfully.'
exit 0