#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — ProServ RSM
#
# Valide puis déploie tous les composants ProServ sur une org Salesforce cible.
# La validation est TOUJOURS exécutée avant le déploiement réel.
# Si la validation échoue, le déploiement est annulé.
#
# Ce que le script déploie :
#   - Objets custom (RegieBillingPlan__c, RSM_PaieBillingPlan__c, RSM_RankCost__c)
#   - Champ custom Order.RSM_BillingModel__c
#   - 52 composants LWC
#   - Classes Apex
#   - FlexiPages (Cockpit_Facturation_Global, Usage_Order_Record_Page)
#   - Quick Action Order.Import_Silae
#   - Flow RSM_Import_Silae
#   - Static Resource rsmCockpitStyles
#
# Prérequis sur l'org cible :
#   - Revenue Cloud Billing activé
#   - Billing Treatment "Régie Mensuelle (Arrears)" configuré
#   - Produit "Bulletin de paie" présent dans le catalogue
#   - Billing Context RLM_BillingContext avec ses mappings
#
# Usage :
#   ./deploy.sh <org-alias-ou-username>
#
# Exemple :
#   ./deploy.sh my-sandbox
#   ./deploy.sh user@company.com
# ─────────────────────────────────────────────────────────────────────────────

set -e

# ── Vérification de l'argument ────────────────────────────────────────────────
TARGET_ORG="${1}"
if [ -z "$TARGET_ORG" ]; then
    echo ""
    echo "❌  Argument manquant."
    echo "    Usage : ./deploy.sh <org-alias-ou-username>"
    echo ""
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ProServ RSM — Validation + Déploiement"
echo "  Org cible : $TARGET_ORG"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Helper : valider puis déployer ────────────────────────────────────────────
# Prend exactement les mêmes arguments que sf project deploy start.
# Exécute d'abord une validation (--dry-run), puis le déploiement réel.
deploy_with_validation() {
    local label="$1"
    shift  # retire le label, le reste = arguments metadata

    echo "  🔍 Validation : $label..."
    if ! sf project deploy validate "$@" --target-org "$TARGET_ORG"; then
        echo ""
        echo "  ❌ Validation échouée pour : $label"
        echo "     Déploiement annulé. Corrigez les erreurs avant de relancer."
        exit 1
    fi
    echo "  ✅ Validation réussie."

    echo "  🚀 Déploiement : $label..."
    sf project deploy start "$@" --target-org "$TARGET_ORG"
    echo "  ✅ Déployé."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 — Objets et champs custom
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 1/4 — Objets et champs custom"
echo "──────────────────────────────────────────────────────────"

deploy_with_validation "Objets et champs custom" \
    --metadata "CustomObject:RegieBillingPlan__c" \
    --metadata "CustomObject:RSM_PaieBillingPlan__c" \
    --metadata "CustomObject:RSM_RankCost__c" \
    --metadata "CustomField:Order.RSM_BillingModel__c"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 — Code Apex et ressources
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 2/4 — Classes Apex et Static Resources"
echo "──────────────────────────────────────────────────────────"

deploy_with_validation "Classes Apex et Static Resources" \
    --metadata "ApexClass:RegieBillingController" \
    --metadata "ApexClass:RegieBillingControllerTest" \
    --metadata "ApexClass:MilestoneBillingController" \
    --metadata "ApexClass:MilestoneBillingControllerTest" \
    --metadata "ApexClass:PaieBillingController" \
    --metadata "ApexClass:GlobalBillingController" \
    --metadata "ApexClass:GlobalBillingControllerTest" \
    --metadata "ApexClass:AffaireControlTowerController" \
    --metadata "StaticResource:rsmCockpitStyles"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 — Composants LWC, Flow et Quick Action
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 3/4 — LWC, Flow et Quick Action"
echo "──────────────────────────────────────────────────────────"

deploy_with_validation "LWC, Flow et Quick Action" \
    --metadata "LightningComponentBundle:affaireControlTower" \
    --metadata "LightningComponentBundle:cockpitFacturationGlobal" \
    --metadata "LightningComponentBundle:milestoneBillingCockpit" \
    --metadata "LightningComponentBundle:milestoneFacturerAction" \
    --metadata "LightningComponentBundle:regieBillingCockpit" \
    --metadata "LightningComponentBundle:regieBillingStatus" \
    --metadata "LightningComponentBundle:regieFacturerAction" \
    --metadata "LightningComponentBundle:regieRefreshPublisher" \
    --metadata "LightningComponentBundle:paieBillingCockpit" \
    --metadata "LightningComponentBundle:paieBillingStatus" \
    --metadata "LightningComponentBundle:paieImportSilaeAction" \
    --metadata "Flow:RSM_Import_Silae" \
    --metadata "QuickAction:Order.Import_Silae"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 — Lightning Pages
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 4/4 — Lightning Pages"
echo "──────────────────────────────────────────────────────────"

deploy_with_validation "Lightning Pages" \
    --metadata "FlexiPage:Cockpit_Facturation_Global" \
    --metadata "FlexiPage:Usage_Order_Record_Page"

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════"
echo "  ✅ Déploiement terminé sur : $TARGET_ORG"
echo ""
echo "  ⚠️  Vérifications post-déploiement :"
echo "     1. Billing Treatment 'Régie Mensuelle (Arrears)' présent"
echo "     2. Produit 'Bulletin de paie' dans le catalogue"
echo "     3. Billing Context RLM_BillingContext configuré"
echo "     4. Assigner les Permission Sets si nécessaire"
echo "════════════════════════════════════════════════════════"
echo ""
