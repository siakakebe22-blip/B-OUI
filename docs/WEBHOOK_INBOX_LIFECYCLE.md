# B-OUI — Cycle de vie de l'inbox webhook

## Portée
Cette étape ajoute uniquement le mécanisme interne de prise en charge et de reprise des événements déjà authentifiés et enregistrés. Elle ne définit aucun endpoint Orange Money/MTN MoMo, aucune signature fournisseur et aucune connexion réseau vers un opérateur.

## États
- `received` : événement durablement enregistré, en attente du premier worker.
- `processing` : événement réservé à un worker par un bail temporaire.
- `failed` : traitement échoué de façon temporaire ; nouvelle tentative après `next_attempt_at`.
- `processed` : traitement terminé avec succès.
- `ignored` : événement reconnu comme non applicable.
- `dead_letter` : échec non récupérable ou limite de tentatives atteinte ; revue opérationnelle requise.

## Prise de bail
`claim_payment_webhook_events` sélectionne un lot limité avec `FOR UPDATE SKIP LOCKED`, puis attribue à chaque ligne un worker, un jeton aléatoire et une date d'expiration. Un événement en cours n'est pas remis à un autre worker avant expiration de son bail. Un bail expiré est récupérable ; si le nombre maximal de tentatives est atteint, l'événement passe en `dead_letter`.

Le jeton de bail est une preuve de possession à durée limitée. Un worker remplacé ne peut pas terminer un événement avec un ancien jeton.

## Accusé de traitement et reprises
`finish_payment_webhook_event` accepte uniquement le jeton de bail courant :
- `processed` : fixe `processed_at` ;
- `ignored` : termine sans émission de billet ;
- `failed` retryable : planifie une nouvelle tentative avec backoff exponentiel de 30 secondes à 1 heure ;
- échec non retryable ou limite atteinte : `dead_letter`.

Les erreurs sont stockées sous forme de codes courts non sensibles. Aucun corps brut, OTP, PIN, jeton ou secret fournisseur n'est ajouté aux logs par cette migration.

## Accès
Les fonctions sont `SECURITY DEFINER`, avec `search_path` fixé, et EXECUTE réservé à `service_role`. Les rôles `anon` et `authenticated` n'ont aucun accès à la table inbox ni aux fonctions de worker.

## Limites restantes
- L'authentification cryptographique de la notification reste dépendante du contrat officiel de chaque opérateur.
- Le worker HTTP, l'accusé HTTP attendu, la supervision/alerte, le rapprochement fournisseur et la politique de rétention doivent être développés séparément.
- Une transaction métier réussie et l'accusé de l'inbox doivent être coordonnés de manière idempotente par l'orchestrateur serveur. La fonction SQL d'inbox seule ne prouve pas le paiement et n'émet aucun billet.
- La garantie append-only des journaux et la sécurité du propriétaire de la base restent distinctes des privilèges applicatifs.

## Recette locale obligatoire
Le workflow PostgreSQL local exécute le contrat 0007 et le test runtime du cycle de vie : réservation exclusive, reprise après expiration, rejet d'un ancien jeton, succès idempotent au niveau de l'état et dead-letter après épuisement des tentatives.
