# ---------------------------------------------------------------------------
# Backend distant — state Terraform dans S3, verrou dans DynamoDB.
#
# Le bloc est volontairement VIDE : les valeurs (nom de bucket, région, table)
# sont fournies à l'initialisation pour ne pas publier l'ID du compte AWS dans
# un dépôt public.
#
#   terraform init -backend-config=backend.hcl
#
# ou, via le Makefile qui passe déjà l'option :
#
#   make init          # .\make.ps1 init sous Windows
#
# Partir de backend.hcl.example pour créer son backend.hcl local — ce dernier
# est ignoré par git.
#
# PRÉREQUIS : le bucket et la table DynamoDB doivent exister AVANT le premier
# `terraform init`. Ils ne sont volontairement PAS gérés par ce code (problème
# de l'œuf et de la poule : le state ne peut pas se stocker dans une ressource
# qu'il décrit lui-même). Ils survivent donc à `terraform destroy`, ce qui est
# le comportement voulu.
#
# Création manuelle, une seule fois — cf. README section « Prérequis » :
#
#   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
#
#   aws s3api create-bucket \
#     --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
#     --region eu-west-3 \
#     --create-bucket-configuration LocationConstraint=eu-west-3
#
#   aws s3api put-bucket-versioning \
#     --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
#     --versioning-configuration Status=Enabled
#
#   aws s3api put-bucket-encryption \
#     --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
#     --server-side-encryption-configuration \
#       '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#
#   aws s3api put-public-access-block \
#     --bucket "tfstate-aws-saa-manara-${ACCOUNT_ID}" \
#     --public-access-block-configuration \
#       "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
#
#   aws dynamodb create-table \
#     --table-name tf-lock-aws-saa-manara \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region eu-west-3
#
# Le nom d'un bucket S3 est unique à l'échelle mondiale, d'où le suffixe par
# ID de compte. Coût du backend : quelques centimes par mois.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {}
}
