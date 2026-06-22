# Composants LWC — Org RSM

49 composants organisés en 3 familles.

---

## Famille 1 — ProServ (Professional Services)

Composants métier custom, spécifiques à la gestion de projets de services (Forfait / Régie / Milestone).

### affaireControlTower
Tableau de bord central d'une affaire (projet de services). Affiche la rentabilité globale avec un indicateur visuel **Boni / Mali / À l'équilibre**, les montants clés du pilotage financier, et deux actions : générer une FAE (Facture À Établir) ou en lier une existante. C'est le composant principal posé sur la page d'un Order ProServ.

### cockpitFacturationGlobal
Vue globale de la facturation sur l'ensemble des affaires. Donne une vision d'ensemble du pipeline de facturation en cours, tous projets confondus.

### milestoneBillingCockpit
Cockpit de facturation pour les affaires au modèle **Milestone** (facturation par jalons). Permet de suivre l'avancement des jalons et de déclencher leur facturation depuis une interface dédiée.

### milestoneFacturerAction
Bouton d'action permettant de facturer un jalon spécifique. Se pose directement sur une page de record ou s'intègre dans un flow.

### regieBillingCockpit
Cockpit de facturation pour les affaires au modèle **Régie** (temps passé / T&M). Affiche les lignes de régie consommées et permet de déclencher la facturation des heures saisies.

### regieBillingStatus
Indicateur visuel du statut de facturation pour une ligne de régie. Composant léger, généralement intégré dans le cockpit ou une page d'enregistrement.

### regieFacturerAction
Bouton d'action permettant de facturer les lignes de régie sélectionnées. Équivalent du `milestoneFacturerAction` pour le modèle Régie.

### regieRefreshPublisher
Composant utilitaire invisible. Après une action de facturation régie, il publie un signal de rafraîchissement pour que tous les autres composants de la page se mettent à jour automatiquement.

---

## Famille 2 — RLM (Revenue Lifecycle Management)

Composants standard Revenue Cloud couvrant la facturation, les invoices, les paiements, le recouvrement et l'usage.

### rlmAssetRatesGrants
Affiche les **tarifs (Rate Cards)** et les **droits d'usage (Entitlement Grants)** associés à un Asset Revenue Cloud. Utile pour voir les grilles de prix applicables et les volumes alloués à un client.

### rlmBillingCaseMetrics
Tableau de bord des opérations de facturation. Affiche 4 métriques : nombre de Billing Cases ouverts, litiges en cours, factures disputées, et montant total en dispute. Se pose sur une page d'accueil ou un dashboard.

### rlmBillingScheduleGroupHierarchy
Vue hiérarchique des **Billing Schedule Groups (BSG)** d'un compte ou d'un order. Résumé en 4 indicateurs : total BSGs, actifs, montant facturé, montant en attente. Navigable en cliquant sur les enregistrements.

### rlmBillingStatus
Badge discret indiquant qu'un compte a la **facturation suspendue**. S'affiche uniquement si une suspension est active (dates de suspension/reprise), invisible sinon. Se pose sur la page du compte.

### rlmBsgConsolidatedTimeline
**Timeline consolidée** d'un Billing Schedule Group. Vue graphique de tous les segments de facturation dans le temps, avec montants facturés et en attente sur un axe chronologique.

### rlmBsgSchedulesTimeline
**Timeline des Billing Schedules** individuels d'un BSG. Vue de type Gantt avec code couleur par statut (Actif, Entièrement facturé, Planifié, Annulé). Permet de cliquer sur un schedule pour voir ses détails.

### rlmCollectionRuleBuilder
Interface de création de **règles de recouvrement**. Permet de définir des conditions (ex : jours de retard > 30, montant > X) et des actions (assignation à une queue, déclenchement d'une timeline). Outil de configuration pour les équipes AR.

### rlmCollectionsDashboard
Tableau de bord complet du **recouvrement (AR Recovery)**. KPIs en temps réel (créances totales, montants échus, paiements non appliqués), graphique d'aging en arc-en-ciel, et liste de travail (worklist) filtrée par priorité. Filtrable par compte et devise.

### rlmDisputeDetails
Affiche les détails d'un **litige (Dispute)** lié à un Case de facturation. Permet de consulter les lignes disputées et de saisir les montants approuvés directement dans le composant.

### rlmDocPreview
Composant technique permettant d'afficher un **aperçu de document** (fichier Salesforce) dans une page ou un flow. Corrige un problème de hauteur d'affichage du prévisualiseur natif Salesforce.

### rlmDocStatusMonitor
**Moniteur de progression** de génération de document. S'utilise dans un flow : affiche un spinner animé ("Generating your document, please wait...") et avance automatiquement dans le flow dès que le document est prêt.

### rlmInvoiceAging
Composant d'**aging des factures** d'un compte. Affiche les métriques clés (nombre total, factures en retard, âge moyen) et une répartition par tranches : moins de 30 jours, 30-60 jours, plus de 60 jours. Section dépliable/repliable.

### rlmInvoiceAgingChart
Version **graphique** de l'aging des factures. Mêmes métriques que `rlmInvoiceAging` présentées avec un graphique en barres. Les deux composants sont complémentaires.

### rlmInvoiceHealth
Indicateur de **santé d'une facture individuelle**. Affiche l'âge de la facture (jours ouverts), sa date d'échéance, son statut avec alertes visuelles, et la progression du règlement (payé vs total).

### rlmInvoiceProductSummary
**Résumé des produits facturés** sur une invoice. Consolide plusieurs lignes de facture par produit en une vue unique. Chaque ligne est expansible pour voir le détail et les attributs de l'asset associé.

### rlmInvoiceTaxSummary
**Résumé des taxes** d'une facture, regroupées par type de taxe avec le montant total par type. Simple tableau à deux colonnes (Nom de taxe / Montant).

### rlmInvoiceTransactionJournals
Liste des **écritures comptables (Transaction Journals)** liées à une facture. Affiche les entrées débit/crédit avec les comptes du Grand Livre associés. Utile pour la comptabilité et les audits.

### rlmOrderRedirect
Composant de **redirection automatique** utilisé dans les flows. Après la création d'un Order, il redirige automatiquement l'utilisateur vers la page de cet Order. Affiche "Redirecting to Order..." pendant la navigation.

### rlmPaymentsData
Vue des **données de paiement (Payment Schedule Items)** filtrables par compte et devise. Affiche les paiements regroupés par statut (Failed, Ready for Processing, etc.) sous forme de cartes colorées.

### rlmQuoteRedirect
Équivalent de `rlmOrderRedirect` pour les **Quotes**. Composant de flow qui redirige automatiquement vers un devis après sa création.

### rlmRampRefreshPage
Bouton **"View Quote"** affiché sur l'écran de succès d'un flow de Ramp Schedule. Redirige l'utilisateur vers la page du devis en fermant proprement le flow.

### rlmRampScheduleFlowModalAction
**Quick Action** qui ouvre le flow de création de Ramp Schedule dans une fenêtre modale. Doit être placé sur la page d'un Quote. Lance le flow `RLM_Create_Ramp_Schedule_V4`.

### rlmRampScheduleForm
**Formulaire de configuration** d'un Ramp Schedule. Permet de saisir le nom, le type (Annuel / Custom), la date de démarrage, la durée et le nombre de segments. Communique en temps réel avec la table de prévisualisation via Lightning Message Service.

### rlmRampSchedulePreviewTable
**Table de prévisualisation** du Ramp Schedule en cours de configuration. Affiche tous les segments avec nom, type, durée, dates, remise (%) et uplift (%). Se met à jour en temps réel à mesure que l'utilisateur remplit le formulaire.

### rlmRampScheduleStatus
**Indicateur de progression** de la création d'un Ramp Schedule. Affiche un spinner pendant le traitement Apex, puis un message de succès ("Ramp Schedule Ready") avec fermeture automatique de la modal.

### rlmRampScheduleTrialSection
Section optionnelle **"Trial"** dans le configurateur de Ramp Schedule. Permet d'ajouter une période d'essai en début de ramp, avec durée (jours ou mois) et remise (%) configurables.

### rlmRebuildSearchIndex
Bouton utilitaire pour **reconstruire l'index de recherche** du Product Catalog Management (PCM). Déclenche un job technique en arrière-plan. Le composant prévient que le traitement peut prendre jusqu'à 15 minutes.

### rlmSetUpQuoteHierarchyTree
Composant d'**arbre hiérarchique** pour configurer les groupes et sous-groupes d'un Quote. Supporte trois modes : création manuelle (avec ajout et renommage), import CSV (renommage uniquement), et révision en lecture seule. Profondeur maximale de 5 niveaux.

### rlmSetUpQuoteWizard
**Assistant (Wizard) complet en 8 étapes** pour créer ou modifier un Quote avec hiérarchie de groupes. Couvre : choix création/modification, informations du devis, configuration de la hiérarchie, assignation des produits Repeat Buy, définition des quantités, validation, et confirmation. C'est le composant central du processus de création de devis avancé.

### rlmSplitInvoicesCards
Vue en **cartes visuelles** des factures scindées (Split Invoices) d'une même facture parente. Toutes les factures partageant le même `CorrelationIdentifier` s'affichent sous forme de cartes avec statut coloré et navigation vers chaque facture.

### rlmSplitInvoicesView
Vue en **tableau** des factures scindées. Équivalent de `rlmSplitInvoicesCards` mais sous forme de datatable triable. Les deux composants servent le même besoin avec des présentations différentes.

### rlmUsageDataTable
**Tableau dynamique** d'affichage des données d'usage. Affiche des enregistrements de type TransactionJournal, UsageSummary ou UsageBillingPeriodItem. Les colonnes sont configurées sans code via un FieldSet Salesforce. Inclut tri et pagination côté client (10 enregistrements par page).

### rlmUsageOrchestration
Interface pour **déclencher manuellement le traitement des données d'usage**. Un bouton "Process Usage" lance le flow d'orchestration `RLM_Orchestrate_Usage_Management`. Un lien "Monitor Workflow Services" permet de suivre l'avancement. Le traitement dure environ 15 minutes.

### rlmUsageUploader
**Outil d'upload de consommation** sur un Asset Revenue Cloud. Deux modes disponibles : saisie unitaire via formulaire (un enregistrement à la fois) et import en masse via CSV avec prévisualisation et validation avant envoi.

---

## Famille 3 — xdoTool (utilitaires Salesforce ISV)

Bibliothèque technique Open Source Salesforce (auteur : Paul Lucas, Q-Branch) pour le tracking d'événements d'usage. Sert à mesurer comment les composants sont utilisés.

### xdoToolCommonJs
**Bibliothèque de fonctions utilitaires** JavaScript communes : affichage de toasts, manipulation de chaînes, gestion d'erreurs. Partagée par tous les autres composants xdoTool.

### xdoToolConstants
**Fichier de constantes** centralisé : types d'API, variantes de boutons, événements DOM, types d'événements, actions de navigation, types de toasts. Évite de dupliquer ces valeurs dans chaque composant.

### xdoToolTrackingEvent
**Système de création d'événements** de tracking. Trois types d'événements : Monitoring (surveillance), Product Development (usage produit), Reporting (reporting). Chaque événement capture le composant source, l'utilisateur et les données contextuelles.

### xdoToolTrackingEventConfig
**Interface de configuration** du système de tracking. Affiche la configuration active du handler sous forme de code formaté. Utilisé pour le debug et la documentation.

### xdoToolTrackingEventHandler
**Handler d'événements de tracking**. Écoute les événements émis par les composants et les transmet à Apex pour persistance ou analyse.

### xdoToolTrackingEventHandlerBase
**Classe de base** pour les handlers de tracking. Contient la logique commune : abonnement aux événements, publication vers Apex via `XDO_Tool_TrackingEventController`, et gestion de la navigation.

### xdoToolTrackingEventTestHarness
**Harnais de test** du système de tracking. Interface permettant d'envoyer manuellement des événements de tracking pour vérifier que le système fonctionne correctement. Usage développement uniquement.
