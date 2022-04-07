# ADF DevOps Demo

This repository can be used to setup a working demo of Azure Data Factory across multiple environments using Terraform.  This will help interesting users learn ways to setup Azure DevOps projects and connect them with Azure Data Factory to publish changes from one environment to another.

## Prerequisites
1. Azure Service Principal with Owner permissions on a subscription.  This is necessary because some of the scripts involved will setup roles and permissions in the subscription
2. Bash shell.  This can be done in Azure Shell or from any workstation that as access to /bin/bash
3. Azure CLI, jquery, envsubst and git installed on the workstation and configured.  If running for Azure Shell you will need to do the following:
   1. mkdir ~/bin
   2. cd ~/bin
   3. curl -L https://github.com/a8m/envsubst/releases/download/v1.2.0/envsubst-`uname -s`-`uname -m` -o envsubst
   4. chmod +x envsubst
8. Check that git is configured for commits by running "git config --list" and ensure that user.name and user.email are set.  If these are not set the script will fail.  Use "git config --global user.name "John Doe" and "git config --global user.email johndoe@example.com" to setup.
9. Azure Devops Extension for Azure CLI.  To install use "az extension add --name azure-devops"
10. Azure DevOps organization and Azure DevOps PAT with permissions to create ADO projects, repositories and pipelines.
11. "Microsoft.DataFactory" will need to be registered for use in the Azure Subscription you are using.  Check using "az provider list --query "[?registrationState=='Registered']" --output table"

## Directions
1. Clone this repository to an environment that can execute bash scripts
2. Ensure the bash shell has access to "az", "git", "jq", "envsubst" commands from the command line.
3. Execute "az login" and login to Azure with an account that has at least "Owner" access to the subscription.  
5. Collect the appId and password of the service principal that has Owner rights on the subscription.  This SP will be used by Azure DevOps to execute pipelines.
6. Set an environment variable called ADO_ORG with the URL to your ADO organization (https://dev.azure.com/someorg)
7. Set an environment variable called DEVOPS_PAT with the personal access token you created in Preq #4
8. Create a directory to store the files that will be created and checked into ADO.  This directory should be outside of the current git repo that you are using. In this example I'll use /tmp/adodemo.
9. cd to the "root" directory of this cloned repo.  
10. Execute "./az-project-bootstrap.sh -u SP_APPID -p "SP_PASSWORD" -d /tmp/adodemo -e DEV -e PRD".  Be sure to replace SP_APPID and SP_PASSWORD. You can optionally pass in a -n option that will be used as a prefix for the resources created, otherwise defaults will be used.
11. That's It.  Should take about 5 minutes to run.

## NOTE:
The az-project-bootstrap.sh script does a number of things and takes several options that can be viewed using the "-h" option
1. Creates multiple resource groups (one for each environment + a mgmt resource group that is used by Terraform)
2. Each environment resource group will contain an ADF and a KeyVault when completed
4. Creates an Azure DevOps project that contains 2 repositories (one for Terraform scripts and one for ADF config)
5. Creates multiple ADO pipelines (one for each environment you create and one for ADF changes)
6. The mgmt resource group will contain a Storage Account and an Azure KeyVault.  The storage account is used by Terraform to manage Azure state and the Keyvault will contain information about the service principal you passed in on the command line
7. After the initial execution of the script multiple pipelines will be executed in Azure DevOps that will use Terraform to create additional resources.  These resources will include some Data resource groups that will contain frequently used Azure resources that are consumed by ADF like a SQL Server database and a storage account
8. In each of the environment resource groups you will also have a KeyVault that works in conjuntion with the ADF for managing connection information for the resources created in the data resource groups
