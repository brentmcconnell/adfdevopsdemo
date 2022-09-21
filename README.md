# ADF DevOps Demo

This repository can be used to setup a working demo of Azure Data Factory across multiple environments using Terraform.  This will help interesting users learn ways to setup Azure DevOps projects and connect them with Azure Data Factory to publish changes from one environment to another.

**NOTE: This is ONLY an example and should not be used for production purposes.  I, nor my employer, make no guarantees or warannties for use of this script.  Use at your own risk.**

## Prerequisites
1. Azure Service Principal with Owner permissions on a subscription.  This is necessary because some of the scripts involved will setup roles and permissions in the subscription.  Using the az cli this can be done with "az ad sp create-for-rbac --role Owner --name ownersp --scopes /subscriptions/xxxxx"
2. Bash shell.  This can be done in Azure Shell or from any workstation that as access to /bin/bash
3. Azure CLI, jquery, envsubst and git installed on the workstation and configured.  If running in Azure Shell you will need to do the following to install envsubst:
```
  mkdir ~/bin
  cd ~/bin
  curl -L https://github.com/a8m/envsubst/releases/download/v1.2.0/envsubst-`uname -s`-`uname -m` -o envsubst
  chmod +x envsubst
```
4. Check that git is configured for commits by running "git config --list" and ensure that user.name and user.email are set.  If these are not set the script will fail.  Use "git config --global user.name 'John Doe'" and "git config --global user.email 'johndoe@example.com'" to setup.
5. Azure Devops Extension for Azure CLI.  To install use "az extension add --name azure-devops"
6. Azure DevOps organization and Azure DevOps PAT with Full Access. This is important since this script creates several objects in Azure DevOps and requires the ability to create ADO projects, repos, pipelines, service connections, variables, etc.
7. "Microsoft.DataFactory" will need to be registered for use in the Azure Subscription you are using.  Check using "az provider list --query "[?registrationState=='Registered']" --output table"

## Directions
1. Clone this repository to an environment that can execute bash scripts (git clone https://github.com/brentmcconnell/adfdevopsdemo.git)
2. Ensure the bash shell has access to "az", "git", "jq", "envsubst" commands in $PATH.
3. Execute "az login" and login to Azure with an account that has at least "Owner" access to the subscription.  If you are using Azure Shell you will already be logged in with using az.
5. Collect the appId and password of the service principal that has Owner rights on the subscription.  This SP will be used by Azure DevOps to execute pipelines.  This information was created in the Prerequisites section.
6. Set an environment variable called ADO_ORG with the URL to your ADO organization (export ADO_ORG=https://dev.azure.com/someorg)
7. Set an environment variable called DEVOPS_PAT with the personal access token you created in Preq #6 (export DEVOPS_PAT=xxxxxxxxxxxxxxx)
8. Create a directory to store the files that will be created and checked into ADO.  This directory should be outside of the current git repo that you are using. In this example I'll use /tmp/adodemo. (mkdir -p /tmp/adodemo)
9. cd to the "root" directory of this cloned repo.  (cd /tmp/adodemo)
10. Execute: 
```
   ./az-project-bootstrap.sh \
      -u SP_APPID \
      -p "SP_PASSWORD" \
      -d /tmp/adodemo \
      -e DEV -e PRD
```  
10. That's It.  Should take about 5 minutes to run.

## NOTE:
The az-project-bootstrap.sh script does a number of things and takes several options that can be viewed using the "-h" option
1. Can be used with multiple "-e" options to create more than 2 environments, however this has not been tested and will likely not work flawlessly.
2. Creates multiple resource groups (one for each environment + a mgmt resource group that is used by Terraform)
3. Each environment resource group will contain an ADF and a KeyVault when completed
4. Creates an Azure DevOps project that contains 2 repositories (one for Terraform scripts and one for ADF config)
5. Creates multiple ADO pipelines (one for each environment you create and one for ADF changes)
6. The mgmt resource group will contain a Storage Account and an Azure KeyVault.  The storage account is used by Terraform to manage Azure state and the Keyvault will contain information about the service principal you passed in on the command line
7. After the initial execution of the script multiple pipelines will be executed in Azure DevOps that will use Terraform to create additional resources.  These resources will include some Data resource groups that will contain frequently used Azure resources that are consumed by ADF like a SQL Server database and a storage account
8. In each of the environment resource groups you will also have a KeyVault that works in conjuntion with the ADF for managing connection information for the resources created in the data resource groups

## CLEANUP
The az-project-bootstrap-cleanup.sh script can be used to cleanup the resource groups and Azure DevOps project that was created above.  NOTE:  Great care should be used with this script since it DELETES lots of things.
```
./az-project-bootstrap-cleanup.sh \
  -g PROJ1234-DATA-DEV-RG \
  -g PROJ1234-DATA-PRD-RG \
  -g PROJ1234-DEV-RG \
  -g PROJ1234-PRD-RG \
  -g PROJ1234-MGMT-RG \
  -d bootstrap-PROJ1234
```
NOTE: above you can place as many resource groups as necessary that you want to remove with the "-g" option.  You also pass in the ADO project with "-d"
