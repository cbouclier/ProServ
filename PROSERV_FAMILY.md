# Famille ProServ — Architecture & Processus de Facturation

Documentation complète de la solution ProServ RSM : composants, modèles de facturation et simulation Napta.

---

## Vue d'ensemble

La solution ProServ gère le cycle de vie complet d'une **mission de conseil** dans Salesforce, de la commande jusqu'à la facture. Elle s'appuie sur Revenue Cloud Billing (RLM) pour la génération des factures et sur **Napta** comme outil de staffing.

Chaque mission est un **Order** Salesforce. Deux modèles de facturation coexistent, déterminés par le champ `RSM_BillingModel__c` sur l'Order :

| Modèle | Principe | Outil de référence |
|--------|----------|--------------------|
| **Régie** | Facturation au temps passé (T&M), mois par mois | Napta (saisie des heures) |
| **Forfait** | Facturation par jalons séquentiels | Avancement du projet |

---

## Composants de la famille

### affaireControlTower
**Tour de contrôle de l'affaire.** Composant principal posé sur la page d'un Order. Agrège en temps réel toutes les données financières de la mission et calcule la rentabilité.

Affiche trois blocs :
- **Pilotage 360°** — Vendu / Réalisé / Facturé (en € et en jours) avec les écarts
- **Boni / Mali** — Indicateur visuel de rentabilité (vert = Boni, rouge = Mali, neutre = À l'équilibre)
- **FAE (Facture À Établir)** — Produit réalisé non encore facturé, materialisable en facture Draft

Fonctionne pour les deux modèles (Régie et Forfait) avec une logique adaptée à chacun.

### cockpitFacturationGlobal
**Vue globale de toutes les missions.** Tableau de bord transversal affichant l'ensemble des affaires du mois en cours avec leur statut de facturation. Inclut un indicateur **"À valider (Napta)"** qui remonte en priorité les missions dont le staffing importé depuis Napta est encore en attente de validation.

Filtres disponibles : par mois, par modèle (Régie/Forfait), et toggle pour n'afficher que les missions avec staffing Napta à valider.

### milestoneBillingCockpit
**Cockpit de facturation Forfait.** Affiche les jalons de la mission (ex : Lancement, Validation, Clôture) avec leur statut et montant. Permet de réaliser un jalon et de déclencher sa facturation. La progression est **séquentielle** : un jalon ne peut être réalisé que si le précédent est déjà facturé.

### milestoneFacturerAction
**Bouton de facturation jalon.** Quick Action posée sur l'Order pour facturer le jalon réalisé en cours. Peut aussi être intégrée dans un flow.

### regieBillingCockpit
**Cockpit de facturation Régie.** Affiche les lignes du plan de facturation régie groupées par mois (grades + frais). Permet d'éditer les jours et montants directement dans le tableau, de valider un mois, et de déclencher la génération des Billing Schedules. Se rafraîchit automatiquement après un Import Napta.

### regieBillingStatus
**Badge de statut régie.** Indicateur visuel léger du statut de facturation d'un plan régie. Généralement intégré dans le cockpit ou une page de record.

### regieFacturerAction
**Bouton de facturation régie.** Quick Action sur l'Order pour facturer tous les mois validés en une seule action.

### regieRefreshPublisher
**Synchroniseur invisible.** Publie un signal de rafraîchissement sur la page après un Import Napta, pour que le cockpit régie se recharge automatiquement sans action de l'utilisateur.

---

## Modèle Régie — Processus détaillé

### Schéma du processus

```
[1] Import Napta          [2] Édition & Validation       [3] Facturation
─────────────────         ──────────────────────────     ──────────────────
Génère les lignes    →    Vérifie / corrige          →   Crée et poste
du mois dans              jours, TJM, frais               la facture RLM
RegieBillingPlan__c       puis valide                     via ConnectApi
(statut Brouillon)        → crée les BillingSchedules
```

### Étape 1 — Import Napta

Le bouton **"Import Napta"** sur la page de l'Order lit les produits de la commande (grades et frais) et crée un enregistrement `RegieBillingPlan__c` par ligne pour le mois choisi, en statut **Brouillon**.

**En production**, Napta envoie les vraies heures saisies par les consultants.

**En démo (simulation)**, le code (`RegieBillingController.importNapta`) génère des données fictives réalistes :

| Donnée | Valeur simulée |
|--------|----------------|
| Jours réels | Entre 8 et 20 jours (pseudo-aléatoire) |
| TJM | Prix réel de la ligne produit sur l'Order |
| Consultant | Nom fictif parmi 15 personnes |
| Frais de déplacement | Entre 250€ et 1 000€ |
| Statut initial | Brouillon |

Consultants fictifs : Marie Lefèvre, Julien Moreau, Sophie Garnier, Thomas Bernard, Camille Rousseau, Lucas Petit, Emma Fontaine, Hugo Mercier, Léa Chevalier, Nathan Girard, Chloé Dumas, Maxime Robin, Inès Lambert, Antoine Faure, Manon Vidal.

> L'import est idempotent : si les lignes du mois existent déjà, elles ne sont pas recréées (contrôle par `ExternalKey__c = OrderItemId|YYYY-MM`).

### Étape 2 — Validation

Dans le **regieBillingCockpit**, le gestionnaire vérifie les lignes importées, corrige si besoin les jours ou montants, puis clique "Valider". Le code exécute deux opérations en séquence :

1. `prepareMonth()` — synchronise les OrderItems avec les valeurs validées, passe les lignes en statut **Validé**
2. `createSchedules()` — appelle l'API Revenue Cloud pour créer les **Billing Schedules** (échéanciers)

> **Note technique :** La régie facture des montants variables chaque mois (≠ abonnement fixe). Le code supprime les anciens Billing Schedules de l'Order avant d'en créer de nouveaux, puis restaure les valeurs contractuelles d'origine sur les OrderItems.

### Étape 3 — Facturation

Deux modes disponibles :

**Mois par mois** — depuis le cockpit régie, via `createAndPostInvoice`. Crée et poste la facture du mois sélectionné. Date de facturation : 1er du mois suivant (facturation en arrears).

**Ordre global** — depuis la Quick Action `regieFacturerAction`, via `invoiceOrder`. Facture tous les mois validés en une seule action.

Dans les deux cas : `ConnectApi.Billing.generateInvoices` crée et poste la facture Revenue Cloud.

---

## Modèle Forfait — Processus détaillé

### Schéma du processus

```
[Activation Order]        [Réalisation jalon]            [Facturation jalon]
──────────────────        ───────────────────            ───────────────────
RLM génère les       →    Le gestionnaire            →   Crée et poste
BillingMilestonePlan      marque le jalon                la facture RLM
Items automatiquement     comme réalisé                  (séquentiel)
```

### Règle de séquentialité

Les jalons sont **strictement séquentiels** : un jalon ne peut être réalisé que si le jalon précédent est réalisé ET facturé. En cas de tentative hors séquence, le système affiche le message : *"Réalisez et facturez d'abord « [jalon précédent] »"*.

### Réalisation d'un jalon

Le bouton "Réaliser" dans le **milestoneBillingCockpit** passe `IsMilestoneAccomplished = true` sur tous les `BillingMilestonePlanItem` du jalon, rendant l'échéance facturable (statut `ReadyForInvoicing`).

### Facturation

`MilestoneBillingController.invoiceMilestone` — crée et poste la facture de toutes les échéances `ReadyForInvoicing` de l'Order.

---

## Pilotage 360° — Affaire Control Tower

L'**affaireControlTower** calcule en temps réel les indicateurs financiers de la mission, en s'adaptant au modèle :

### Calcul du Réalisé

| Modèle | Source du réalisé | Source des jours réalisés |
|--------|-------------------|---------------------------|
| Régie | Temps valorisé (RegieBillingPlan__c × TJM) | Jours saisis dans Napta |
| Forfait | Jalons accomplis (BillingMilestonePlanItem) | Temps réel si saisi, sinon estimation au prorata |

### Calcul du Boni / Mali

Le Boni/Mali mesure l'écart entre la marge réelle à date et la marge attendue pour ce niveau de production :

```
Boni/Mali = Marge réelle - (Marge vendue × % d'avancement en valeur)
```

Un Boni signifie que le projet est plus rentable que prévu. Un Mali signifie qu'il coûte plus cher que budgété.

### FAE (Facture À Établir)

La FAE représente le produit réalisé non encore facturé : `FAE = Produit réalisé - Facturé`.

Deux états possibles :
- **FAE calculée** — affichée dans le composant, pas encore matérialisée
- **FAE Draft** — matérialisée en facture Draft Revenue Cloud via `genererFAE()` (comptabilisation possible sans poster)

---

## Objets Salesforce impliqués

| Objet | Rôle dans la solution |
|-------|-----------------------|
| `Order` | La mission / affaire ProServ |
| `OrderItem` | Les grades et frais contractuels |
| `RegieBillingPlan__c` | Les lignes mensuelles régie (source de vérité du cockpit) |
| `RSM_RankCost__c` | Le coût journalier par grade (pour le calcul de rentabilité) |
| `BillingMilestonePlanItem` | Les jalons du modèle Forfait |
| `BillingSchedule` | Les échéanciers Revenue Cloud générés à la validation |
| `Invoice` | La facture créée et postée (ou Draft pour la FAE) |

---

## Classes Apex associées

| Classe | Rôle |
|--------|------|
| `RegieBillingController` | Import Napta, édition, validation, facturation régie |
| `MilestoneBillingController` | Réalisation et facturation des jalons |
| `AffaireControlTowerController` | Calcul du pilotage 360° et du Boni/Mali |
| `GlobalBillingController` | Agrégation des missions pour le cockpit global |

---

→ Voir [COMPOSANTS_LWC.md](COMPOSANTS_LWC.md) pour la description de tous les composants du projet.
→ Voir [FACTURATION_REGIE.md](FACTURATION_REGIE.md) pour le détail technique de la facturation régie.
