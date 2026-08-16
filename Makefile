# ---------------------------------------------------------------------------
# Makefile — point d'entrée unique du cycle de vie de l'infrastructure.
#
# Sous Windows sans GNU make, utiliser le wrapper équivalent :
#   .\make.ps1 <target>
# ---------------------------------------------------------------------------

INFRA_DIR  := infra
APP_DIR    := app
TF         := terraform -chdir=$(INFRA_DIR)
PLAN_FILE  := tfplan

# Le shell des recettes : bash si disponible (Git Bash sous Windows).
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help
.PHONY: help init fmt fmt-check validate plan apply destroy docs check clean cost publish-app deploy-app

## help : liste les targets disponibles
help:
	@echo ""
	@echo "  Cibles disponibles :"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /    /'
	@echo ""

## init : initialise le backend S3 et télécharge les providers
init:
	@test -f $(INFRA_DIR)/backend.hcl || { \
	  echo "infra/backend.hcl absent. Créer le fichier : cp infra/backend.hcl.example infra/backend.hcl"; exit 1; }
	$(TF) init -input=false -backend-config=backend.hcl

## fmt : reformate tous les fichiers .tf
fmt:
	$(TF) fmt -recursive

## fmt-check : échoue si un fichier n'est pas formaté (utilisé en CI)
fmt-check:
	$(TF) fmt -check -diff -recursive

## validate : vérifie la syntaxe et la cohérence de la configuration
validate:
	$(TF) validate

## plan : calcule le diff et l'enregistre dans infra/tfplan
plan:
	$(TF) plan -input=false -out=$(PLAN_FILE)

## apply : applique le plan enregistré (lancer `make plan` avant)
apply:
	@test -f $(INFRA_DIR)/$(PLAN_FILE) || { echo "Aucun plan trouvé. Lance d'abord : make plan"; exit 1; }
	$(TF) apply -input=false $(PLAN_FILE)
	@rm -f $(INFRA_DIR)/$(PLAN_FILE)

## destroy : détruit TOUTE la stack (demande confirmation)
destroy:
	@echo "Cette commande détruit l'intégralité de la stack du compte AWS courant."
	@read -p "Taper 'destroy' pour confirmer : " answer; \
	  test "$$answer" = "destroy" || { echo "Annulé."; exit 1; }
	$(TF) destroy -input=false

## docs : régénère les README des modules avec terraform-docs
docs:
	@command -v terraform-docs >/dev/null 2>&1 || { \
	  echo "terraform-docs absent. Installation : https://terraform-docs.io/user-guide/installation/"; exit 1; }
	terraform-docs markdown table --output-file README.md --output-mode inject $(INFRA_DIR)
	@for d in $(INFRA_DIR)/modules/*/; do \
	  [ -f "$$d/main.tf" ] || continue; \
	  terraform-docs markdown table --output-file README.md --output-mode inject "$$d"; \
	done

## check : enchaîne fmt-check, validate et plan — le contrôle avant commit
check: fmt-check validate plan

## cost : estime le coût mensuel via infracost (optionnel)
cost:
	@command -v infracost >/dev/null 2>&1 || { \
	  echo "infracost absent. Installation : https://www.infracost.io/docs/"; exit 1; }
	infracost breakdown --path $(INFRA_DIR)

## clean : supprime les artefacts locaux (state distant non touché)
clean:
	@rm -rf $(INFRA_DIR)/.terraform $(INFRA_DIR)/$(PLAN_FILE)
	@echo "Artefacts locaux supprimés. Relancer 'make init' avant tout plan."

## publish-app : dotnet publish + upload vers le bucket S3 d'artefacts
publish-app:
	@BUCKET=$$($(TF) output -raw artifact_bucket_name); \
	  REGION=$$($(TF) output -raw region); \
	  rm -rf $(APP_DIR)/publish $(APP_DIR)/release.zip; \
	  dotnet publish $(APP_DIR) -c Release -o $(APP_DIR)/publish --self-contained false; \
	  cd $(APP_DIR)/publish && zip -r -q ../release.zip . && cd ../..; \
	  aws s3 cp $(APP_DIR)/release.zip "s3://$$BUCKET/releases/latest.zip" --region "$$REGION"; \
	  rm -rf $(APP_DIR)/publish $(APP_DIR)/release.zip; \
	  echo "Publié : s3://$$BUCKET/releases/latest.zip"

## deploy-app : publish-app puis remplace les instances de l'ASG (instance refresh)
deploy-app: publish-app
	@ASG=$$($(TF) output -raw asg_name); \
	  REGION=$$($(TF) output -raw region); \
	  echo "Déclenchement d'un instance refresh sur $$ASG..."; \
	  echo "ATTENTION : avec asg_min_size=1 (profil économique), l'instance"; \
	  echo "unique est remplacée l'une après l'autre -> coupure de service"; \
	  echo "de quelques dizaines de secondes pendant le remplacement."; \
	  aws autoscaling start-instance-refresh --auto-scaling-group-name "$$ASG" \
	    --region "$$REGION" \
	    --preferences '{"MinHealthyPercentage":0,"InstanceWarmup":180}'; \
	  echo "Suivre la progression : aws autoscaling describe-instance-refreshes --auto-scaling-group-name $$ASG --region $$REGION"
