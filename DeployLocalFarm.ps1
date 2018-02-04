# Invoking the Deploy method assumes:
# 1. There 2 stopped sites called $projectName-Green and $projectName-Blue. Green bound only to $deploymentGreenNodeAddress and Blue only bound to deploymentBlueNodeAddress, both using port $deploymentNodesPort
# 2. There is a farm called $projectName-Farm
# 3. The farm has 2 nodes, each pointing to one of the sites (Blue and Green)
# 4. There is a rewrite rule to redirect requests to the farm when the port ({SERVER_PORT}) does not match $deploymentNodesPort
# 5. There is a healthcheck in the farm pointing to the main url of the farm
#
# File Strcuture
# - C:\PATH_TO_YOUR_CODE\$projectName        (This folder holds the files to be deployed)
# - C:\PATH_TO_YOUR_CODE\$projectName-Green  (Can be empty to start with - deployment files will be copied here when activating this node)
# - C:\PATH_TO_YOUR_CODE\$projectName-Blue   (Can be empty to start with - deployment files will be copied here when activating this node)
#
# IIS Sites
# - "$projectName"           (ARR Site)              Running
# - "$projectName-Green"     (Balanced Site Green)   Stopped
# - "$projectName-Blue"      (Balanced Site Blue)    Stopped
#
# Web Farms
# - "$projectName-Farm"  
#   - "$deploymentBlueNodeAddress"     Unavailable
#   - "$deploymentGreenNodeAddress"    Unavailable
#
# This script provides some utility funcions to automate the creating of the sites, farms and nodes
# but you don't need to use them. By calling "Deploy" the script assumes all the above has been setup.
#
# XML Schema for ARR: %windir%\system32\inetsrv\config\schema\arr_schema.xml


[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Web.Administration")
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
Import-Module webadministration -ErrorAction Stop
Add-PSSnapin WebFarmSnapin

Clear-Host

$deploymentBlueNodeAddress   = "127.0.0.1"             #The ip of the node representing the blue site
$deploymentGreenNodeAddress  = "127.0.0.2"             #The ip of the node representing the blue site
$deploymentBlueNodePort      = 22001                   #The port used by both sites and nodes
$deploymentGreenNodePort     = 22002                   #The port used by both sites and node2
$path                        = "C:\inetpub\wwwroot\"   #The path where the deployment, blue and green sites are. Script will look for the deployment files in $path\$projectName and copy them to $path\$projectName-Green and $path\$projectName-Blue
$projectName                 = "YOUR SITE NAME"        #The base name for the IIS balanced sites (Blue and Green) and the folders holding their application files
$networkInterfaceAlias       = "Ethernet"              #The name of the network adapter where to create the IPs bound to the balanced sites

Set-Location $path

Function HasIpAddress($ip){
    $r = Get-NetIPAddress | 
        Where-Object{ $_.InterfaceAlias -eq $networkInterfaceAlias } |
        Where-Object{ $_.IPAddress -eq $ip }
    return $r -ne $null
}

Function CreateIpAddress($ip){
    Write-Host "Adding IP $ip to interface $networkInterfaceAlias"
    $r = New-NetIPAddress –InterfaceAlias $networkInterfaceAlias -IPAddress $ip -PrefixLength 24
}

Function CreateBalancedSite($sufix, $ip, $port) {
    $hasIp = HasIpAddress $ip
    if($hasIp -eq $false) {
        $r = CreateIpAddress($ip)
    }

    $foundSite = Get-Website $projectName-$sufix
    if($foundSite -eq $null){
        $r = CreateWebSite $sufix $port $ip "$path\$projectName-$sufix"
    }
}

Function CreateWebSite($sufix, $port, $ip, $path) {
    Write-Host "Creating site $projectName-$sufix..."
    md -Path $path
    $r = New-Website -Name "$projectName-$sufix" -Port $port -IPAddress $ip -PhysicalPath $path
} 

Function ChangeNodeStatus($farm, $nodeAddress, $status){ #status can be "Start", "Drain", "ForcefulStop", "GracefulStop"

    #Find the node mapped to the site we are going to the deploy the files to
    $nodes          = $farm.GetCollection()
    $deploymentNode = $nodes | Where-Object { $_.GetAttributeValue("address") -eq $nodeAddress }
    if($deploymentNode -eq $null){
        Write-Error "Could not find deploymentNode with address $nodeAddress"
        exit 1
    }
    $arrObject = $deploymentNode.GetChildElement("applicationRequestRouting")

    #Change the node status
    Write-Host "Changing status for node $nodeAddress to $status"
    $setStateMethod     = $arrObject.Methods["SetState"]
    $setStateMethodInst = $setStateMethod.CreateInstance()
    $newStateProp       = $setStateMethodInst.Input.Attributes[0].Value = $status
    $setStateMethodInst.Execute()
}

Function ChangeNodeToHealthy($farm, $nodeAddress) {
    #Find the node mapped to the site we are going to the deploy the files to
    $nodes          = $farm.GetCollection()
    $deploymentNode = $nodes | Where-Object { $_.GetAttributeValue("address") -eq $nodeAddress }
    if($deploymentNode -eq $null){
        Write-Error "Could not find deploymentNode with address $nodeAddress"
        exit 1
    }
    $arrObject = $deploymentNode.GetChildElement("applicationRequestRouting")
    #Change the node status
    Write-Host "Changing health status for node $nodeAddress to healthy..."

    $setStateMethod     = $arrObject.Methods["SetHealthy"]
    $setStateMethodInst = $setStateMethod.CreateInstance()
    $setStateMethodInst.Execute()

}

Function SetNodeHttpPort($farmName, $ip, $port) {

    $computer = gc env:computername
    $iis    = [Microsoft.Web.Administration.ServerManager]::OpenRemote($computer.ToLower())

    #Get app host configuration file and the webfarms section within it
    $conf            = $iis.GetApplicationHostConfiguration()
    $webFarmsSection = $conf.GetSection("webFarms")
    $webFarms        = $webFarmsSection.GetCollection()
    $farm            = $webFarms | Where-Object { $_.GetAttributeValue("name") -eq $farmName }
    $nodes           = $farm.GetCollection()
    $deploymentNode  = $nodes | Where-Object { $_.GetAttributeValue("address") -eq $ip }
    $httpPort        = $deploymentNode.ChildElements.Attributes | Where-Object { $_.Name -eq "httpPort" }
    $httpPort.Value  = $port
    $iis.CommitChanges()
}

Function CreateFarmNode($nodeAddress) {
    
    $computer = gc env:computername
    $iis    = [Microsoft.Web.Administration.ServerManager]::OpenRemote($computer.ToLower())
    $sites  = $iis.sites |
                 Select-Object Id, Name, State |
                 Format-Table -AutoSize

    #Get app host configuration file and the webfarms section within it
    $conf            = $iis.GetApplicationHostConfiguration()
    $webFarmsSection = $conf.GetSection("webFarms")
    $webFarms        = $webFarmsSection.GetCollection()
   
    #Find the farm by its name
    $farmName = "$projectName-Farm"
    $farm = $webFarms | Where-Object { $_.GetAttributeValue("name") -eq $farmName }
    if($farm -eq $null){
        New-WebFarm $farmName -Enabled
        New-Server -WebFarm $farmName -Address $deploymentBlueNodeAddress  
        New-Server -WebFarm $farmName -Address $deploymentGreenNodeAddress

        SetNodeHttpPort "$projectName-Farm" $deploymentBlueNodeAddress $deploymentBlueNodePort -Enabled
        SetNodeHttpPort "$projectName-Farm" $deploymentGreenNodeAddress $deploymentGreenNodePort
    }
    else{
        #Find the node mapped to the site we are going to the deploy the files to
        $nodes          = $farm.GetCollection()
    }

    
    

}

Function CreateRewriteRule($port) {
    $rule = Get-WebConfigurationProperty "/system.webserver/rewrite/globalRules/rule[@name='$projectName']" -Name "name"
    if ($rule -eq $null){
        $serverManager = new-object Microsoft.Web.Administration.ServerManager 
        $config = $serverManager.GetApplicationHostConfiguration();
        $rulesSection = $config.GetEffectiveSectionGroup().SectionGroups["system.webServer"].Sections["rewrite"]
        $rulesSection 
    }
}

Function Deploy() {
    $computer = gc env:computername
    $iis    = [Microsoft.Web.Administration.ServerManager]::OpenRemote($computer.ToLower())

    $blueSiteName   = "$projectName-Blue"
    $greenSiteName  = "$projectName-Green"

    $blueSite = Get-Website $blueSiteName
    $greenSite = Get-Website $greenSiteName

    if($blueSite -eq $null){
        Write-Error "Could not find IIS website $blueSiteName"
        exit 1
    }
    if($greenSite -eq $null){
        Write-Error "Could not find IIS website $greenSiteName"
        exit 1
    }

    $blueStatus  = Get-WebsiteState $blueSiteName
    $greenStatus = Get-WebsiteState $greenSiteName
    $farmName    = "$projectName-Farm"

    #decide which node to deploy
    if($blueStatus.Value -eq "Stopped"){
        $stoppedNodeAddress  = $deploymentBlueNodeAddress
        $stoppedSiteName     = "$projectName-Blue"
        $runningNodeAddress  = $deploymentGreenNodeAddress
        $runningSiteName     = "$projectName-Green"
        $wakeUpPort          = $deploymentBlueNodePort
    }
    else {
        $stoppedNodeAddress  = $deploymentGreenNodeAddress
        $stoppedSiteName     = "$projectName-Green"
        $runningNodeAddress  = $deploymentBlueNodeAddress
        $runningSiteName     = "$projectName-Blue"
        $wakeUpPort          = $deploymentGreenNodePort
    }

    #Get app host configuration file and the webfarms section within it
    $conf            = $iis.GetApplicationHostConfiguration()
    $webFarmsSection = $conf.GetSection("webFarms")
    $webFarms        = $webFarmsSection.GetCollection()


    #Find the farm by its name
    $farm = $webFarms | Where-Object { $_.GetAttributeValue("name") -eq $farmName }
    if($farm -eq $null){
        Write-Error "Could not find farm $farmName"
        exit 1
    }

    $deploymentSite      = Get-Item IIS:\Sites\$stoppedSiteName
    $deploymentSitePath  = $deploymentSite.PhysicalPath
    $deploymentFilesPath = $path + "\" + $projectName + "\"
    $archivePath         = $deploymentFilesPath + $projectName + ".zip"


    #Deploy files
    $shell = New-Object -com shell.application 
    $destination = $shell.namespace($deploymentSitePath) 
    # If there is a zip file, use it to deploy
    if (Test-Path $archivePath) {
        Write-Host "Extracting archive '$archivePath' to $deploymentFilesPath..."
        $zipFile = $shell.namespace($archivePath) 
        $destination.Copyhere($zipFile.items(), [System.Int32]1556)
    }
    else {
        Write-Host "Copying raw files to $deploymentSitePath..."
        Copy-Item -Path ($deploymentFilesPath + "\*") -Filter *.* -Destination $deploymentSitePath -Recurse -Force
    }

    Write-Host "Starting deployment website..."
    Start-Website $stoppedSiteName

    #wake up deployment site
    $url = "http://" + $stoppedNodeAddress + ":$wakeUpPort/"
    Write-Host "Starting deployment website $url..."
    $page = (New-Object System.Net.WebClient).DownloadString($url)

    #Swap farm nodes
    ChangeNodeToHealthy $farm $stoppedNodeAddress
    ChangeNodeStatus $farm $stoppedNodeAddress "Start"
    ChangeNodeStatus $farm $runningNodeAddress "Drain"
    
    #Wait a minute for connections to drain
    Write-Host "Waiting 60 secs for connections to drain..."
    Start-Sleep -s 60

    #Stop old code website
    Stop-Website $runningSiteName
}

Deploy

Write-Host "Done"





