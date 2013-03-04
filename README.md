IIS-ARR-Zero-Downtime
=====================

Powershell script to achive zero downtime deployments using IIS ARR module. 
It uses the Green / Blue deployment strategy: two sites and reverse proxy in front of them (ARR in this case).
Only one site is running at a time. The script deploys to the stopped site, warms it up and the 
swaps the reverse proxy to route requests to the new site. Finally it stops the old site.

Invoking the Deploy method assumes:
 1. There are 2 stopped sites called $projectName-Green and $projectName-Blue. Green bound only to $deploymentGreenNodeAddress and Blue only bound to deploymentBlueNodeAddress, both using port $deploymentNodesPort
 2. There is a farm called $projectName-Farm
 3. The farm has 2 nodes, each pointing to one of the sites (Blue and Green)
 4. There is a rewrite rule to redirect requests to the farm when the port ({SERVER_PORT}) does not match $deploymentNodesPort

#File Strcuture
 - C:\PATH_TO_YOUR_CODE\$projectName        (This folder holds the files to be deployed)
 - C:\PATH_TO_YOUR_CODE\$projectName-Green  (Can be empty to start with - deployment files will be copied here when activating this node)
 - C:\PATH_TO_YOUR_CODE\$projectName-Blue   (Can be empty to start with - deployment files will be copied here when activating this node)

#IIS Sites
 - "$projectName"           (ARR Site)              Running
 - "$projectName-Green"     (Balanced Site Green)   Stopped
 - "$projectName-Blue"      (Balanced Site Blue)    Stopped

#Web Farms
 - "$projectName-Farm"  
   - "$deploymentBlueNodeAddress"     Unavailable
   - "$deploymentGreenNodeAddress"    Unavailable

This script provides some utility funcions to automate the creating of the sites, farms and nodes
but you don't need to use them. By calling "Deploy" the script assumes all the above has been setup.

#Usage

A bat file is all is required:

powershell     -ExecutionPolicy unrestricted -file "FULL PATH TO PS1 FILE"
pause

The default behaviour of the script is just to call the Deploy funcion, which assumes all sites, farms, nodes and IPs 
are setup. This funcions just deploys to the inactive node, swaps ARR to use it, and deactivates the active node.

If you are using Windows 2012 / Windows 8 you can also use the utility funcions to script most of the 
setup process. Create a Farm, the nodes and add the IPs to your local interface.
