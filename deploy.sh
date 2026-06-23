#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — ProServ RSM
#
# Déploie tous les composants ProServ sur une org Salesforce cible.
#
# Ce que le script déploie :
#   - Objets custom (RegieBillingPlan__c, RSM_PaieBillingPlan__c, RSM_RankCost__c)
#   - Champ custom Order.RSM_BillingModel__c
#   - 52 composants LWC
#   - Classes Apex
#   - FlexiPages (Cockpit_Facturation_Global, Usage_Order_Record_Page, RLM_Home_Page_Default)
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
echo "  ProServ RSM — Déploiement"
echo "  Org cible : $TARGET_ORG"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Répertoire du script ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 — Objets et champs custom
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 1/4 — Objets et champs custom..."
echo "──────────────────────────────────────────────────────────"

sf project deploy start \
    --metadata "CustomObject:RegieBillingPlan__c" \
    --metadata "CustomObject:RSM_PaieBillingPlan__c" \
    --metadata "CustomObject:RSM_RankCost__c" \
    --metadata "CustomField:Order.RSM_BillingModel__c" \
    --target-org "$TARGET_ORG"

echo "  ✅ Objets et champs déployés."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 — Code Apex et ressources
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 2/4 — Classes Apex et Static Resources..."
echo "──────────────────────────────────────────────────────────"

sf project deploy start \
    --metadata "ApexClass:RegieBillingController" \
    --metadata "ApexClass:RegieBillingControllerTest" \
    --metadata "ApexClass:MilestoneBillingController" \
    --metadata "ApexClass:MilestoneBillingControllerTest" \
    --metadata "ApexClass:PaieBillingController" \
    --metadata "ApexClass:GlobalBillingController" \
    --metadata "ApexClass:GlobalBillingControllerTest" \
    --metadata "ApexClass:AffaireControlTowerController" \
    --metadata "StaticResource:rsmCockpitStyles" \
    --target-org "$TARGET_ORG"

echo "  ✅ Apex et ressources déployés."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 — Composants LWC, Flow et Quick Action
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 3/4 — LWC, Flow et Quick Action..."
echo "──────────────────────────────────────────────────────────"

sf project deploy start \
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
    --metadata "QuickAction:Order.Import_Silae" \
    --target-org "$TARGET_ORG"

echo "  ✅ LWC, Flow et Quick Action déployés."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 — Lightning Pages
# ══════════════════════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────────────────────"
echo "  Étape 4/4 — Lightning Pages..."
echo "──────────────────────────────────────────────────────────"

sf project deploy start \
    --metadata "FlexiPage:Cockpit_Facturation_Global" \
    --metadata "FlexiPage:Usage_Order_Record_Page" \
    --target-org "$TARGET_ORG"

echo "  ✅ Lightning Pages déployées."
echo ""

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
