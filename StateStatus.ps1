#Requires -Version 7.2
#Requires -Modules CognosModule,eSchoolModule,SimplySQL

<#

    .SYNOPSIS
    This script will monitor state servers for authentication and data.

    .DESCRIPTION
    This script will only ever use the DefaultConfig of the CognosModule to test services.

#>

try {
    Open-SQLiteConnection -DataSource "$PSScriptRoot\statestatus.sqlite3" -ErrorAction Stop

    Invoke-SqlUpdate -Query 'CREATE TABLE IF NOT EXISTS "state_status" (
        "rowIdentity"   INTEGER,
        "district"      TEXT NOT NULL,
        "service"	    TEXT NOT NULL,
        "method"        TEXT NOT NULL,
        "status"        INTEGER NOT NULL,
        "server"        TEXT,
        "dt"            TEXT NOT NULL,
        "dtUpload"      TEXT,
        PRIMARY KEY("rowIdentity" AUTOINCREMENT)
    );' | Out-Null

} catch {
    Write-Error "Failed to open SQLite Database."
    exit 1
}

$districtLEA = Get-Content "$($env:userprofile)\.config\Cognos\DefaultConfig.json" | 
    ConvertFrom-Json | 
    Select-Object -ExpandProperty Username | 
    Select-String -Pattern "(\d+).*" | 
    Select-Object -ExpandProperty Matches | 
    Select-Object -ExpandProperty Groups | 
    Select-Object -Skip 1 -ExpandProperty Value


#Hashtables to build results.
function New-StatusObject {
    return [ordered]@{
        district = $districtLEA
        service = $null
        method = $null
        status = 0 #boolean false
        server = $null
        dt = (Get-Date)
        dtUpload = $null
    }
}

function Write-StatusToDB ($statusObject) {
    # "INSERT INTO state_status ('$($statusObject.keys -join ''',''')') VALUES (@$($statusObject.keys -join ',@'))"
    Invoke-SqlUpdate -Query "INSERT INTO state_status ('$($statusObject.keys -join ''',''')') VALUES (@$($statusObject.keys -join ',@'))" -Parameters $statusObject | Out-Null
}

#Check eSchool Login
Try {

    $eSchoolLoginStatus = New-StatusObject
    $eSchoolLoginStatus.service = 'eSP'
    $eSchoolLoginStatus.method = 'login'

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

    $eSchoolTaskStatus = New-StatusObject
    $eSchoolTaskStatus.service = 'eSP'
    $eSchoolTaskStatus.method = 'tasks'

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

    $CognosLoginStatus = New-StatusObject
    $CognosLoginStatus.service = 'cognos'
    $CognosLoginStatus.method = 'login'

    Connect-ToCognos

    $CognosLoginStatus.status = 1 #boolean true
    
    Write-StatusToDB $CognosLoginStatus

} catch {

    Write-Error "Failed to Login to Cognos"
    Write-StatusToDB $CognosLoginStatus

}

#Check Cognos Report Pull.
Try {

    $CognosReportStatus = New-StatusObject
    $CognosReportStatus.service = 'cognos'
    $CognosReportStatus.method = 'report'

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

    $SSOReportStatus = New-StatusObject
    $SSOReportStatus.service = 'sso'
    $SSOReportStatus.method = 'login'

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

    $passwordForm = @{
        'loginform:password' = $password
        'loginform:loginButton' = 'Sign In'
        'loginform_SUBMIT' = 1
        'javax.faces.ViewState' = ($ssoResponse2.InputFields | Where-Object { $PSItem.name -eq 'javax.faces.ViewState' })[0].value
    }

    #submit password
    $ssoResponse3 = Invoke-WebRequest -Uri "https://k12.ade.arkansas.gov/identity/self-service/ade/login.jsf" `
        -Method "POST" `
        -WebSession $ssoSession `
        -Form $passwordForm

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