#Requires -Version 7.2
#Requires -Modules CognosModule,eSchoolModule,SimplySQL

<#

    .SYNOPSIS
    This script will monitor state servers for authentication and data.

    .DESCRIPTION
    This script will only ever use the DefaultConfig of the CognosModule to test services.

#>

$version = '23.3.9'

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

#Check State AD/SSO/EPAMSA (Entity Password and Account Management for State Applications) or whatever its called now.
Try {

    $SSOReportStatus = New-StatusObject -service 'sso' -method 'login'

    $accountInfo = Get-Content "$($env:userprofile)\.config\Cognos\DefaultConfig.json" | ConvertFrom-Json

    $username = $accountInfo.Username
    $password = (New-Object PSCredential "user",$($accountInfo | Select-Object -ExpandProperty password | ConvertTo-SecureString)).GetNetworkCredential().Password
    
    #this will be a 301 to the login page.
    $ssoResponse = Invoke-WebRequest -Uri https://k12.ade.arkansas.gov -TimeoutSec 5 -SessionVariable ssoSession

    $jsessionId = ($ssoResponse.Headers.'Set-Cookie' | Select-String -Pattern 'JSESSIONID=(\w{32})').Matches.Groups[1].Value
    $browserId = (New-Guid) -replace '-',''

    $usernameForm = @{
        'loginform:userid' = $username
        'loginform:browserId' = $browserId
        'loginform:showCaptcha' = 'false'
        'loginform:captchaType' = 'JCAPTCHA'
        'loginform:reCaptchaSiteKey' = ''
        'loginform:loginButton' = 'Next'
        'loginform_SUBMIT' = '1'
        'javax.faces.ViewState' = ($ssoResponse.InputFields | Where-Object { $PSItem.name -eq 'javax.faces.ViewState' })[0].value
    }

    #submit username
    $ssoResponse2 = Invoke-WebRequest -Uri "https://k12.ade.arkansas.gov/identity/self-service/ade/login.jsf;jsessionid=$($jsessionId)" `
        -Method "POST" `
        -WebSession $ssoSession `
        -Form $usernameForm

    #submit password
    $ssoResponse3 = Invoke-WebRequest -Uri "https://k12.ade.arkansas.gov/identity/self-service/ade/login.jsf" `
        -Method "POST" `
        -WebSession $ssoSession `
        -Form (@{
            'loginform:password' = $password
            'loginform:loginButton' = 'Sign In'
            'loginform_SUBMIT' = 1
            'javax.faces.ViewState' = ($ssoResponse2.InputFields | Where-Object { $PSItem.name -eq 'javax.faces.ViewState' })[0].value
        })

    #submit login
    $ssoResponse4 = Invoke-WebRequest -Uri "https://k12.ade.arkansas.gov/identity/self-service/ade/loggedin.jsf" `
        -Method "POST" `
        -WebSession $ssoSession `
        -Form (@{
            'loginform:advanceButton' = 'Submit'
            'loginform_SUBMIT' = 1
            'javax.faces.ViewState' = ($ssoResponse3.InputFields | Where-Object { $PSItem.name -eq 'javax.faces.ViewState' })[0].value
        })

    #if the page doesn't redirect you're logged in.
    $ssoResponse5 =  Invoke-WebRequest -Uri "https://k12.ade.arkansas.gov/identity/self-service/ade/ussp.jsf" -WebSession $ssoSession -MaximumRedirection 0

    $SSOReportStatus.status = 1

    Write-StatusToDB $SSOReportStatus

} catch {

    Write-Error "Failed to login to SSO."
    Write-StatusToDB $SSOReportStatus

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

#Cleanup CognosSession
Remove-Variable -Name CognosSession -Scope Global -Force -ErrorAction SilentlyContinue

#Cleanup SSO
Remove-Variable -Name ssoSession -ErrorAction SilentlyContinue

#Cleanup eFinance
Remove-Variable -Name eFinanceSession -ErrorAction SilentlyContinue

#Do not leave username/password in memory.
Remove-Variable -Name username -ErrorAction SilentlyContinue
Remove-Variable -Name password -ErrorAction SilentlyContinue