# Famille ProServ — Architecture & Processus de Facturation

Documentation complète de la solution ProServ RSM : composants, modèles de facturation, simulation Napta et simulation Silae.

---

## Vue d'ensemble

La solution ProServ gère le cycle de vie complet d'une **mission de conseil** dans Salesforce, de la commande jusqu'à la facture. Elle s'appuie sur Revenue Cloud Billing (RLM) pour la génération des factures.

Chaque mission est un **Order** Salesforce. **Trois modèles de facturation** coexistent, déterminés par le champ `RSM_BillingModel__c` sur l'Order :

| Modèle | Principe | Outil de référence | Objet plan |
|--------|----------|--------------------|------------|
| **Régie** | Facturation au temps passé (T&M), mois par mois | Napta (saisie des heures) | `RegieBillingPlan__c` |
| **Forfait** | Facturation par jalons séquentiels | Avancement du projet | `BillingMilestonePlanItem` |
| **Paie** | Facturation au nombre de bulletins de salaire, mois par mois | Silae (logiciel de paie) | `RSM_PaieBillingPlan__c` |

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

### paieBillingCockpit
**Cockpit de facturation Paie.** Même architecture que le cockpit Régie, mais la facturation est basée sur un nombre de **bulletins de salaire** × prix unitaire. Intègre directement une barre d'import Silae avec sélection du mois. Permet d'éditer le nombre de bulletins en ligne, de valider et de facturer. Se rafraîchit automatiquement après un import Silae.

### paieBillingStatus
**Widget de suivi de facturation Paie.** Affiche 3 indicateurs (Total Paie, À facturer, Facturé) et un tableau mensuel récapitulatif avec le nombre de bulletins, le prix unitaire, le montant et le statut de chaque mois.

### paieImportSilaeAction
**Quick Action d'import Silae.** Bouton sur l'Order qui ouvre une fenêtre modale permettant de choisir le mois à importer. Déclenche la simulation Silae et publie un signal de rafraîchissement au cockpit Paie.

---

## Modèle Régie — Processus détaillé

### Schéma du processus

```
[Activation Order]   [1] Import Napta          [2] Édition & Validation       [3] Facturation
──────────────────   ─────────────────         ──────────────────────────     ──────────────────
RLM crée des    →    Génère les lignes    →    Vérifie / corrige          →   Crée et poste
BS Evergreen         du mois dans              jours, TJM, frais               la facture RLM
(supprimés à         RegieBillingPlan__c       puis valide                     via ConnectApi
chaque validation)   (statut Brouillon)        → supprime les BS Evergreen
                                               → recrée les BS du mois
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

> **Comportement à l'activation de la commande :** Dès qu'un Order est activé, Revenue Cloud crée automatiquement des `BillingSchedule` de type **Evergreen** (récurrents, montant fixe) à partir du Billing Treatment des OrderItems. Pour la régie, ces BS sont inutilisables tels quels car le montant varie chaque mois. Le code les **supprime intégralement** à chaque validation mensuelle et en recrée de nouveaux avec le montant exact du mois (jours réels × TJM). Les mois déjà facturés restent tracés par leurs Invoices, qui sont permanentes.

### Étape 3 — Facturation

Deux modes disponibles :

**Mois par mois** — depuis le cockpit régie, via `createAndPostInvoice`. Crée et poste la facture du mois sélectionné. Date de facturation : 1er du mois suivant (facturation en arrears).

**Ordre global** — depuis la Quick Action `regieFacturerAction`, via `invoiceOrder`. Facture tous les mois validés en une seule action.

Dans les deux cas : `ConnectApi.Billing.generateInvoices` crée et poste la facture Revenue Cloud.

---

## Modèle Forfait — Processus détaillé

### Schéma du processus

```
[Activation Order]             [Réalisation jalon]            [Facturation jalon]
──────────────────             ───────────────────            ───────────────────
RLM génère les BS         →    Le gestionnaire            →   Crée et poste
+ BillingMilestonePlan         marque le jalon                la facture RLM
Items automatiquement          comme réalisé                  (séquentiel)
(conservés tels quels)
```

> **Comportement à l'activation de la commande :** Pour le modèle Forfait, l'activation de l'Order déclenche la création automatique par Revenue Cloud des `BillingSchedule` et des `BillingMilestonePlanItem` à partir du Billing Treatment. Ces enregistrements sont conservés tels quels et utilisés directement par le cockpit — aucune suppression ni recréation.

### Règle de séquentialité

Les jalons sont **strictement séquentiels** : un jalon ne peut être réalisé que si le jalon précédent est réalisé ET facturé. En cas de tentative hors séquence, le système affiche le message : *"Réalisez et facturez d'abord « [jalon précédent] »"*.

### Réalisation d'un jalon

Le bouton "Réaliser" dans le **milestoneBillingCockpit** passe `IsMilestoneAccomplished = true` sur tous les `BillingMilestonePlanItem` du jalon, rendant l'échéance facturable (statut `ReadyForInvoicing`).

### Facturation

`MilestoneBillingController.invoiceMilestone` — crée et poste la facture de toutes les échéances `ReadyForInvoicing` de l'Order.

---

## Modèle Paie — Processus détaillé

### Principe

Le modèle Paie (dit "Usage / Social") facture les missions de **gestion de la paie** : chaque mois, le nombre de bulletins de salaire traités est multiplié par un prix unitaire pour calculer le montant à facturer. Il utilise **Silae** comme logiciel source des données de paie.

C'est une variante simplifiée du modèle Régie — une seule ligne "Bulletin de paie" par mois au lieu de plusieurs grades — avec le même pipeline technique RLM.

### Schéma du processus

```
[Activation Order]   [1] Import Silae          [2] Validation                 [3] Facturation
──────────────────   ─────────────────         ──────────────────────────     ──────────────────
RLM crée des    →    Génère 1 ligne        →    Vérifie / corrige          →   Crée et poste
BS Evergreen         par mois dans              nb bulletins                   la facture RLM
(supprimés à         RSM_PaieBillingPlan__c     puis valide                    via ConnectApi
chaque validation)   (statut Brouillon)         → supprime les BS Evergreen
                                                → recrée les BS du mois
```

### Étape 1 — Import Silae (simulation)

Le bouton **"Import Silae"** (dans le cockpit ou via Quick Action) sélectionne la ligne produit "Bulletin de paie" de l'Order et crée un enregistrement `RSM_PaieBillingPlan__c` pour le mois choisi, en statut **Brouillon**.

**En production**, Silae enverrait le vrai nombre de bulletins traités dans le mois.

**En démo (simulation)**, le code (`PaieBillingController.simulerImportSilae`) génère un nombre fictif de bulletins :

| Donnée | Valeur simulée |
|--------|----------------|
| Nombre de bulletins | Entre 40 et 60 (aléatoire) |
| Prix unitaire | Prix réel de la ligne produit (défaut : 12€) |
| Statut initial | Brouillon |
| Source | Silae (tracé dans `Source__c`) |

> Si aucun mois n'est précisé, l'import cible automatiquement le mois suivant le dernier importé, ou le mois de démarrage de la mission si aucun import n'existe encore. L'import est idempotent via `ExternalKey__c = OrderId-YYYY-MM`.

### Étape 2 — Validation

Même mécanique que la Régie : `prepareMonth()` met à jour l'OrderItem avec le nombre de bulletins et le prix du mois, supprime les BS Evergreen existants et passe le plan en **Validé**. Puis `createSchedules()` recrée les Billing Schedules via l'API RLM.

> La mission doit être **Activée** avant de pouvoir valider un mois — le code vérifie explicitement `Order.Status = 'Activated'`.

### Étape 3 — Facturation

Identique à la Régie : facturation mois par mois (`createAndPostInvoice`) ou globale pour tous les mois validés (`invoiceOrder`). Date de facturation : 1er du mois suivant (arrears).

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

## Lightning Pages

### Cockpit_Facturation_Global (App Page)

Page de type **App Page** accessible depuis la navigation de l'application. Elle affiche uniquement le composant `cockpitFacturationGlobal` qui prend toute la surface de la page.

**Ce que l'utilisateur voit :**

- **3 indicateurs KPI** en haut : total à facturer, total facturé, et nombre de missions avec du staffing Napta à valider
- **Sélecteur de mois** pour naviguer et voir les missions du mois choisi
- **Toggle filtre** "Afficher uniquement les missions avec staffing Napta à valider"
- **Tableau des missions** avec les colonnes : N° Order, Client, Modèle (Régie / Forfait / Paie), Staffing Napta à valider, Montant HT, Statut (À traiter / Validé / Facturé)

Les missions avec du staffing Napta non validé remontent automatiquement en tête de liste. C'est le **point d'entrée central** pour les gestionnaires qui pilotent la facturation de l'ensemble des missions du mois.

---

## Objets Salesforce impliqués

| Objet | Rôle dans la solution |
|-------|-----------------------|
| `Order` | La mission / affaire ProServ |
| `OrderItem` | Les grades et frais contractuels |
| `RegieBillingPlan__c` | Les lignes mensuelles régie (grades + frais) |
| `RSM_PaieBillingPlan__c` | Les lignes mensuelles paie (bulletins de salaire) |
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
| `PaieBillingController` | Import Silae, édition, validation, facturation paie |
| `AffaireControlTowerController` | Calcul du pilotage 360° et du Boni/Mali |
| `GlobalBillingController` | Agrégation des missions pour le cockpit global |

---

## Portabilité — Modifications pour déploiement multi-org

### IDs hardcodés supprimés

Les classes `RegieBillingController` et `PaieBillingController` contenaient des IDs d'enregistrements Salesforce spécifiques à l'org RSM, qui auraient cassé tout déploiement sur une autre org :

| ID supprimé | Valeur originale | Rôle |
|-------------|-----------------|------|
| `REGIE_TREATMENT` | `1BTWs0000004ik1OAA` | ID du Billing Treatment "Régie Mensuelle (Arrears)" |
| `BULLETIN_PRODUCT` | `01tWs00000EdlqXIAR` | ID du produit "Bulletin de paie" |

### Solution appliquée

**`REGIE_TREATMENT`** (dans les deux classes) — remplacé par un getter `getRegieTreatmentId()` qui interroge dynamiquement l'org cible :
```apex
SELECT Id FROM BillingTreatment WHERE Name = 'Régie Mensuelle (Arrears)' LIMIT 1
```
Le résultat est mis en cache statique pour éviter des requêtes répétées. Si le Treatment n'existe pas sur l'org, une erreur explicite s'affiche.

**`BULLETIN_PRODUCT`** (dans `PaieBillingController`) — supprimé. La recherche du produit "Bulletin de paie" repose désormais uniquement sur le pattern de nom :
```apex
Product2.Name LIKE 'Bulletin%paie%'
```

### Prérequis sur l'org cible

Pour que les composants fonctionnent sur une nouvelle org, celle-ci doit disposer de :
- Revenue Cloud Billing activé
- Un Billing Treatment nommé exactement **"Régie Mensuelle (Arrears)"**
- Un produit dont le nom contient **"Bulletin"** et **"paie"** (ex : "Bulletin de paie")
- Le Billing Context `RLM_BillingContext` avec ses mappings `OrderEntitiesMapping` et `BSGEntitiesMapping`

---

## Déploiement sur une nouvelle org

Un script de déploiement est disponible à la racine du projet. Il déploie tous les composants en 4 étapes ordonnées (objets → Apex → LWC → pages).

**La validation est toujours exécutée avant chaque déploiement réel.** Si une étape ne passe pas la validation, le script s'arrête immédiatement et le déploiement est annulé. Aucune modification n'est appliquée à l'org en cas d'échec.

```bash
cd /Users/cbouclier/VSCode/ProServ && ./deploy.sh <alias-org>
```

Exemple :
```bash
./deploy.sh my-sandbox
./deploy.sh user@company.com
```

Pour chaque étape, le script :
1. Lance une validation (`sf project deploy validate`) — vérifie la compatibilité sans toucher à l'org
2. Si la validation réussit → lance le déploiement réel (`sf project deploy start`)
3. Si la validation échoue → affiche l'erreur et arrête tout

Voir [deploy.sh](deploy.sh) pour le détail des étapes et les vérifications post-déploiement.

---

→ Voir [COMPOSANTS_LWC.md](COMPOSANTS_LWC.md) pour la description de tous les composants du projet.
