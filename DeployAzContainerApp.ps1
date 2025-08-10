# ================================
# PARAMETERS
# ================================
param(
    [bool]$DeleteResourceGroup = $false,
    [bool]$RebuildImage = $true,
    [string]$ConfigFile = "./DeployAzContainerAppConfig.json",
    [string]$DockerfilePath = "./Dockerfile",
    [string]$ProjectPath = "."
)

# ================================
# CONFIGURATION
# ================================

# Deserialize config from JSON file
if (-not (Test-Path $ConfigFile)) {
    throw "Config file '$ConfigFile' not found."
}
$config = Get-Content $ConfigFile | ConvertFrom-Json

$location = $config.location
$resourceGroup = $config.resourceGroup
$containerAppEnv = $config.containerAppEnv
$containerAppName = $config.containerAppName
$containerImage = $config.containerImage
$containerImageWithoutTag = $config.containerImageWithoutTag

# Optional: Enable logging to a file
$logFile = ".\deploy-log.txt"
$EnableLogFile = $false

# ================================
# LOGGING FUNCTIONS
# ================================
function Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Information "$timestamp [INFO] $Message" -InformationAction Continue
    if ($EnableLogFile) { Add-Content -Path $logFile -Value "$timestamp [INFO] $Message" }
}

function Warn {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Warning "$timestamp [WARN] $Message"
    if ($EnableLogFile) { Add-Content -Path $logFile -Value "$timestamp [WARN] $Message" }
}

function ErrorLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Error "$timestamp [ERROR] $Message"
    if ($EnableLogFile) { Add-Content -Path $logFile -Value "$timestamp [ERROR] $Message" }
}

# ================================
# DEPLOYMENT STEPS
# ================================

if ($RebuildImage)
{
    docker build -f $DockerfilePath -t $containerImageWithoutTag $ProjectPath
    docker push $containerImage
}

# Resource Group
if ($DeleteResourceGroup) {
    Log "Deleting resource group '$resourceGroup'..."
    az group delete --name $resourceGroup --yes | Out-Null
    Log "Resource group '$resourceGroup' deleted."
}

Log "Checking resource group '$resourceGroup'..."
if (-not (az group exists --name $resourceGroup | ConvertFrom-Json)) {
    Log "Creating resource group..."
    az group create --name $resourceGroup --location $location | Out-Null
} else {
    Log "Resource group already exists."
}

# Ensure required providers are registered
Log "✅ Ensuring OperationalInsights is registered..."
az provider register --namespace Microsoft.OperationalInsights --wait

# Container App Environment
Log "Checking Container App environment '$containerAppEnv'..."
if (-not (az containerapp env show --name $containerAppEnv --resource-group $resourceGroup 2>$null)) {
    Log "Creating Container App environment..."
    az containerapp env create `
        --name $containerAppEnv `
        --resource-group $resourceGroup `
        --location $location | Out-Null
} else {
    Log "Environment already exists."
}

Log "Checking Container App '$containerAppName'..."
if (-not (az containerapp show --name $containerAppName --resource-group $resourceGroup 2>$null)) {
    Log "Creating Container App..."

    # Prompt user for Docker Hub credentials
    $DockerHubUsername = Read-Host "Docker Hub Username"
    $DockerHubPassword = Read-Host "Docker Hub Password" -AsSecureString
    $DockerHubPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($DockerHubPassword)
    )

    az containerapp create `
        --name $containerAppName `
        --resource-group $resourceGroup `
        --environment $containerAppEnv `
        --image $containerImage `
        --target-port 8080 `
        --ingress external `
        --registry-server docker.io `
        --registry-username $DockerHubUsername `
        --registry-password $DockerHubPasswordPlain `
        --cpu 0.5 --memory 1.0Gi | Out-Null
    Log "Container App created."

    Log "Setting up Container App registry credentials..."
    az containerapp registry set `
        -n $containerAppName `
        -g $resourceGroup `
        --server docker.io `
        --username $DockerHubUsername `
        --password $DockerHubPasswordPlain | Out-Null
    Log "Container App registry credentials set."

} else {
    Log "Container App already exists. Updating with new image..."
    az containerapp update `
        --name $containerAppName `
        --resource-group $resourceGroup `
        --image $containerImage | Out-Null
    Log "Container App updated."
}

Log "✅ Deployment completed."