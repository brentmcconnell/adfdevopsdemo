#!/bin/bash -x
# This script bootstraps a Terraform project for Azure DevOps
# Running this script will create a remote tfstate file in a storage account.
# It also will create several resource groups and an Azure DevOps project.
# A service principal with Contributor to a subscription is required as 
# well as an ADO PAT that can create projects in Azure DevOps.

set -o errexit  # exit if any statement returns a non-true return value
shopt -s expand_aliases

# Print out something but not the real thing
mask() {
  local n=${#1}/2              # number characters left intact
  local a="${1:0:${#1}-n}"     # take all but the last n chars
  local b="${1:${#1}-n}"       # take the final n chars 
  printf "%s%s\n" "${a//?/*}" "$b"   # substitute a with asterisks
}

upper() {
  echo $1 | tr "[:lower:]" "[:upper:]"
}

lower() {
  echo $1 | tr "[:upper:]" "[:lower:]"
}

# geta and gets are functions for printing out Yaml in Bash less than v4
geta() {
  local _ref=$1
  local -a _lines
  local _i
  local _leading_whitespace
  local _len

  IFS=$'\n' read -rd '' -a _lines ||:
  _leading_whitespace=${_lines[0]%%[^[:space:]]*}
  _len=${#_leading_whitespace}
  for _i in "${!_lines[@]}"; do
    eval "$(printf '%s+=( "%s" )' "$_ref" "${_lines[$_i]:$_len}")"
  done
}

gets() {
  local _ref=$1
  local -a _result
  local IFS

  geta _result
  IFS=$'\n'
  printf -v "$_ref" '%s' "${_result[*]}"
}

usage() { 
  echo "`basename $0`"
  echo "   Usage: " 
  echo "     [-u <service principal appid>] service principal appid"
  echo "     [-p <service principal password>] service principal password.  Required if using -u"
  echo "     [-e <environment(s)>] environmental purpose.  This option can be used multiple times.  The last -e will be considered 'production' and be linked to the 'main' branch in Git.  Default is 'dev'"
  echo "     [-s <storage account>] storage account to use for Terraform state"
  echo "     [-c <container name>] storage account container to use for Terraform state"
  echo "     [-k <keyvault name>] keyvault to store service principal in"
  echo "     [-r <region>] region to use. EastUs or USGovVirginia are defaults"
  echo "     [-n <prefix>] prefix to use for Azure resources.  Must be unique across Azure"
  echo "     [-d <target directory>] Creates project files at this location"
  echo "     [-a <Devops project name>] Devops project to inject service principal and pipelines into"
  echo "     [-o <org>] URL of Azure DevOps organization or Github Organization name."
  echo "     [-m <MGMT resource group>] MGMT RG.  This adds a seperate and distinct RG for the keyvault that contains the service principal and any files related to Terraform state"
  exit 1
}

# Catch any help requests
for arg in "$@"; do
  case "$arg" in
    --help| -h) 
        usage
        ;;
  esac
done

echo "Check program requirements..."
(
  set +e
  programs=(az jq git)
  missing=0
  for i in ${programs[@]}; do
      command -v $i 2&> /dev/null
      if [ $? -eq 0 ]; then
          echo " * Found $i"
      else
          echo " * ERROR: missing $i"
          missing=1
      fi
  done
  if [[ "$missing" -ne 0 ]]; then
      echo "Missing required commands"
      exit 1
  fi
  set -e
)

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while getopts c:m:a:r:g:d:n:o:s:k:p:e:u:P option
do
  case "${option}"
  in
      a) DEVOPS_PROJECT=${OPTARG};;
      g) RESOURCE_GROUP=${OPTARG};;
      m) MGMT_RESOURCE_GROUP=${OPTARG};;
      n) PREFIX=${OPTARG};;
      u) SP_APPID=${OPTARG};;
      p) SP_PASSWORD=${OPTARG};;
      e) ENV_NAME+=(${OPTARG});;
      k) KEYVAULT_NAME=${OPTARG};;
      s) STORAGE_ACCT_NAME=${OPTARG};;
      c) CONTAINER_NAME=${OPTARG};;
      r) REGION=${OPTARG};;
      d) TARGET_DIRECTORY=${OPTARG};;
      o) DEVOPS_ORG=${OPTARG};;
      *) usage;;
      : ) usage;;
  esac
done
shift "$(($OPTIND -1))"

# TODO: Support other subscriptions
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# See if SP info was passed in or not
if ! [ -z $SP_APPID ]; then
  SP_INFO=$(az ad sp show --id $SP_APPID --query '{clientId:appId, displayName:displayName, tenantId:appOwnerTenantId, objectId:objectId}' -o json)
  SP_NAME=$(echo $SP_INFO | jq -e -r 'select(.displayName != null) | .displayName')
  SP_TENANTID=$(echo $SP_INFO | jq -e -r 'select(.tenantId != null) | .tenantId')
  if [ -z $SP_PASSWORD ]; then
    echo "Password required when using -a"
    exit 1
  fi
  SP_INFO=$(echo $SP_INFO | jq -r --arg SECRET "$SP_PASSWORD" '. + {"clientSecret": $SECRET}')
  # At this point the passed in info should be formatted similar to create-for-rbac --sdk required by GH
fi

if [ -z "$SP_INFO" ]; then
  echo "No Service Principal Info provided"
  exit 1
else
  SP_OBJID=$(az ad sp show --id $SP_APPID --query objectId -o tsv)
  if [ -z SP_OBJ_ID ]; then
    echo "SP_APPID not found"
    exit 1
  fi
fi

#Get a Random number that gets used for uniqueness
RND=$(echo $RANDOM | grep -o ....$)

# 4 digit random number if no prefix is defined
if [ -z $PREFIX ]; then
  PREFIX=PROJ-$RND
fi

# Get rid of weird characters because they cause issues in some Azure resources
PREFIX=$(echo $PREFIX | tr -dc '[:alnum:]\n\r')
UPREFIX=$(echo $PREFIX | tr "[:lower:]" "[:upper:]") 
LPREFIX=$(echo $PREFIX | tr "[:upper:]" "[:lower:]") 

TERRAFORM=true

# Check if Region is passed in, otherwise eastus will be used
if [ -z "$REGION" ]; then
  # check if in gov or commercial
  CLOUD=`az account list-locations -o json | jq -r '.[0].name'`
  if [ ${CLOUD:0:5} = "usgov" ]; then
      REGION='usgovvirginia'
  else
      REGION='eastus'
  fi
fi

# If ENV_NAME is not passed in assume dev
if [ -z "$ENV_NAME" ]; then
  ENV_NAME+=("DEVELOP")
fi


for env in "${ENV_NAME[@]}"; do
  ENV_SHORT+=(${env:0:4})
  LENV_NAME+=($(echo $env | tr "[:upper:]" "[:lower:]"))
  GIT_BRANCH+=($(echo $env | tr "[:upper:]" "[:lower:]"))
  UENV=$(upper ${env:0:4})
  RESOURCE_GROUP+=($UPREFIX-$UENV-RG)
done

#Set the last Git branch to main to follow Git standards
#This will be our "production" branch
if [ ${#ENV_NAME[@]} -gt 1 ]; then
  PROD_ENV=${ENV_NAME[@]: -1}
else
  PROD_ENV="N/A"
fi
GIT_BRANCH[${#GIT_BRANCH[@]} - 1]=main

if [ -z "$MGMT_RESOURCE_GROUP" ]; then
  if [[ -z $STORAGE_ACCT_NAME && -z $KEYVAULT_NAME ]]; then
    MGMT_RESOURCE_GROUP=$UPREFIX-MGMT-RG
    MGMT_REQUIRED=true
  fi
fi

if [ $TERRAFORM == "true" ]; then
  # Set Terraform Storage Acct Name
  if [ -z "$STORAGE_ACCT_NAME" ]; then
    STORAGE_ACCT_NAME=tfst${LPREFIX}sa
    if [ ${#STORAGE_ACCT_NAME} -gt 24 ]; then
      echo "STORAGE_ACCT_NAME $STORAGE_ACCT_NAME is too long"
      exit 1
    fi
  fi

  # Set Container Name for Terraform state
  if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME=tfst${LPREFIX}
    if [ ${#CONTAINER_NAME} -gt 24 ]; then
      echo "CONTAINER_NAME $CONTAINER_NAME is too long"
      exit 1
    fi
  fi
fi

# Set Keyvault where Service Principal info will be stored
if [ -z "$KEYVAULT_NAME" ]; then
  KEYVAULT_NAME=spinfo-$LPREFIX-kv
fi

# Set Service principal name to be used
if [ -z "$SP_NAME" ]; then
  SP_NAME=$LPREFIX-sp
fi

if [ -z "$DEVOPS" ]; then
  
  DEVOPS_ORG=$ADO_ORG
  DEVOPS=$DEVOPS_PAT

  if [ -z "$DEVOPS" ]; then
    echo "ERROR: Must supply a Token for Azure DevOps.  This can be"
    echo "done either on the command line with -d or via env with DEVOPS_PAT" 
    exit 1
  fi

  # Set default org
  if [ -z "$DEVOPS_ORG" ]; then
    echo "ERROR: Must set DEVOPS_ORG using -a or have DEVOPS_ORG environment variable"
    exit 1
  fi
fi

if ! [ -z "$DEVOPS" ]; then
  IFS=$'\n'

  if [ $TERRAFORM == "true" ]; then
    # Only allow .tf and .tfvars files
    for z in $(find . -type f ! \( -name \*.tmpl -o -name \*.sh -o -name \*.md -o -name \*.yml -o -name \*.tfvars -o -name \*.tf -o -path '*/\.*' \) -print -maxdepth 1 );do
      if test -f "$z"; then
        echo "Error: Directory must only contain .tf or .tfvar files."
        echo "       This script will bootstrap tf files and check them into Git"
        echo "       in an autogenerated ADO project with any other .tf files in the directory."
        exit 1
      fi
    done
  fi
  
  unset IFS
fi

# Mask the DevOps Token, if there is one, for display
if ! [ -z $DEVOPS ]; then
  MASK_TOKEN=$(mask $DEVOPS)
fi

DEVOPS_TARGET="ADO"

if [ -z $DEVOPS_ORG ]; then
  echo "Error: DEVOPS_ORG must be defined"
  exit 1
fi

if [ -z $DEVOPS_PROJECT ]; then
  DEVOPS_PROJECT="bootstrap-$PREFIX"
fi

if ! [ -z "$TARGET_DIRECTORY" ]; then
  if ! [ -d $TARGET_DIRECTORY ]; then
    echo "Target directory doesn't exist. Please pass in an existing directory"
    exit 1
  fi
else
  TARGET_DIRECTORY=$PWD
fi

PROJECT_DIRECTORY=${TARGET_DIRECTORY}/${DEVOPS_PROJECT}

echo -e "\nThe following resources will be used or created...\n"
echo "PREFIX:               $PREFIX"
echo "PROJECT_DIRECTORY:    $PROJECT_DIRECTORY"
echo "MGMT_RESOURCE_GROUP:  $MGMT_RESOURCE_GROUP"
echo "PROTECTED ENV:        $PROD_ENV"
echo "RESOURCE_GROUP(s):    ${RESOURCE_GROUP[@]}"
echo "GIT_BRANCH(s):        ${GIT_BRANCH[@]}"
echo "ENV_NAME(s):          ${ENV_NAME[@]}"
echo "ENV_SHORT(s):         ${ENV_SHORT[@]}"
echo "SP_NAME:              $SP_NAME"
echo "KEYVAULT_NAME:        $KEYVAULT_NAME"
if [ $TERRAFORM == "true" ]; then
  echo "STORAGE_ACCT_NAME:    $STORAGE_ACCT_NAME"
  echo "CONTAINER_NAME:       $CONTAINER_NAME"
fi
echo "REGION:               $REGION"
echo "DEVOPS_ORG:           $DEVOPS_ORG"
echo "DEVOPS_TARGET:        $DEVOPS_TARGET"
echo "DEVOPS_TOKEN:         $MASK_TOKEN" 
echo "TARGET_DIRECTORY:     $TARGET_DIRECTORY"
echo ""
echo -e "NOTE: Service Principal $SP_NAME with Owner permissions on $RESOURCE_GROUP will be stored in $KEYVAULT_NAME\n"

read -p "Are you sure you want to Proceed [y/N]?"
if ! [[ "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Maybe next time!"
    exit 1 
fi



if [ -d ".git" ]; then
  echo ""
  echo "WARNING: Directory already a git repo. There will be changes made to this Git repository that may have devastating consquencies"
  read -p "Are you sure you want to Proceed [y/N]?"
  if ! [[ "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Maybe next time!"
      exit 1 
  fi
fi

cd $TARGET_DIRECTORY

set +e
BRANCH_EXISTS=$(git -P branch --list "$GIT_BRANCH")
set -e
# If branch exists already probably should abort
if ! [ -z "$BRANCH_EXISTS" ]; then
  echo "ERROR: Git branch \"$GIT_BRANCH\" already exists.  Aborting."
  exit 1
fi

alias echo="echo -e"

if [ $MGMT_REQUIRED == "true" ]; then
  MGMT_ID=$(az group create --name $MGMT_RESOURCE_GROUP --location $REGION --query id -o tsv)
fi

# Create storage account if required because of Terraform
if [ $TERRAFORM == "true" ]; then
  # Retrieve or create the storage account for Terraform state
  set +e
  SA_ID=$(az storage account show --name $STORAGE_ACCT_NAME --query "id" -o tsv)
  if [ $? -ne 0 ]; then
      echo "Storage Account does not exist.  Continuing and will create it".
      SA_ID=$(az storage account create --resource-group $MGMT_RESOURCE_GROUP --name $STORAGE_ACCT_NAME --sku Standard_LRS --encryption-services blob --query "id" -o tsv)
  fi
  set -e

  # Get storage account key
  ACCOUNT_KEY=$(az storage account keys list --account-name $STORAGE_ACCT_NAME --query [0].value -o tsv)

  # Create blob container
  az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCT_NAME --account-key $ACCOUNT_KEY 1>/dev/null

  echo "storage_account_name:   $STORAGE_ACCT_NAME"
  echo "container_name:         $CONTAINER_NAME"
fi

# Create Keyvault if it doesn't exist.  This keyvault will hold service principal info
# for our projects.  
set +e
KEYVAULT_ID=$(az keyvault show -n $KEYVAULT_NAME --query "id" -o tsv)
if [ $? -ne 0 ]; then
    echo "Keyvault does not exist.  Continuing and will create it".
    KEYVAULT_ID=$(az keyvault create -n $KEYVAULT_NAME -g $MGMT_RESOURCE_GROUP --query "id" -o tsv)
fi
set -e

if [ -z $KEYVAULT_ID ]; then
  echo "ERROR: Cannot retrieve or create Keyvault. Exitting."
  exit 1
fi

#################################
#### Create Project Resources
#################################


# Create the project resource group or retrieve the existing id
for RG in ${RESOURCE_GROUP[@]}; do
  
  CRG=$(echo $RG | tr "[:lower:]" "[:upper:]") 
  RG_ID=$(az group create --name $CRG --location $REGION --query id -o tsv)
  # Create the Mgmt RG for storage account and ado SP keyvault if necessary
  #Now that we have a SP let's give it some permissions
  az role assignment create --role Owner --scope $RG_ID --assignee $SP_APPID -o json
done
az role assignment create --role Owner --scope $MGMT_ID --assignee $SP_APPID -o json

# echo "SP_APPID=$SP_APPID"
# echo "SP_PASSWORD=$SP_PASSWORD"
# echo "SP_TENANTID=$SP_TENANTID"
# echo "SUBSCRIPTION_ID=$SUBSCRIPTION_ID"

# Add SP info and access key to keyvault
az keyvault secret set --vault-name $KEYVAULT_NAME --name "SA-ACCESS-KEY" --value "$ACCOUNT_KEY"
az keyvault secret set --vault-name $KEYVAULT_NAME --name "SP-CLIENTID" --value "$SP_APPID"
az keyvault secret set --vault-name $KEYVAULT_NAME --name "SP-SUBSCRIPTIONID" --value "$SUBSCRIPTION_ID" 
az keyvault secret set --vault-name $KEYVAULT_NAME --name "SP-TENANTID" --value "$SP_TENANTID" 
az keyvault secret set --vault-name $KEYVAULT_NAME --name "SP-PASSWORD" --value "$SP_PASSWORD" 

# Allow SP to manage Keyvault
az keyvault set-policy --name $KEYVAULT_NAME --object-id $SP_OBJID \
  --certificate-permissions backup create delete deleteissuers get getissuers import list listissuers managecontacts manageissuers purge recover restore setissuers update \
  --key-permissions backup create decrypt delete encrypt get import list purge recover restore sign unwrapKey update verify wrapKey \
  --secret-permissions backup delete get list purge recover restore set \
  --storage-permissions backup delete deletesas get getsas list listsas purge recover regeneratekey restore set setsas update


devOpsLogin() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    echo $DEVOPS | az devops login --organization $DEVOPS_ORG
    #Setup service connection in project
    echo "Setting up SP in ADO Project"
    export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY="$SP_PASSWORD"
  else  
    echo "ERROR: Shouldn't be here.  Took a wrong turn somewhere"
    exit 1
  fi
}

getExistingProject() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    DEVOPS_PROJECT_ID=$(az devops project show -p $DEVOPS_PROJECT --query 'id' -o tsv)
  fi
}

createDevOpsProject() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    DEVOPS_PROJECT_ID=$(az devops project create --name $DEVOPS_PROJECT --org $DEVOPS_ORG --query "id" -o tsv)
    mkdir -p $DEVOPS_PROJECT; cd $DEVOPS_PROJECT
  fi
  echo "DEVOPS_PROJECT_ID=$DEVOPS_PROEJCT_ID"
}

createADFRepo() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    DEVOPS_ADFREPO_ID=$(az repos create --name adf-config --project $DEVOPS_PROJECT --org $DEVOPS_ORG --query "id" -o tsv)
  fi
  echo "DEVOPS_ADFREPO_ID=$DEVOPS_PROEJCT_ID"
}

getRepoURL() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    REPO=$(az repos show -r $DEVOPS_PROJECT --project $DEVOPS_PROJECT --query webUrl -o tsv)
  fi
  echo "REPO=$REPO"
}

getADFRepoURL() {
  if [ "$DEVOPS_TARGET" == "ADO" ]; then
    ADFREPO=$(az repos show -r adf-config --project $DEVOPS_PROJECT --query webUrl -o tsv)
  fi
  echo "ADFREPO=$ADFREPO"
}

addTokenToURL() {
  if [ -z $REPO ]; then
    echo "ERROR:  Repo is empty"
    exit 1
  fi
  if [ -z $DEVOPS ]; then
    echo "ERROR:  Token not found"
    exit 1
  fi
  GIT_URL=$(sed -e "s^//^//$DEVOPS@^" <<<$REPO)
}

##############################################
# Create ADO project, repo and pipelines
##############################################
if ! [ -z $DEVOPS ]; then
  # Call function to Login to correct platform
  devOpsLogin

  # See if project already exists and don't stop if there is an error
  set +e 
  getExistingProject

  # Create if it doesn't exist
  if [ -z $DEVOPS_PROJECT_ID ]; then
    echo "DEVOPS Project does not exist.  Continuing and will create it".
    createDevOpsProject  
    createADFRepo
  fi
  set -e
fi

######################################################
# This section creates generic ADO pipeline components
# Get generic pipeline file done
######################################################
#
# Loop over each branch to create a pipeline file that listens
# for changes on that branch only
#
for ((i=0; i < ${#GIT_BRANCH[@]}; ++i )); do
#for BRANCH in ${GIT_BRANCH[@]}; do
gets ADO_PIPE <<'EOS'
trigger:
  branches:
    include:
    - ${GIT_BRANCH[$i]}
pool:
  vmImage: 'ubuntu-latest'
parameters:
- name: DESTROY
  displayName: 'Destroy infrastructure instead of create?'
  type: boolean
  default: false
extends:
  template: azure-pipelines.tmpl
  parameters:
    DESTROY: \${{parameters.DESTROY}}
EOS
  printf '%s\n' "$ADO_PIPE" > azure-pipelines-${GIT_BRANCH[$i]}.yml
done

#
# Get generic pipeline part that is the same for all branches
#
gets GENERIC_PIPE_TMPL <<'EOS'
parameters:
- name: DESTROY
  displayName: 'Destroy infrastructure instead of create?'
  type: boolean
  default: false
steps:
#KEY VAULT TASK
- task: AzureKeyVault@1
  inputs:
    azureSubscription: 'AZURE-SP'
    KeyVaultName: '${KEYVAULT_NAME}'
    SecretsFilter: 'SP-CLIENTID,SP-SUBSCRIPTIONID,SP-TENANTID,SP-PASSWORD'
  displayName: 'Get key vault secrets as pipeline variables'

# AZ LOGIN
- script: |
    az login --service-principal -u "\$\(SP-CLIENTID\)" -p "\$\(SP-PASSWORD\)" --tenant "\$\(SP-TENANTID\)"
  displayName: 'Login the az cli'
EOS

# Generic pipeline that is created for either Bicep or Terraform
printf '%s\n' "$GENERIC_PIPE_TMPL" > azure-pipelines.tmpl

######################################################
# This section creates Terraform files
# Terraform only stuff.  Reusable in ADO and GitHUB
######################################################
if [ $TERRAFORM == "true" ]; then
  # Get the latest release of azurerm provider
  AZURE_RM_LATEST=$(curl --silent "https://api.github.com/repositories/93446042/releases/latest" | 
    grep '"tag_name":' | 
    sed -E 's/.*"([^"]+)".*/\1/' | 
    sed -E 's/^v/~>/'
  )
  if [ -z $AZURE_RM_LATEST ]; then
    AZURE_RM_LATEST="2.50.0"
  fi

gets TERRA_PROVIDER <<'EOS'
terraform {
  required_providers {
    azurerm = {
      source  = \"hashicorp/azurerm\"
      version = \"$AZURE_RM_LATEST\"
    }
  }
  backend "azurerm" {
    storage_account_name  = \"$STORAGE_ACCT_NAME\"
    container_name        = \"$CONTAINER_NAME\"
    key                   = \"terraform.state.main\"
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}
EOS

gets TERRA_TFVARS <<'EOS'
  # Added by bootstrap program
  prefix          = \"$PREFIX\"
EOS

gets TERRA_STARTER <<'EOS'
variable location {
  type        = string
  default     = \"eastus\"
}

variable prefix {
  type        = string
}

variable resource_group {
  type        = string
}

variable environment {
  type        = string
}

data \"azurerm_client_config\" \"current\" {} 
data \"azurerm_resource_group\" \"project-rg\" {
  name = var.resource_group 
}

locals { 
  # All variables used in this file should be 
  # added as locals here 
  resource_group          = data.azurerm_resource_group.project-rg.name
  prefix                  = lower(var.prefix)
  environment             = lower(var.environment)
  prefix_minus            = replace(local.prefix, \"-\", \"\")
  location                = var.location 
  common_tags = { 
    created_by = \"Terraform\" 
  }
}
EOS

####################################################
# ADO Pipeline for Terraform.
####################################################
gets TERRA_PIPE_TMPL <<'EOS'
#KEY VAULT TASK BECAUSE SA Account KEY is needed by TF
- task: AzureKeyVault@1
  inputs:
    azureSubscription: 'AZURE-SP'
    KeyVaultName: '${KEYVAULT_NAME}'
    SecretsFilter: 'SA-ACCESS-KEY'
  displayName: 'Get SA-ACCESS-KEY as pipeline variables'
- script: |
    # Run Terraform
    set -x
    export ARM_CLIENT_ID=\$(SP-CLIENTID)
    export ARM_CLIENT_SECRET=\$(SP-PASSWORD)
    export ARM_SUBSCRIPTION_ID=\$(SP-SUBSCRIPTIONID)
    export ARM_TENANT_ID=\$(SP-TENANTID)
    export ARM_ACCESS_KEY=\$(SA-ACCESS-KEY)
    export TERRA_WORKSPACE=\$(ENVIRONMENT)
    echo '#######Terraform Init########'
    terraform init
    terraform workspace select \$TERRA_WORKSPACE || terraform workspace new \$TERRA_WORKSPACE
    echo '#######Terraform Plan########'
    terraform plan -out="out.plan" -var-file=terraform.tfvars -var=\"resource_group=\$(RESOURCE_GROUP)\" -var=\"environment=\$(ENVIRONMENT)\"
    echo '#######Terraform Apply########'
    terraform apply out.plan
  displayName: 'Terraform Init, Plan and Apply '
  condition: eq(\${{ parameters.DESTROY }}, false)

- script: |
    # Destroy with Terraform
    set -x
    export ARM_CLIENT_ID=\$(SP-CLIENTID)
    export ARM_CLIENT_SECRET=\$(SP-PASSWORD)
    export ARM_SUBSCRIPTION_ID=\$(SP-SUBSCRIPTIONID)
    export ARM_TENANT_ID=\$(SP-TENANTID)
    export ARM_ACCESS_KEY=\$(SA-ACCESS-KEY)
    export TERRA_WORKSPACE=\$(ENVIRONMENT)
    echo '#######Terraform Init########'
    terraform init
    terraform workspace select \$TERRA_WORKSPACE || terraform workspace new \$TERRA_WORKSPACE
    terraform destroy --auto-approve -var-file=terraform.tfvars -var=\"resource_group=\$(RESOURCE_GROUP)\" -var=\"environment=\$(ENVIRONMENT)\"
  displayName: 'Terraform Destroy '
  condition: \${{ parameters.DESTROY }}
EOS

##############################################
# CREATE project files 
#############################################
  printf '%s\n' "$TERRA_STARTER" > bootstrap.tf 
  printf '%s\n' "$TERRA_PROVIDER" > provider.tf 
  printf '%s\n' "$TERRA_TFVARS" > terraform.tfvars
  printf '%s\n' "$TERRA_PIPE_TMPL" >> azure-pipelines.tmpl
  cp -r $SCRIPT_DIR/data data
  cp -r $SCRIPT_DIR/files/main.tf.tmpl main.tf
fi


# Initialize current directory as a Git repo 
git init
for BRANCH in ${GIT_BRANCH[@]}; do
  git checkout -b $BRANCH; git add *; git commit -m 'initial commit' || true
done 

# Get Repo URL
getRepoURL

# Let's add the DEVOPS token to the url for pushing
# This will setup the GIT_URL variable
addTokenToURL
echo "GIT_URL=$GIT_URL"
if [ -z $GIT_URL ]; then
  echo "ERROR: Failed to create a valid GIT_URL"
  exit 1
fi

git remote add origin $REPO || true
git push $GIT_URL --all
# This is all the files we are putting in the main repo

# Add repo for adf-config
# Back out of terraform directory
cd ..
# Create a new directory for adf-config
mkdir ${LPREFIX}-adf-config; cd ${LPREFIX}-adf-config

echo $REGION

# Copy pipeline file to adf-config and replace values before committing
PROD_ADF_RG=${UPREFIX}-${PROD_ENV}-RG \
  PROD_ADF=${LPREFIX}-${PROD_ENV}-ADF \
  PROD_ADF_KV_ADDRESS="https://${LPREFIX}-${PROD_ENV}-kv.vault.azure.net/" \
  ADF_LOCATION="$REGION" \
  envsubst '$PROD_ADF_RG $PROD_ADF $PROD_ADF_KV_ADDRESS $ADF_LOCATION' < $SCRIPT_DIR/files/azure-adf-pipelines.yml > azure-pipelines.yml
git init
git checkout -b adf_publish; git add *; git commit -m 'initial commit' || true
getADFRepoURL
REPO=$ADFREPO
addTokenToURL
echo "GIT_URL=$GIT_URL"
if [ -z $GIT_URL ]; then
  echo "ERROR: Failed to create a valid GIT_URL"
  exit 1
fi

git remote add origin $REPO || true
git push $GIT_URL --all

  
if [ "$DEVOPS_TARGET" == "ADO" ]; then
  # Put a policy on ADO repos committing to main
  # Not currently available in GitHub free repos
  if [ ${#GIT_BRANCH[@]} -gt 1 ]; then
    REPO_ID=$(az repos show -r $DEVOPS_PROJECT --project $DEVOPS_PROJECT --query id -o tsv)
    az repos policy merge-strategy create \
      --blocking true \
      --branch main \
      --enabled true \
      --repository-id $REPO_ID \
      --allow-no-fast-forward true \
      --org $DEVOPS_ORG \
      --project $DEVOPS_PROJECT 
  fi
  # Get the existing SE in the ADO project named azure-sp if it exists otherwise create it
  SE_ID=$(az devops service-endpoint list -p $DEVOPS_PROJECT --query "[?name=='azure-sp'].id" -o tsv)
  if [ -z $SE_ID ]; then
    SE_ID=$(az devops service-endpoint azurerm create \
      --name azure-sp \
      --azure-rm-tenant-id $SP_TENANTID  \
      --azure-rm-subscription-id $SUBSCRIPTION_ID \
      --azure-rm-subscription-name internal \
      --azure-rm-service-principal-id $SP_APPID \
      --project $DEVOPS_PROJECT --query "id" -o tsv)
  fi
  echo "SE_ID=$SE_ID"

  sleep 15  

  # Allow pipelines to use this SP
  az devops service-endpoint update \
    --project $DEVOPS_PROJECT \
    --id $SE_ID \
    --enable-for-all true

  # Let Azure work everything out related to the service connection
  sleep 15

  for ((i=0; i < ${#ENV_NAME[@]}; ++i )); do
    # Create and run the pipeline in ADO
    az pipelines create \
      --name "Terraform-Build-${GIT_BRANCH[$i]}" \
      --description "Infra Build for ${ENV_NAME[$i]}" \
      --yml-path azure-pipelines-${GIT_BRANCH[$i]}.yml \
      --branch ${GIT_BRANCH[$i]} \
      --project $DEVOPS_PROJECT \
      --repository $DEVOPS_PROJECT \
      --repository-type tfsgit \
      --skip-first-run \
      --org $DEVOPS_ORG

    sleep 5

    az pipelines variable create \
      --name RESOURCE_GROUP \
      --value ${RESOURCE_GROUP[$i]} \
      --project $DEVOPS_PROJECT \
      --org $DEVOPS_ORG \
      --pipeline-name Terraform-Build-${GIT_BRANCH[$i]} \
      --allow-override false
    
    sleep 5

    az pipelines variable create \
      --name ENVIRONMENT \
      --value ${ENV_SHORT[$i]} \
      --project $DEVOPS_PROJECT \
      --org $DEVOPS_ORG \
      --pipeline-name Terraform-Build-${GIT_BRANCH[$i]} \
      --allow-override false

    sleep 5 

    az pipelines variable create \
      --name REGION \
      --value $REGION \
      --project $DEVOPS_PROJECT \
      --org $DEVOPS_ORG \
      --pipeline-name Terraform-Build-${GIT_BRANCH[$i]} \
      --allow-override false
    
    sleep 5 

    az pipelines variable create \
      --name PREFIX \
      --value $PREFIX \
      --project $DEVOPS_PROJECT \
      --org $DEVOPS_ORG \
      --pipeline-name Terraform-Build-${GIT_BRANCH[$i]} \
      --allow-override false

    sleep 5

    az pipelines run \
      --name Terraform-Build-${GIT_BRANCH[$i]} \
      --org $DEVOPS_ORG \
      --project $DEVOPS_PROJECT 
  done

  # Now setup the adf-config pipeline
  az pipelines create \
    --name "adf-config" \
    --description "ADF Factory Pipeline" \
    --yml-path azure-pipelines.yml \
    --branch adf_publish \
    --project $DEVOPS_PROJECT \
    --repository adf-config \
    --repository-type tfsgit \
    --skip-first-run \
    --org $DEVOPS_ORG
else
  echo "ERROR: Something amiss" 
  exit 1
fi

echo "The following environment(s) have been created:"
echo "${ENV_NAME[@]}"
echo "and are represented by the following RGs:"
echo "${RESOURCE_GROUP[@]}"
echo ""
echo $SP_INFO
echo "THE END"
