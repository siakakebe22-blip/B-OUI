# B-OUI

Billetterie des événements scolaires en Guinée.

## État du dépôt
La branche `feature/fondations-techniques-v1` contient les premiers documents de cadrage technique et une migration PostgreSQL de fondation.

- `docs/ARCHITECTURE.md` : architecture cible, flux, sécurité et ordre de livraison.
- `supabase/migrations/0001_core_schema.sql` : tables, contraintes, index et activation RLS.
- `supabase/migrations/0002_atomic_reservations.sql` : réservation transactionnelle, idempotence et expiration des quotas.
- `supabase/migrations/0003_verified_payment_and_ticket_issuance.sql` : confirmation privée d'un paiement préalablement vérifié par le backend, conversion atomique des quotas, émission idempotente et audit.
- `supabase/tests/0001_schema_contract.sql`, `0002_reservation_security.sql` et `0003_payment_issuance_security.sql` : contrats structurels et permissions.

## Attention
La migration est une base de travail, pas une version certifiée production. Elle n'a pas été exécutée contre PostgreSQL/Supabase dans cette livraison. Elle ne doit pas être appliquée à une base de production. La réservation atomique, l'expiration et le noyau SQL de confirmation/émission sont spécifiés dans les migrations 0002 et 0003, mais aucune de ces migrations n'a encore été exécutée ni validée sur PostgreSQL. La vérification cryptographique du webhook et l'adaptateur Orange Money restent à implémenter côté backend. Les fonctions de scan et de récupération, ainsi que les tests d'intégration RLS multi-utilisateurs et de concurrence, restent à réaliser.

Aucun projet cloud, secret, compte marchand ou donnée réelle n'est créé ici.
