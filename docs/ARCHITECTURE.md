# B-OUI — Architecture technique v1

## Statut
Ce document décrit la cible technique. La branche de travail est isolée de `main`. Aucun projet Supabase, aucune base distante et aucun secret de paiement ne sont créés ou modifiés par ce dépôt.

## Produit
Billetterie des événements scolaires en Guinée, montants en GNF, interface française responsive. Le premier prestataire prévu est Orange Money Guinée. MTN Mobile Money est une extension ultérieure.

## Espaces
- Acheteur : découverte, réservation, paiement, billets, récupération, historique.
- École : demande d'accès, membres, événements, tarifs, ventes et rapports.
- Organisateur : événements attribués, agents, contrôle des entrées et rapports.
- Administration B-OUI : vérification des écoles, approbation des événements, commissions, remboursements, comptes et audit.

## Architecture cible
1. Frontend web responsive hébergé sur Cloudflare Pages.
2. API/backend de confiance pour toutes les opérations sensibles.
3. PostgreSQL avec Row Level Security.
4. Authentification gérée par un fournisseur compatible Supabase Auth.
5. Stockage privé pour les exports et documents.
6. Adaptateur de paiement Orange Money côté serveur.
7. Génération de billets et QR codes côté serveur.

Le frontend ne reçoit jamais la clé service-role ni les secrets du prestataire.

## Flux de réservation et paiement
1. L'API vérifie que l'événement est publié et que le tarif est actif.
2. Une transaction verrouille le type de billet, vérifie le quota et réserve les quantités.
3. La réservation reçoit une échéance et une clé d'idempotence.
4. L'API crée une demande de paiement auprès du prestataire.
5. Une notification serveur est authentifiée, vérifiée, dédupliquée et rapprochée du montant, de la devise et de la référence attendus.
6. La page de retour du navigateur n'est jamais une preuve de paiement.
7. Après vérification cryptographique et métier du webhook, le backend appelle la fonction SQL privée de confirmation. La fonction verrouille réservation, paiement et quotas dans un ordre stable.
8. Une transaction confirme le paiement, convertit le quota réservé en quota vendu et émet exactement un billet par unité achetée. Une notification répétée du même paiement ne crée aucun billet supplémentaire.
9. Un paiement reçu après expiration est mis en revue manuelle ; il ne réactive pas automatiquement une réservation expirée.
10. L'identifiant de transaction du prestataire est unique par prestataire. Les événements webhook sont journalisés et traités de manière idempotente.

## QR code et récupération
- Le QR contient un jeton opaque signé (HMAC) par le backend ; le secret n'est jamais dans PostgreSQL ni dans le frontend.
- La base conserve uniquement l'empreinte SHA-256 du jeton et la version de clé utilisée. Le backend peut recalculer le même jeton pour le même ticket, y compris après rotation contrôlée des clés.
- La récupération restitue le billet original et le même QR code ; elle ne crée aucun billet.
- Depuis le compte : accès aux billets déjà émis.
- Sans compte : référence de réservation et canal de contact vérifié par OTP.
- Réponse générique pour éviter de révéler l'existence d'une réservation.
- Expiration des OTP, limitation des tentatives et journalisation.

## Règles financières
- Montants stockés en unités entières de GNF.
- Commission applicable : événement, sinon école, sinon règle générale.
- La vente conserve un instantané du prix et de la commission appliqués.
- Les remboursements nécessitent une décision autorisée et ne peuvent dépasser le montant encaissé.
- Les opérations financières sont historisées ; pas de réécriture silencieuse.

## Sécurité
- RLS activée sur toutes les tables exposées.
- Accès acheteur limité à ses données.
- Accès école limité à son établissement et à ses membres autorisés.
- Organisateur limité aux événements explicitement attribués.
- L'approbation, les paiements, l'émission, les quotas, les remboursements et les scans passent par le backend.
- Journal d'audit append-only.
- Secrets uniquement côté serveur ; vérification de signature, horodatage, anti-rejeu et idempotence pour les webhooks.
- Sauvegardes et restauration testées avant lancement.

## Déploiement et environnements
- Développement local avec données fictives.
- Environnement de test séparé pour les migrations et les tests d'intégration.
- Production uniquement après revue, tests et autorisation explicite.
- Les changements sont préparés sur une branche dédiée et soumis en Pull Request ; aucun merge automatique vers main.

## Ordre de livraison
1. Schéma SQL et politiques d'accès.
2. Tests RLS et contraintes multi-tenant.
3. Authentification et demandes d'accès écoles.
4. Événements, approbations et tarifs.
5. Réservations transactionnelles et expiration.
6. Confirmation de paiement vérifiée et émission atomique.
7. Adaptateur Orange Money réel, récupération et scan des billets.
8. Commissions, remboursements, rapports et audit.
9. Tests de charge, sécurité, sauvegarde et restauration.

## Hors périmètre de cette première livraison
Aucun compte marchand Orange Money, aucun projet Supabase, aucune base distante, aucune clé API, aucun déploiement Cloudflare et aucune donnée réelle ne sont créés ou modifiés.
