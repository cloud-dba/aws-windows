<#

Open Powershell as Administrator

Import-Module c:\windows\temp\InstallSqlUpdate.psm1 -Force
Install-SQLUpdate -Action ["No" | "Yes"]

No - will only display comments/logs and commands that will get executed
Yes - will actually do the install

Example:

Import-Module c:\windows\temp\InstallSqlServicePack.psm1 -Force
Install-SQLUpdate -Action "No"
Install-SQLUpdate -Action "Yes"

#>

function Install-SQLUpdate
{
    [CmdletBinding()]
    PARAM
    (
        [ValidateSet("Yes", "No")][string] $Action = "Yes"
        ,[string] $DestinationDrive = "C"
        ,[string] $DestinationFolder = "Windows\temp"
        ,[int] $MinimumRequiredDriveSpace = 1 #GB
    )

    BEGIN
    {
        $DestinationDriveFolder = $DestinationDrive + ":\$DestinationFolder"
        $Global:LogFile = $DestinationDriveFolder + "\Logfile.txt"
        Write-Host "== Install SQL Update =="
        Write-Output "== Install SQL Update ==" | out-file -encoding ASCII $LogFile
    }

    PROCESS
    {

        # Test-SQLInstallation
        # if sql is installed but service is not started, it tries to start the service
        # if sql service is started, it will import sqlps module
        # if sql cannot be started, then script stops here

        Write-Log "Test-SQLInstallation"

        $ReturnCode = Test-SQLInstallation
        if($ReturnCode -eq $false) {RETURN} 
        
        Import-ModuleSQLPS


        # Check if SQL is Clustered
        # If yes then stop here

        Write-Log "Check if Clustered"
        
        $Clustered = Invoke-Sqlcmd -Query "select IsClustered = SERVERPROPERTY('IsClustered')"
        if($Clustered.isClustered -eq 1)
        {
            Write-Log "- SQL is clustered. Not supported at this time" -Color Red
            RETURN
        }
        else
        {
            Write-Log "- Not Clustered"
        }

        # Get-InstallableUpdate
        # This will scan the SqlBuilds array, and check if there's applicable update for the current sql version installed on this server
        # If none, then script stops here

        Write-Log "Get-InstallableUpdate"

        $InstallableUpdate = Get-InstallableUpdate

        if($InstallableUpdate)
        {
            $Message = "- Found " + $InstallableUpdate.Release + " - " + $InstallableUpdate.Version + " (" + $InstallableUpdate.ServicePack + ")"
            Write-Log $Message

            $FileName = Split-Path $InstallableUpdate.DownloadPath -Leaf
            $FullPath = $DestinationDriveFolder + "\" + $FileName
        }
        else
        {
            Write-Log "- No installable update found." -Color Red
            RETURN
        }

        
        # Test-DownloadDestinationFolder
        # Make sure that the drive has enough space, creates the destination folder
        # If there's a problem of the space or cannot create the destination folder then script stops here.
        
        Write-Log "Test-DownloadDestinationFolder"

        $ReturnCode = Test-DownloadDestinationFolder -DestinationDrive $DestinationDrive -DestinationDriveFolder $DestinationDriveFolder
        if($ReturnCode -eq $false) {RETURN}

       
        # ------------------------------
        # download bits
        #-------------------------------

        $Message = "Downloading " + $InstallableUpdate.Release + " - " + $InstallableUpdate.Version + " (" + $InstallableUpdate.ServicePack + ") from Microsoft..."
        Write-Log $Message

        if($Action -eq "Yes")
        {
            #write-Log "*** Invoke-WebRequest ..."

            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest $InstallableUpdate.DownloadPath -OutFile $FullPath
        }
        else
        {
            $Message = "- Source " + $InstallableUpdate.DownloadPath
            write-Log $Message 
            write-Log "- Destination $FullPath"
        }

        

        Write-Log -Message "- Downloading Update bits completed"

        # ------------------------------
        # Install
        #-------------------------------

        $Message = "Installing " + $InstallableUpdate.Release + " - " + $InstallableUpdate.Version + " (" + $InstallableUpdate.ServicePack + ")"
        Write-Log $Message

        $InstallParameters = "/allinstances /quiet /IAcceptSQLServerLicenseTerms=True"

        if($Action -eq "Yes")
        {
            Start-Process $FullPath -ArgumentList $InstallParameters -NoNewWindow -Wait
        }
        else
        {
            Write-Log "- $FullPath $InstallParameters"
        }
        
        $Message = "Installing " + $InstallableUpdate.Release + " - " + $InstallableUpdate.Version + " (" + $InstallableUpdate.ServicePack + ") Completed"
        Write-Log "- $Message"

        # ------------------------------
        # Verify
        #-------------------------------

        Write-Log "Verify SQL version after update"
        $AfterUpdateVersion = Get-SqlVersion

        $AfterUpdateVersion2 = $AfterUpdateVersion.Version

        Write-Log "- Version after update $AfterUpdateVersion2"

        if($InstallableUpdate.Version -eq $AfterUpdateVersion.Version)
        {
            $Message = "Update Successful!"
            Write-Log $Message -Color Green
        }
        else
        {
            $Message = "Update Failed!"
            Write-Log $Message -Color Red
        }
        
        
    }
    END
    {
    }
}

function Get-SqlVersion
{
    $CurrentVersionObj = @()
    
    $CurrentVersion = Invoke-Sqlcmd -Query "select ProductVersion = SERVERPROPERTY('ProductVersion')"
    $CurrentVersionSplits = $CurrentVersion.ProductVersion.Split(".")
    $CurrentVersionObj = New-Object PSObject -Property @{
        Version = $CurrentVersion.ProductVersion
        Major = $CurrentVersionSplits[0]
        Minor = $CurrentVersionSplits[1]
        Build = $CurrentVersionSplits[2]
        Revision = $CurrentVersionSplits[3]
    }

    ## for testing
    #$CurrentVersionObj = New-Object PSObject -Property @{
    #    Version = "10.0.1600.22"
    #    Major = "10"
    #    Minor = "0"
    #    Build = "1600"
    #    Revision = "22"
    #}


    return $CurrentVersionObj
}

function Get-InstallableUpdate
{
    Write-Log "- Read current installed version..."
    $CurrentVersionDisplay = Invoke-Sqlcmd -Query "select SqlVersion = substring(left(@@VERSION, charindex(char(10), @@version)), 0, charindex('(x',@@version)) + '(' + cast(SERVERPROPERTY('ProductLevel') as varchar) + ')'"
    $Message = "- Found " + $CurrentVersionDisplay.SqlVersion
    Write-Log $Message

    $CurrentVersion = Get-SqlVersion
    Write-Log "- Looking for latest Service Pack..."
    $SqlBuilds = Get-Builds $CurrentVersion.Major

    $InstallableUpdate = @()
    :breakforeach
    foreach ($b in $SqlBuilds | Sort-Object Minor, Build, Revision)
    {
        if([int]$b.Major -eq [int]$CurrentVersion.Major -and [int]$b.Minor -gt [int]$CurrentVersion.Minor)
        {
            $InstallableUpdate = $b
            break breakforeach
        }
        else
        {
            if([int]$b.Major -eq [int]$CurrentVersion.Major -and [int]$b.Minor -eq [int]$CurrentVersion.Minor -and [int]$b.Build -gt [int]$CurrentVersion.Build)
            {
                $InstallableUpdate = $b
                break breakforeach
            }
            else
            {
                if([int]$b.Major -eq [int]$CurrentVersion.Major -and [int]$b.Minor -eq [int]$CurrentVersion.Minor -and [int]$b.Build -eq [int]$CurrentVersion.Build -and [int]$b.Revision -gt [int]$CurrentVersion.Revision)
                {
                    $InstallableUpdate = $b
                    break breakforeach
                }
            }
        }
    }

    $InstallableUpdate
}

function Write-Log
{
    PARAM
    (
         [Parameter(Mandatory = $true)] [string] $Message
        ,[ValidateSet("Green", "Yellow", "Red")] [string] $Color
    )

    $Datestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $CompleteMessage = "$Datestamp $Message"
    
    if($Color)
    {
        Write-Host $CompleteMessage -ForegroundColor $Color
    }
    else
    {
        Write-Host $CompleteMessage
    }
    Write-Output $CompleteMessage | out-file -encoding ASCII $LogFile -Append
}

function Test-SQLInstallation
{
    $isSqlInstalled = Get-Service -Name MSSQLSERVER
    if($isSqlInstalled)
    {
        $SqlServiceStatus = (Get-Service -Name MSSQLSERVER).Status
        if($SqlServiceStatus -ne "Running")
        {
            Write-Log -Message "- SQL Server seeems to be installed but SQLServer service is not running. Trying to start."

            Start-Service MSSQLSERVER
            Start-Sleep -Seconds 10

            $SqlServiceStatus = (Get-Service -Name MSSQLSERVER).Status
            if($SqlServiceStatus -ne "Running")
            {
                Write-Log -Message "- SQL Server seeems to be installed but SQLServer service cannot be started." -Color Red
                $ReturnCode = $false
            }
            else
            {
                Write-Log -Message "- SQL Server service is now running"
                $ReturnCode = $true
            }
        }
        else
        {
            Write-Log -Message "- SQL server service is installed and started"
            $ReturnCode = $true
        }
    }
    else
    {
        Write-Log -Message "- SQL Server is not installed" -Color Red
        $ReturnCode = $false
    }

    return $ReturnCode
}

function Test-DownloadDestinationFolder
{

    [CmdletBinding()]
    
    PARAM
    (
        $DestinationDrive
        ,$DestinationDriveFolder
    )
    
    BEGIN
    {
        $ReturnCode = $false
    }

    PROCESS
    {
        write-Log "- Get disk information on $DestinationDrive`: drive"
        $DriveInfo = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$DestinationDrive`:'"
        [int]$FreeSpace = $DriveInfo.FreeSpace / 1073741824 #GB
        
        write-Log "- Free space is $FreeSpace GB"

        if($FreeSpace -ge $MinimumRequiredDriveSpace)
        {
            # Create the folder
            if(!(Test-Path -Path $DestinationDriveFolder))
            {
                $null = New-Item $DestinationDriveFolder -type directory -ErrorAction SilentlyContinue
            }

            # Verify
            if(Test-Path -Path $DestinationDriveFolder)
            {
                write-Log -Message "- Destination folder $DestinationDriveFolder was successfully created."
                $ReturnCode = $true
            }
            else
            {
                write-Log -Message "- Destination folder was not created." -Color Red
                $ReturnCode = $false
            }
        }
        else
        {
            $Message = "- Free space in $DestinationDrive Drive is $FreeSpace GB. $MinimumRequiredDriveSpace GB is required to download the update."
            Write-Log -Message $Message -Color Red
            $ReturnCode = $false
        }
    }

    END
    {
        return $ReturnCode
    }
}

function Import-ModuleSQLPS {

    Write-Log "- Importing SQLPS Module"

    if(!(get-module sqlps))
    {
        push-location
        import-module sqlps 3>&1 | out-null
        pop-location

    }
}

function Get-Builds
{
    PARAM
    (
        $MajorVersion = 0
    )

    $BuildsArray = @()
    
    $Obj = New-Object PSObject -Property @{
        Release = "Microsoft SQL Server 2008R2"
        ServicePack = "SP3"
        Version = "10.50.6000.34"
        DownloadPath = "https://download.microsoft.com/download/D/7/A/D7A28B6C-FCFE-4F70-A902-B109388E01E9/ENU/SQLServer2008R2SP3-KB2979597-x64-ENU.exe"
    } ; $BuildsArray += $Obj

    $Obj = New-Object PSObject -Property @{
        Release = "Microsoft SQL Server 2012"
        ServicePack = "SP3"
        Version = "11.0.6020.0"
        DownloadPath = "https://download.microsoft.com/download/B/1/7/B17F8608-FA44-462D-A43B-00F94591540A/ENU/x64/SQLServer2012SP3-KB3072779-x64-ENU.exe"
    } ; $BuildsArray += $Obj
    
    $Obj = New-Object PSObject -Property @{
        Release = "Microsoft SQL Server 2014"
        ServicePack = "SP2"
        Version = "12.0.5000.0"
        DownloadPath = "https://download.microsoft.com/download/6/D/9/6D90C751-6FA3-4A78-A78E-D11E1C254700/SQLServer2014SP2-KB3171021-x64-ENU.exe"
    } ; $BuildsArray += $Obj

    $Obj = New-Object PSObject -Property @{
        Release = "Microsoft SQL Server 2016"
        ServicePack = "SP1"
        Version = "13.0.4001.0"
        DownloadPath = "https://download.microsoft.com/download/3/0/D/30D3ECDD-AC0B-45B5-B8B9-C90E228BD3E5/ENU/SQLServer2016SP1-KB3182545-x64-ENU.exe"
    } ; $BuildsArray += $Obj


    $BuildsArray2 = @()
    
    foreach($Build in $BuildsArray)
    {
        $ReturnObj = New-Object PSObject
        $VersionBits = $Build.Version.Split(".")
        Add-Member -InputObject $ReturnObj -NotePropertyName Release -NotePropertyValue $Build.Release
        Add-Member -InputObject $ReturnObj -NotePropertyName ServicePack -NotePropertyValue $Build.ServicePack
        Add-Member -InputObject $ReturnObj -NotePropertyName Version -NotePropertyValue $Build.Version
        Add-Member -InputObject $ReturnObj -NotePropertyName Major -NotePropertyValue $VersionBits[0]
        Add-Member -InputObject $ReturnObj -NotePropertyName Minor -NotePropertyValue $VersionBits[1]
        Add-Member -InputObject $ReturnObj -NotePropertyName Build -NotePropertyValue $VersionBits[2]
        Add-Member -InputObject $ReturnObj -NotePropertyName Revision -NotePropertyValue $VersionBits[3]
        Add-Member -InputObject $ReturnObj -NotePropertyName DownloadPath -NotePropertyValue $Build.DownloadPath
        $BuildsArray2 += $ReturnObj
    }

    
    $ReturnBuildsArray = @()

    if($MajorVersion -eq 0)
    {
        $ReturnBuildsArray = $BuildsArray2
    }
    else
    {
        $ReturnBuildsArray = $BuildsArray2 | Where-Object {$_.Major -eq $MajorVersion} 
    }

    return $ReturnBuildsArray
}

