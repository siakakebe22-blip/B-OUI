# B-OUI — Audit technique initial des fondations SQL

Date de l'audit : 25 novembre 2026  
Branche examinée : `feature/fondations-techniques-v1`  
Périmètre : migrations SQL 0001 à 0004, scripts de contrôle 0001 à 0004 et architecture technique.

## 1. Portée et limites

Cet audit est une revue statique du contenu GitHub. Les migrations et scripts de contrôle n'ont pas été exécutés dans PostgreSQL/Supabase pendant cet audit. Aucune base, ressource cloud, donnée métier, clé ou configuration de paiement n'a été créée ou modifiée. Aucun test de concurrence, d'intégration ou de pénétration n'a été exécuté.

La branche examinée est en avance de 20 commits sur `main` et en retard de 0 commit au moment de la vérification.

## 2. Points solides constatés

- Les 18 tables de base sont déclarées avec des clés étrangères et contraintes métier.
- RLS est activée sur les 18 tables initiales.
- Les écritures financières sensibles sont retirées aux rôles clients dans la migration 0002.
- La création de réservation verrouille le type de billet et utilise une clé d'idempotence.
- La confirmation de paiement est réservée à `service_role`, vérifie le montant et la devise, et émet les billets dans la même transaction.
- La migration 0004 ajoute une inbox webhook privée et corrige l'expiration en vérifiant les quotas avant leur libération.
- Les secrets de paiement et les clés HMAC QR sont explicitement exclus de la base et du frontend dans l'architecture cible.

## 3. Constatations et corrections recommandées

### BOU-DB-001 — Vérifier l'état de l'école dans la réservation
**Priorité : haute**

La fonction `public.create_reservation` vérifie le statut publié de l'événement, mais ne vérifie pas explicitement que l'école associée est toujours `verified`. Comme la fonction est `SECURITY DEFINER`, elle ne doit pas dépendre des politiques RLS des lectures publiques pour faire cette validation métier.

**Correction recommandée :** joindre l'école dans la vérification serveur et refuser toute réservation si l'école n'est pas vérifiée. Ajouter un test couvrant une école suspendue avec un événement qui serait encore marqué publié.

### BOU-DB-002 — Lier la clé d'idempotence au contenu de la demande
**Priorité : haute**

Lorsqu'une réservation existe déjà avec la même clé et le même acheteur, la fonction retourne cette réservation sans comparer le type de billet ni la quantité demandée. Une réutilisation accidentelle de la même clé pour une demande différente peut donc retourner une réservation qui ne correspond pas à la demande courante.

**Correction recommandée :** comparer le contenu de la demande existante (type de billet, quantité et paramètres pertinents) avant de retourner la réservation. Retourner un conflit explicite si le contenu diffère. Ajouter des tests même clé/même payload et même clé/payload différent.

### BOU-DB-003 — Limiter les colonnes publiques de l'école
**Priorité : moyenne à haute, selon la sensibilité des contacts**

La politique RLS `schools_select_verified` autorise la lecture des lignes d'écoles vérifiées, tandis que le rôle public reçoit un accès SELECT à la table. RLS filtre les lignes, pas les colonnes : les champs `contact_email` et `contact_phone` sont donc lisibles avec les autres colonnes par les rôles autorisés.

**Correction recommandée :** séparer les informations publiques des coordonnées privées, ou exposer une vue publique à colonnes limitées avec une configuration `security_invoker` appropriée et des privilèges contrôlés. Vérifier les accès aux données privées par tests.

### BOU-DB-004 — Renforcer le journal d'audit
**Priorité : haute avant production**

La table `audit_logs` existe, mais les migrations actuelles ne démontrent pas une immutabilité complète au niveau base (interdiction de modification/suppression pour les rôles applicatifs, voie d'écriture contrôlée, séparation des privilèges et conservation).

**Correction recommandée :** définir une voie d'écriture backend dédiée, retirer les privilèges de modification/suppression aux rôles applicatifs, et tester qu'un utilisateur ou opérateur non autorisé ne peut ni modifier ni effacer les traces.

### BOU-DB-005 — Compléter le cycle de vie de l'inbox webhook
**Priorité : haute avant intégration réelle**

La table privée et la clé de déduplication existent. Le dépôt ne fournit pas encore le traitement complet de prise en charge concurrente, bail/lease de traitement, reprise après interruption, politique de retry, classement définitif et réponse d'acquittement conforme au contrat Orange Guinée.

**Correction recommandée :** concevoir les transitions atomiques de l'inbox, les verrous/leases, les retries bornés, les erreurs définitives, l'observabilité et les règles d'ACK à partir de la documentation marchande officielle. Ne pas inventer la signature ou le format des webhooks.

### BOU-DB-006 — Compléter les tests de sécurité multi-tenant
**Priorité : haute avant production**

Les scripts actuels contrôlent surtout l'existence des tables, RLS, certains privilèges et quelques index/fonctions. Ils ne démontrent pas encore l'isolation complète entre écoles, les accès aux colonnes sensibles, les politiques de lecture croisées, les permissions de chaque rôle et les scénarios de privilèges hérités.

**Correction recommandée :** ajouter une matrice de tests avec au moins deux écoles, plusieurs rôles et des tentatives croisées de lecture/écriture. Vérifier les privilèges effectifs, pas seulement la présence des politiques.

### BOU-DB-007 — Vérifier l'exposition Data API des nouvelles tables
**Priorité : moyenne, à traiter avant connexion frontend**

Depuis le changement Supabase d'octobre 2026, les nouvelles tables du schéma public ne sont plus automatiquement exposées à la Data API. Les GRANT SQL et les politiques RLS ne suffisent pas à eux seuls à établir l'exposition REST souhaitée. Il faudra maintenir une liste explicite des tables exposées, et laisser les tables internes/webhook privées non exposées.

**Correction recommandée :** définir et documenter l'allowlist Data API par table, en vérifiant conjointement exposition, GRANT et RLS. Source : https://supabase.com/changelog/breaking-change-tables-not-exposed-by-default

### BOU-DB-008 — Compléter la couverture des scénarios transactionnels
**Priorité : haute avant production**

Les tests fournis sont principalement des assertions structurelles. Ils ne valident pas encore l'exécution réelle des scénarios de concurrence, de double notification, de paiement tardif, de réservation du dernier billet, d'expiration concurrente et de rollback après échec d'émission.

**Correction recommandée :** construire une suite d'intégration PostgreSQL isolée avec sessions concurrentes et données jetables. Vérifier l'état final des quotas, paiements, réservations, billets et journaux après chaque scénario.

### BOU-DB-009 — Clarifier la portée fonctionnelle des réservations
**Priorité : moyenne**

La table `reservation_items` autorise plusieurs catégories dans une réservation, mais `create_reservation` ne crée qu'une seule ligne d'article par appel. Le parcours multi-catégories n'est donc pas implémenté par cette fonction. La fonction exige également un compte et un profil existants ; le parcours d'achat invité n'est pas couvert.

**Correction recommandée :** décider si le premier lancement impose un compte acheteur et limite chaque réservation à un seul type de billet, ou s'il faut une fonction transactionnelle multi-articles et un modèle invité sécurisé. Documenter le choix avant le frontend.

## 4. Éléments non vérifiés

- Exécution des migrations dans une base PostgreSQL de test.
- Exécution des scripts SQL de contrôle.
- Tests de concurrence réels et analyse des deadlocks.
- Revue des privilèges effectifs et des défauts de privilèges du projet Supabase cible.
- Conseils Supabase Advisors sur un projet isolé.
- Test complet du stockage privé, des fonctions backend, des webhooks et du scanner QR.
- Audit juridique et conformité locale.

## 5. Plan de correction recommandé

1. Corriger BOU-DB-001 et BOU-DB-002 avant d'exposer la fonction de réservation.
2. Traiter BOU-DB-003 et BOU-DB-004 avant d'ouvrir les lectures publiques et l'administration.
3. Définir BOU-DB-005 avec le contrat officiel Orange Money Guinée.
4. Ajouter BOU-DB-006 et BOU-DB-008 dans une base PostgreSQL de test isolée.
5. Définir l'allowlist Data API BOU-DB-007.
6. Trancher BOU-DB-009 avant la finalisation du parcours acheteur.

## 6. Décision de l'audit

**Statut : fondations prometteuses, non prêtes pour production.**

Les migrations 0001 à 0004 ne doivent pas être exécutées sur une base de production à ce stade. La prochaine intervention doit être une correction ciblée des défauts prioritaires sur la branche de développement, suivie de tests PostgreSQL isolés et reproductibles.

Aucun merge vers `main`, déploiement Cloudflare, création de ressource cloud, exécution de migration distante ou paiement réel n'est autorisé par ce rapport.
