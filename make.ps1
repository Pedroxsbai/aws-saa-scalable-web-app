<#
.SYNOPSIS
    Équivalent PowerShell du Makefile, pour un poste Windows sans GNU make.

.DESCRIPTION
    Expose exactement les mêmes cibles que le Makefile. Le Makefile reste la
    référence (c'est lui qu'utilise la CI GitHub Actions sous Linux) ; ce
    script sert au développement local sous Windows.

.EXAMPLE
    .\make.ps1 init
    .\make.ps1 plan
    .\make.ps1 check
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'init', 'fmt', 'fmt-check', 'validate', 'plan',
        'apply', 'destroy', 'docs', 'check', 'cost', 'clean',
        'publish-app', 'deploy-app')]
    [string]$Target = 'help'
)

$ErrorActionPreference = 'Stop'

$InfraDir = Join-Path $PSScriptRoot 'infra'
$AppDir   = Join-Path $PSScriptRoot 'app'
$PlanFile = 'tfplan'
$PlanPath = Join-Path $InfraDir $PlanFile

function Get-TerraformOutput {
    param([string]$Name)
    $value = & terraform "-chdir=$InfraDir" output -raw $Name
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de lire l'output Terraform '$Name'. La stack est-elle appliquee ?"
    }
    return $value
}

function Invoke-Terraform {
    param([string[]]$Arguments)

    Write-Host "terraform -chdir=infra $($Arguments -join ' ')" -ForegroundColor DarkGray
    & terraform "-chdir=$InfraDir" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "terraform a retourné le code $LASTEXITCODE"
    }
}

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not (Test-Command 'terraform')) {
    throw "terraform introuvable dans le PATH. Installation : winget install HashiCorp.Terraform"
}

switch ($Target) {

    'help' {
        Write-Host ''
        Write-Host '  Cibles disponibles :' -ForegroundColor Cyan
        Write-Host ''
        @(
            'init       initialise le backend S3 et telecharge les providers'
            'fmt        reformate tous les fichiers .tf'
            'fmt-check  echoue si un fichier n''est pas formate (CI)'
            'validate   verifie la syntaxe et la coherence'
            'plan       calcule le diff et l''enregistre dans infra/tfplan'
            'apply      applique le plan enregistre'
            'destroy    detruit TOUTE la stack (confirmation demandee)'
            'docs       regenere les README des modules via terraform-docs'
            'check       fmt-check + validate + plan'
            'cost        estimation mensuelle via infracost'
            'clean       supprime les artefacts locaux'
            'publish-app dotnet publish + upload vers le bucket S3 d''artefacts'
            'deploy-app  publish-app puis remplace les instances de l''ASG'
        ) | ForEach-Object { Write-Host "    $_" }
        Write-Host ''
    }

    'init' {
        if (-not (Test-Path (Join-Path $InfraDir 'backend.hcl'))) {
            throw 'infra\backend.hcl absent. Creer le fichier : copy infra\backend.hcl.example infra\backend.hcl'
        }
        Invoke-Terraform @('init', '-input=false', '-backend-config=backend.hcl')
    }

    'fmt' { Invoke-Terraform @('fmt', '-recursive') }

    'fmt-check' { Invoke-Terraform @('fmt', '-check', '-diff', '-recursive') }

    'validate' { Invoke-Terraform @('validate') }

    'plan' { Invoke-Terraform @('plan', '-input=false', "-out=$PlanFile") }

    'apply' {
        if (-not (Test-Path $PlanPath)) {
            throw "Aucun plan trouve. Lance d'abord : .\make.ps1 plan"
        }
        Invoke-Terraform @('apply', '-input=false', $PlanFile)
        Remove-Item $PlanPath -Force -ErrorAction SilentlyContinue
    }

    'destroy' {
        Write-Host "Cette commande detruit l'integralite de la stack du compte AWS courant." -ForegroundColor Yellow
        $answer = Read-Host "Taper 'destroy' pour confirmer"
        if ($answer -ne 'destroy') {
            Write-Host 'Annule.'
            return
        }
        Invoke-Terraform @('destroy', '-input=false')
    }

    'docs' {
        if (-not (Test-Command 'terraform-docs')) {
            throw 'terraform-docs absent. Installation : winget install terraform-docs.terraform-docs'
        }
        & terraform-docs markdown table --output-file README.md --output-mode inject $InfraDir
        Get-ChildItem (Join-Path $InfraDir 'modules') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'main.tf') } |
        ForEach-Object {
            & terraform-docs markdown table --output-file README.md --output-mode inject $_.FullName
        }
    }

    'check' {
        Invoke-Terraform @('fmt', '-check', '-diff', '-recursive')
        Invoke-Terraform @('validate')
        Invoke-Terraform @('plan', '-input=false', "-out=$PlanFile")
    }

    'cost' {
        if (-not (Test-Command 'infracost')) {
            throw 'infracost absent. Installation : https://www.infracost.io/docs/'
        }
        & infracost breakdown --path $InfraDir
    }

    'clean' {
        Remove-Item (Join-Path $InfraDir '.terraform') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $PlanPath -Force -ErrorAction SilentlyContinue
        Write-Host "Artefacts locaux supprimes. Relancer '.\make.ps1 init' avant tout plan."
    }

    'publish-app' {
        $bucket = Get-TerraformOutput 'artifact_bucket_name'
        $region = Get-TerraformOutput 'region'

        $publishDir = Join-Path $AppDir 'publish'
        $zipPath = Join-Path $AppDir 'release.zip'
        Remove-Item $publishDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        & dotnet publish $AppDir -c Release -o $publishDir --self-contained false
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish a echoue" }

        Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath

        & aws s3 cp $zipPath "s3://$bucket/releases/latest.zip" --region $region
        if ($LASTEXITCODE -ne 0) { throw "upload S3 echoue" }

        Remove-Item $publishDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        Write-Host "Publie : s3://$bucket/releases/latest.zip" -ForegroundColor Green
    }

    'deploy-app' {
        & $PSCommandPath publish-app
        if ($LASTEXITCODE -ne 0) { throw "publish-app a echoue" }

        $asgName = Get-TerraformOutput 'asg_name'
        $region = Get-TerraformOutput 'region'

        Write-Host "Declenchement d'un instance refresh sur $asgName..." -ForegroundColor Cyan
        Write-Host "ATTENTION : avec asg_min_size=1 (profil economique), l'instance" -ForegroundColor Yellow
        Write-Host "unique est remplacee -> coupure de service de quelques dizaines" -ForegroundColor Yellow
        Write-Host "de secondes pendant le remplacement." -ForegroundColor Yellow

        & aws autoscaling start-instance-refresh --auto-scaling-group-name $asgName `
            --region $region `
            --preferences '{"MinHealthyPercentage":0,"InstanceWarmup":180}'
        if ($LASTEXITCODE -ne 0) { throw "start-instance-refresh a echoue" }

        Write-Host "Suivre la progression : aws autoscaling describe-instance-refreshes --auto-scaling-group-name $asgName --region $region"
    }
}
