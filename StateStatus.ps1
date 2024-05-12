#Requires -Version 7.2
#Requires -Modules CognosModule,eSchoolModule,SimplySQL

<#

.SYNOPSIS
This script will monitor state servers for authentication and data retrieval.

.DESCRIPTION
This script will only ever use the DefaultConfig of the CognosModule to test services.

#>

$version = '24.5.11'

try {
    Open-SQLiteConnection -DataSource "$PSScriptRoot\statestatus.sqlite3" -ErrorAction Stop

    # I want to keep this as simple as possible. If the version number changes then drop the state_status table.
    try {
        $dbVersion = Invoke-SqlScalar -Query "SELECT version FROM version"
    } catch {
        Invoke-SqlUpdate -Query 'CREATE TABLE IF NOT EXISTS "version" (
            "version"  TEXT
        );' | Out-Null
        
        Invoke-SqlUpdate -Query "INSERT INTO version (version) VALUES ('$($version)')" | Out-Null

        Invoke-SqlUpdate -Query 'DROP TABLE IF EXISTS "state_status";' | Out-Null
    } finally {
    
        if ([version]$dbVersion -lt [version]$version) {
            Invoke-SqlUpdate -Query "UPDATE version SET version = '$($version)'" | Out-Null
            Invoke-SqlUpdate -Query 'DROP TABLE IF EXISTS "state_status";' | Out-Null
        }

        Invoke-SqlUpdate -Query 'CREATE TABLE IF NOT EXISTS "state_status" (
            "rowIdentity"   INTEGER,
            "district"      TEXT NOT NULL,
            "service"	    TEXT NOT NULL,
            "method"        TEXT NOT NULL,
            "status"        INTEGER NOT NULL,
            "server"        TEXT,
            "dt"            TEXT NOT NULL,
            "dtStart"       TEXT NOT NULL,
            "dtUpload"      TEXT,
            PRIMARY KEY("rowIdentity" AUTOINCREMENT)
        );' | Out-Null

        #remove records older than 30 days so the database doesn't grow exponentially 
        Invoke-SqlUpdate -Query "DELETE FROM state_status WHERE dtStart < '$((Get-Date).AddDays(-30).ToString('yyyy-MM-dd'))'" | Out-Null

    }

} catch {
    Write-Error "Failed to open SQLite Database."
    exit 1
}

#Start of this whole loop
$global:dtStart = Get-Date

if (Test-Path "$PSScriptRoot\settings.ps1") {
    . $PSScriptRoot\settings.ps1
}

$districtLEA = Get-Content "$($env:userprofile)\.config\Cognos\DefaultConfig.json" | 
    ConvertFrom-Json | 
    Select-Object -ExpandProperty Username | 
    Select-String -Pattern "(\d+).*" | 
    Select-Object -ExpandProperty Matches | 
    Select-Object -ExpandProperty Groups | 
    Select-Object -Skip 1 -ExpandProperty Value

#Hashtables to build results.
function New-StatusObject ($service, $method) {
    return [ordered]@{
        district = $districtLEA
        service = $service
        method = $method
        status = 0 #boolean false
        server = $null
        dt = (Get-Date)
        dtStart = $dtStart
        dtUpload = $null
    }
}

function Write-StatusToDB ($statusObject) {
    # "INSERT INTO state_status ('$($statusObject.keys -join ''',''')') VALUES (@$($statusObject.keys -join ',@'))"
    Invoke-SqlUpdate -Query "INSERT INTO state_status ('$($statusObject.keys -join ''',''')') VALUES (@$($statusObject.keys -join ',@'))" -Parameters $statusObject | Out-Null
}

#Check eSchool Login
Try {

    $eSchoolLoginStatus = New-StatusObject -service 'eSP' -method 'login'

    Connect-ToeSchool

    $eSchoolLoginStatus.status = 1 #boolean true
    $eSchoolLoginStatus.server = $eSchoolSession.server
    
    Write-StatusToDB $eSchoolLoginStatus

} catch {

    Write-Error "Failed to Login to eSchool"
    Write-StatusToDB $eSchoolLoginStatus

}

#Check eSchool Task Pull. This is something every user can do regardless of rights.
Try {

    $eSchoolTaskStatus = New-StatusObject -service 'eSP' -method 'tasks'

    $tasks = Get-eSPTaskList -SilentErrors

    $eSchoolTaskStatus.status = 1 #boolean true
    $eSchoolTaskStatus.server = $eSchoolSession.server
    
    Write-StatusToDB $eSchoolTaskStatus

} catch {

    Write-Error "Failed to retrieve eSchool Tasks"
    Write-StatusToDB $eSchoolTaskStatus

}

#Check for eSchool task success and data pull. Not all users can do this so its optional.
if ($espDownloadDefinitions) {
    
        Try {
    
            $eSchoolDownloadDefinitionStatus = New-StatusObject -service 'eSP' -method 'definitions'
    
            $eSPDefinitions = (Invoke-eSPExecuteSearch -SearchType UPLOADDEF).interface_id

            if ($eSPDefinitions -notcontains 'CAMST') {
                Write-Host "Creating download definition CAMST for CAMTech State Monitoring" -ForegroundColor Yellow
                . $PSScriptRoot\resources\espDownloadDefinitions.ps1
            }

            # Remove-eSPFile -FileName "camtech-state-monitoring.csv" #This breaks stuff.
            Invoke-eSPDownloadDefinition -InterfaceId CAMST #This does not return if the task has started or is running.
                        
            #check that the task now is listed in the task list.
            if (-Not(Get-eSPTaskList | Select-Object -ExpandProperty InactiveTasks | Where-Object -Property TaskName -eq 'CAMST')) {
                Write-Error "Failed to find eSchool Task CAMST in the task list." -ErrorAction Stop
            }

            #We don't need to check the status of the task. We are just going to wait up to 15 seconds for the file to be created.
            $counter = 0
            do {

                #we are intentionally not saving this to disk and only checking for files in the last 2 minutes.
                $espDownloadDefinitionValues = Get-eSPFileList |
                    Where-Object -Property ModifiedDate -gt (Get-Date).AddMinutes(-2) |
                    Where-Object -Property RawFileName -eq "camtech-state-monitoring.csv" |
                    Get-eSPFile -Raw |
                    ConvertFrom-Csv

                if (-Not($espDownloadDefinitionValues)) {
                    Start-Sleep -Seconds 1
                }

                $counter++
                if ($counter -ge 15) {
                    Write-Error "CAMST did not produce the file within within 15 seconds." -ErrorAction Stop
                }
            } until ($espDownloadDefinitionValues)
                
            #if both students_active and students_inactive are greater than 1 then we are good.
            if (
                (($espDownloadDefinitionValues | Where-Object -Property Name -eq 'students_active' | Select-Object -ExpandProperty Value) -ge 1) -and
                (($espDownloadDefinitionValues | Where-Object -Property Name -eq 'students_inactive' | Select-Object -ExpandProperty Value) -ge 1)
            ) {
                $eSchoolDownloadDefinitionStatus.status = 1 #boolean true
                $eSchoolDownloadDefinitionStatus.server = $eSchoolSession.server
            } else {
                Write-Error "CAMST did not produce the expected results." -ErrorAction Stop
            }

            Write-StatusToDB $eSchoolDownloadDefinitionStatus
    
        } catch {
    
            Write-Error "Failed to retrieve eSchool Definitions"
            Write-StatusToDB $eSchoolDownloadDefinitionStatus
    
        }
    
}

#Check Cognos Login.
Try {

    $CognosLoginStatus = New-StatusObject -service 'cognos' -method 'login'

    Connect-ToCognos

    $CognosLoginStatus.status = 1 #boolean true
    
    Write-StatusToDB $CognosLoginStatus

} catch {

    Write-Error "Failed to Login to Cognos"
    Write-StatusToDB $CognosLoginStatus

}

#Check Cognos Report Pull.
Try {

    $CognosReportStatus = New-StatusObject -service 'cognos' -method 'report'

    #smallest report for verification
    $schools = Get-CogSchool | Where-Object { $PSitem.School_number -like "$($districtLEA)*" }

    #this means at least one returned.
    if ($schools) {
        $CognosReportStatus.status = 1 #boolean true
    }
    
    Write-StatusToDB $CognosReportStatus

} catch {

    Write-Error "Failed to Retrieve Report from Cognos"
    Write-StatusToDB $CognosReportStatus

}

#Check State ADAM (SSO) Site.
Try {

    $ADAMReportStatus = New-StatusObject -service 'ADAM' -method 'login'

    $accountInfo = Get-Content "$($env:userprofile)\.config\Cognos\DefaultConfig.json" | ConvertFrom-Json

    $username = $accountInfo.Username
    $password = (New-Object PSCredential "user",$($accountInfo | Select-Object -ExpandProperty password | ConvertTo-SecureString)).GetNetworkCredential().Password
    
    #this will be a 301 to the login page.
    $ADAMResponse = Invoke-WebRequest -Uri "https://adam.ade.arkansas.gov/" -TimeoutSec 5 -SessionVariable ADAMSession

    # $jsessionId = ($ADAMResponse.Headers.'Set-Cookie' | Select-String -Pattern 'JSESSIONID=(\w{32})').Matches.Groups[1].Value
    # $browserId = (New-Guid) -replace '-',''

    $usernameForm = @{
        'LoginInfo.UserName' = $username
        'LoginInfo.Password' = $password
        '__RequestVerificationToken' = ($ADAMResponse.InputFields | Where-Object { $PSItem.name -eq '__RequestVerificationToken' })[0].Value
    }

    #submit login
    $ADAMResponse2 = Invoke-WebRequest -Uri "https://adam.ade.arkansas.gov/login?ReturnUrl=/" `
        -Method "POST" `
        -WebSession $ADAMSession `
        -Form $usernameForm `

    #if the page doesn't redirect you're logged in.
    $ADAMResponse3 =  Invoke-WebRequest -Uri "https://adam.ade.arkansas.gov/Password" -WebSession $ADAMSession -MaximumRedirection 0

    $ADAMReportStatus.status = 1

    Write-StatusToDB $ADAMReportStatus

} catch {

    Write-Error "Failed to login to ADAM."
    Write-StatusToDB $ADAMReportStatus

}


# Not everyone has access to eFinance or should be checking it.
if ($efinance) {

    Try {

        $eFPReportStatus = New-StatusObject -service 'eFP' -method 'login'

        #start session
        $efpResponse = Invoke-WebRequest -Uri 'https://efinance20.efp.k12.ar.us/' -SessionVariable eFinanceSession -TimeoutSec 5

        #submit username/password
        $efpResponse2 = Invoke-WebRequest -Uri "https://efinance20.efp.k12.ar.us/eFP20.11/eFinancePLUS/SunGard.eFinancePLUS.Web/LogOn" `
            -Method "POST" `
            -WebSession $eFinanceSession `
            -Form (@{
                UserName = $username
                tempUN = $null
                tempPW= $null
                Password = $password
                login = $null
            })

        $efpResponse3 = Invoke-WebRequest -UseBasicParsing -Uri 'https://efinance20.efp.k12.ar.us/eFP20.11/eFinancePLUS/SunGard.eFinancePLUS.Web/Account/SetEnvironment/SessionStart' -WebSession $eFinanceSession

        $eFPReportStatus.server = $efpResponse3.InputFields | Where-Object -Property name -EQ -Value 'ServerName' | Select-Object -ExpandProperty value -First 1

        $efpresponse3.RawContent -match 'name="EnvironmentConfiguration.BusinessEntity"><option selected="selected" value="(.*)">.*</option>' | Out-Null
        $eFPBusinessEntity = $matches[1]

        #set environment and login
        $efpResponse4 = Invoke-WebRequest -Uri "https://efinance20.efp.k12.ar.us/eFP20.11/eFinancePLUS/SunGard.eFinancePLUS.Web/Account/SetEnvironment/SessionStart" `
            -Method "POST" `
            -WebSession $eFinanceSession `
            -Form (@{
                ServerName = $eFPReportStatus.server
                'EnvironmentConfiguration.BusinessEntity' = $eFPBusinessEntity
                'EnvironmentConfiguration.EntityProfile' = $efpResponse3.InputFields | Where-Object -Property name -EQ -Value 'EnvironmentConfiguration.EntityProfile' | Select-Object -ExpandProperty value
                'UserErrorMessage' = $null
            })

        #if this redirects then we aren't logged in completely.
        $efpResponse5 = Invoke-RestMethod -Uri 'https://efinance20.efp.k12.ar.us/eFP20.11/eFinancePLUS/SunGard.eFinancePLUS.Web/Dashboard/SessionInfo' -WebSession $eFinanceSession -MaximumRedirection 0

        Write-Host "Logged into eFianance $($efpResponse5.productVersion) for $($efpResponse5.profileName)" -ForegroundColor Green

        $eFPReportStatus.status = 1

        Write-StatusToDB $eFPReportStatus

    } catch {

        Write-Error "Failed to login to eFinance."
        Write-StatusToDB $eFPReportStatus

    }
}

#Remove eSchoolSession.
Remove-Variable -Name eSchoolSession -Scope Global -Force -ErrorAction SilentlyContinue

#Remove DownloadDefinitions
Remove-Variable -Name espDownloadDefinitions -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name espDownloadDefinitionValues -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name eSPActiveTask -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name eSPDefinitions -Scope Global -Force -ErrorAction SilentlyContinue

#Cleanup CognosSession
Remove-Variable -Name CognosSession -Scope Global -Force -ErrorAction SilentlyContinue

#Cleanup ADAM
Remove-Variable -Name ADAMSession -ErrorAction SilentlyContinue

#Cleanup eFinance
Remove-Variable -Name eFinanceSession -ErrorAction SilentlyContinue

#Do not leave username/password in memory.
Remove-Variable -Name username -ErrorAction SilentlyContinue
Remove-Variable -Name password -ErrorAction SilentlyContinue