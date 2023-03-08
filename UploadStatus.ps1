#Requires -Version 7.2
#Requires -Modules SimplySQL

<#

    .SYNOPSIS
    This script will upload the results into CAMTech Computer Services, LLC public dashboard.

#>

if (Test-Path "$PSScriptRoot\statestatus.sqlite3") {
    Open-SQLiteConnection -DataSource "$PSScriptRoot\statestatus.sqlite3" -ErrorAction Stop
} else {
    Write-Error "Local SQLite3 database does not exist."
    exit 1
}

function Get-JsonArray ($rows) {

    $responseArray = [System.Collections.Generic.List[Object]]::new()
    $columnNames = $rows | Get-Member | Where-Object -Property MemberType -EQ 'Property' | Select-Object -ExpandProperty Name
    $rows | Select-Object -ExcludeProperty dtUpload -Property $columnNames | ForEach-Object {
        $responseArray.Add($PSitem)
    }

    return ($responseArray | ConvertTo-Json)

}

#limited to a maximum of 50 submissions at once.
while ($rows = Invoke-SqlQuery -Query "SELECT * FROM state_status WHERE dtUpload IS NULL ORDER BY dt LIMIT 50") {
    $response = Invoke-RestMethod -Uri "https://www.camtechcs.com/statestatus/api" -Method Post -Body (Get-JsonArray $rows)
    Invoke-SqlUpdate -Query "UPDATE state_status SET dtUpload = '$(Get-Date)' WHERE rowIdentity IN ($($response.rowIdentities -join ','))"
}