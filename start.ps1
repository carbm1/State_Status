<#

.SYNOPSIS
This script will start a loop every X minutes to check the state servers and then upload their status.

#>

Param(
    [Parameter(Mandatory=$false)][int]$Minutes = 15
)

while ($true) {
    .\StateStatus.ps1
    .\UploadStatus.ps1
    Start-Sleep -Seconds ($Minutes * 60)
}