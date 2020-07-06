#!/usr/bin/env pwsh

Param(
    [Parameter(Mandatory = $false)]
    [string] $OmiUrl = "https://itsomi.tools.cihs.gov.on.ca",

    [Parameter(Mandatory = $false)]
    [string] $OmiUsername = "admin",

    [Parameter(Mandatory = $false)]
    [securestring] $OmiPassword = ("P@55w0rd" | ConvertTo-SecureString -AsPlainText -Force),

    [Parameter(Mandatory = $false)]
    [string] $ElixirUrl = "https://elixir-prod.tools.cihs.gov.on.ca",

    [Parameter(Mandatory = $false)]
    [string] $ClientId = "consumer-omi-service",

    [Parameter(Mandatory = $false)]
    [securestring] $ClientSecret = ("1f153266-6d74-4770-bb7c-8b821159b7dc" | ConvertTo-SecureString -AsPlainText -Force),

    [Parameter(Mandatory = $false)]
    [switch] $CloseResolved = $true
) 



try{
    $token =  Get-ITSToolsKeycloakToken -ClientId $ClientId -ClientSecret $ClientSecret -Refresh
}catch{
    $token = Get-ITSToolsKeycloakToken -ClientId $ClientId -ClientSecret $ClientSecret -Cache -Verbose
}

$EventCloseXml = "<event xmlns=""http://www.hp.com/2009/software/opr/data_model""><state>closed</state></event>"
$AnnotationXml = @"
<annotation xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns="http://www.hp.com/2009/software/opr/data_model" type="urn:x-hp:2009:software:data_model:opr:type:event:annotation" version="1.0">
    <author>admin</author>
    <time_created>2017-04-06T20:23:56.154-04:00</time_created>
    <text>{0}</text>
</annotation>
"@
$EventListUrl = "{0}/opr-web/rest/9.10/event_list" -f $OmiUrl
$BaseUrl = "{0}/torca/elixir/api/v3" -f $ElixirUrl
$IncidentPath = "/esmt/incidents/{0}"
$IncidentMetadata = Invoke-ITSTorcaRequest -Method GET -BaseUrl $BaseUrl -Path "/esmt/incidents/metadata" -AccessToken $token.access_token
$OmiCredentials = new-object -typename System.Management.Automation.PSCredential -argumentlist "$OmiUsername", $OmiPassword
$userName = $OmiCredentials.GetNetworkCredential().UserName
$password = $OmiCredentials.GetNetworkCredential().Password
$omiBase64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $userName, $password)))
$omiHeaders = @{Authorization=("Basic {0}" -f $omiBase64AuthInfo)}
$omiQuery = "control_transferred_to[dns_name=""elixir-prod.tools.cihs.gov.on.ca""] AND state EQ ""open"" AND control_transferred_to[state=""transferred""]"

$eventList = Invoke-RestMethod -Uri "$($EventListUrl)?query=$omiQuery&page_size=3000" -Headers $omiHeaders -SessionVariable omiSession
$secureModifyCookie = $omiSession.Cookies.GetCookies($OmiUrl) | Where-Object {$_.name -eq "secureModifyToken" }
if(-not $secureModifyCookie){
    throw "Could not get secureModifyCookie from Session"
}
foreach($event in $eventList.event_list.event){
   # Write-Host "$($event.id) $($event.state) $($incident.status)"   
    $externalId = $event.control_transferred_to.external_id
    if($externalId -eq $null){
        continue
    }
    $externalIncidentPath = $IncidentPath -f $externalId
    $incident = Invoke-ITSTorcaRequest -Method GET -BaseUrl $BaseUrl -Path $externalIncidentPath -AccessToken $token.access_token
    $incidentStatus = ($IncidentMetadata.field_limits.status.values | Where-Object {$_.number -eq $incident.status}).value
    if($incident.status -ge 4){
        if($incident.status -eq 4){
            $IncidentValue = "Resolved"
        }
        if($incident.status -eq 5){
            $IncidentValue = "Closed"
        }
        if($incident.status -eq 6){
            $IncidentValue = "Cancelled"
        }
        $headers = $omiHeaders
        $headers["X-Secure-Modify-Token"] = $secureModifyCookie.Value
        $headers["Content-Type"] = "application/xml"
        $headers["Accept"] = "application/xml"
        if($CloseResolved){
            Start-Sleep -Seconds 5
            $eventUrl = "$EventListUrl/{0}" -f $event.id
            Write-Host "Closing $($event.id), $($IncidentValue), $($externalId),  $($incident.assignee), $($incident.assigned_group)" 
            Write-Output "Closing $($event.id), $($IncidentValue), $($externalId),  $($incident.assignee), $($incident.assigned_group)" | Out-File -append C:\temp\closeOmiIncidents.txt
            #Invoke-WebRequest -Method Put -Uri $eventUrl -Headers $headers -Body $EventCloseXml -WebSession $omiSession
        }else{
            Write-Host "Event $($event.id) $($event.key) state:$($event.state) - Resolved in ESMT - $($incident.incident_number) - $incidentStatus"
            Write-Host "Resolution $($incident.resolution)"
        }
    }
}
