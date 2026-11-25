# B-OUI

Billetterie des événements scolaires en Guinée.

## État du dépôt
La branche `feature/fondations-techniques-v1` contient les premiers documents de cadrage technique et les migrations PostgreSQL de fondation.

- `docs/ARCHITECTURE.md` : architecture cible, flux, sécurité et ordre de livraison.
- `supabase/migrations/0001_core_schema.sql` : tables, contraintes, index et activation RLS.
- `supabase/migrations/0002_atomic_reservations.sql` : réservation transactionnelle, idempotence et expiration initiale.
- `supabase/migrations/0003_verified_payment_and_ticket_issuance.sql` : confirmation privée d'un paiement préalablement vérifié par le backend, conversion atomique des quotas, émission idempotente et audit.
- `supabase/migrations/0004_webhook_inbox_and_expiration_locking.sql` : inbox privée de notifications, déduplication persistante et expiration avec verrous ordonnés et contrôle strict des quotas.
- `supabase/tests/0001_schema_contract.sql`, `0002_reservation_security.sql`, `0003_payment_issuance_security.sql` et `0004_webhook_inbox_security.sql` : contrats structurels et permissions.

## Attention
Ces migrations sont une base de travail, pas une version certifiée production. Elles n'ont pas été exécutées contre PostgreSQL/Supabase dans cette livraison et ne doivent pas être appliquées à une base de production. Les contrats SQL ne remplacent pas les tests d'intégration et de concurrence sur une instance PostgreSQL de test.

La migration 0004 ajoute le stockage dédupliqué des notifications et corrige la stratégie de verrouillage de l'expiration. Elle ne vérifie pas elle-même les signatures du prestataire : le backend doit authentifier la notification avant son insertion, utiliser une clé de déduplication stable conforme à la documentation officielle, puis rapprocher les données métier avant d'appeler la confirmation SQL.

L'adaptateur Orange Money Guinée reste à concevoir à partir de la documentation officielle du produit marchand en Guinée et de son environnement sandbox. Aucun endpoint, en-tête, format de signature ou statut fournisseur n'est supposé dans ce dépôt. Les fonctions de scan et de récupération, les tests d'intégration RLS multi-utilisateurs, de webhook et de concurrence restent à réaliser.

Aucun projet cloud, secret, compte marchand, paiement réel ou donnée réelle n'est créé ici.

- `docs/ORANGE_MONEY_GN_INTEGRATION_CONTRACT.md` : contrat interne fournisseur-neutre, éléments officiels confirmés, questions à Orange Guinée, pipeline webhook et matrice de tests sandbox. Aucun endpoint ni mécanisme cryptographique fournisseur n'est supposé.
