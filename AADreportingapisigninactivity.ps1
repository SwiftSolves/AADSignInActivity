<#
    .DESCRIPTION
        This runbook will invoke web requests against graph.windows.net and query signin activities and store them in a JSON format in Azure Files. To be used via a schedule as the last row login date \ time is stored and queried greater then against on next run

    .NOTES
        AUTHOR: @SwiftSolves
        LASTEDIT: Mar 10, 2017
#>

$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
# This script will require the Web Application and permissions setup in Azure Active Directory
$aadcred = Get-AutomationPSCredential -Name 'ClientID' #stored in Azure Automation Credential \ AAD SPN Client ID
$storecred = Get-AutomationPSCredential -Name 'Storage' #stored in Azure Automation Credential \ Storage Account Credential
$ClientID       = $aadcred.UserName            # Should be a ~35 character string insert your info here
$ClientSecret   = $aadcred.GetNetworkCredential().Password
$loginURL       = "https://login.windows.net/"
$tenantdomain   = (Get-AzureRmAutomationVariable -AutomationAccountName "automationaccountname" -ResourceGroupName "resourcegroupname" -Name "TenantDomain").value # Stored as variable For example, contoso.onmicrosoft.com
$daterange            
$StoreUser = $storecred.UserName
$StorePassword = $storecred.GetNetworkCredential().Password
 
#custom date range stored in azure automation account, this variable is update at end of the script and is used at begining to start collecting the latest sign in activity since last run
$ctxcustomrange = (Get-AzureRmAutomationVariable -AutomationAccountName "automationaccountname" -ResourceGroupName "resourcegroupname" -Name "aadlastrun").value
 
Write-Output $ctxcustomrange
 
# Get an Oauth 2 access token based on client id, secret and tenant domain
$body       = @{grant_type="client_credentials";resource=$resource;client_id=$ClientID;client_secret=$ClientSecret}
 
$oauth      = Invoke-RestMethod -Method Post -Uri $loginURL/$tenantdomain/oauth2/token?api-version=1.0 -Body $body
 
if ($oauth.access_token -ne $null) {
$headerParams = @{'Authorization'="$($oauth.token_type) $($oauth.access_token)"}
 
$url = "https://graph.windows.net/$tenantdomain/activities/signinEvents?api-version=beta&`$filter=signinDateTime ge $ctxcustomrange" 

 
# Lopping through and collecting sign in activity results 
$i=0
$data = $null
Do{
    Write-Output "Fetching data using Uri: $url"
    $myReport = (Invoke-WebRequest -UseBasicParsing -Headers $headerParams -Uri $url)
    Write-Output "Save the output to a file SigninActivities$i.json"
    Write-Output "---------------------------------------------"
    
	#Build array of JSON results
	$requestData = ConvertFrom-Json $myReport.Content
    if($data -eq $null){
        $data = $requestData
    } else {
        foreach($v in $requestData.value){ $data.value += $v }
    }
    $url = ($myReport.Content | ConvertFrom-Json).'@odata.nextLink'
    $i = $i+1
} while($url -ne $null)
} else {
    Write-Host "ERROR: No Access Token"
}

#date of ran log 
$filelogdate = Get-Date -format "MMddyyyyhhmm"

# saving aad activity sign in locally
$Outputfile = "c:\temp\signinactivity_" + $filelogdate + ".json"

ConvertTo-Json -InputObject $data | Out-File -FilePath $Outputfile -force

#Search last record of sign in activity
$lastRecord = ($data.value | Sort-Object -Descending {$_.signinDateTime})

#Check to make sure since last run actual JSON was collected, if so set the automation variable that is persisted outside of script with the latest date\time of sign activity to be used on next run to pick up where this log left off
$lastDate = $ctxcustomrange
if($lastRecord -ne $null){
    $lastDate = $lastRecord[0].signinDateTime
    Set-AzureRmAutomationVariable -AutomationAccountName "automationaccountname" -ResourceGroupName "resourcegroupname" -Name aadlastrun -Value $lastDate -Encrypted:$false
}
 
#Azure storage Context
$ctx=New-AzureStorageContext $StoreUser $StorePassword

# upload a local file to the new Azure Files directory
$azurefiledrop = "signinactivity_" + $filelogdate + ".json"
Set-AzureStorageFileContent -ShareName "AzureFileShareName" -Source $Outputfile -Path $azurefiledrop -Context $ctx