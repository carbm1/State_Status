<#

.SYNOPSIS
Create a simple download definition with no confidential data that can be quickly run and monitored to validate that
eSchool tasks are running, producing files, and that you can download the file.

#>

$newDefinition = New-espDefinitionTemplate -InterfaceId CAMST -Description "CAMTech State Monitoring"

$newDefinition.UploadDownloadDefinition.InterfaceHeaders += New-eSPInterfaceHeader `
	-InterfaceId "CAMST" `
	-HeaderId 1 `
	-HeaderOrder 1 `
	-FileName "camtech-state-monitoring.csv" `
	-TableName "atttb_state_grp" `
	-Description "CAMTech State Monitoring" `
	-AdditionalSql @'
	WHERE 1=2
	UNION
	SELECT 'version' AS 'Name', '24.5.10' AS 'Value'
	UNION
	SELECT 'timestamp' AS 'Name', CONVERT(varchar,(GETDATE())) AS 'Value'
	UNION
	SELECT 'students_active' AS 'Name', CONVERT(varchar,(COUNT(*))) AS 'Value' FROM REG WHERE CURRENT_STATUS = 'A'
	UNION
	SELECT 'students_inactive' AS 'Name', CONVERT(varchar,(COUNT(*))) AS 'Value' FROM REG WHERE CURRENT_STATUS='I'
	UNION
	SELECT 'buildings' AS 'Name', CONVERT(varchar,(COUNT(*))) AS 'Value' FROM REG_BUILDING WHERE BUILDING NOT IN (80000,88000,9000)
'@
	
$newDefinition.UploadDownloadDefinition.InterfaceHeaders[0].InterfaceDetails +=	New-eSPDefinitionColumn `
	-InterfaceId "CAMST" `
	-HeaderId 1 `
	-TableName "atttb_state_grp" `
	-FieldId 1 `
	-FieldOrder 1 `
	-ColumnName CODE `
	-FieldLength 9999 `
	-ColumnOverride 'Name'

$newDefinition.UploadDownloadDefinition.InterfaceHeaders[0].InterfaceDetails +=	New-eSPDefinitionColumn `
	-InterfaceId "CAMST" `
	-HeaderId 1 `
	-TableName "atttb_state_grp" `
	-FieldId 2 `
	-FieldOrder 2 `
	-ColumnName ACTIVE `
	-FieldLength 9999 `
	-ColumnOverride 'Value'

Remove-eSPInterfaceId -InterfaceId CAMST
New-eSPDefinition -Definition $newDefinition
Connect-ToeSchool

