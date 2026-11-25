# B-OUI

Billetterie des événements scolaires en Guinée.

## État du dépôt
La branche `feature/fondations-techniques-v1` contient les premiers documents de cadrage technique et une migration PostgreSQL de fondation.

- `docs/ARCHITECTURE.md` : architecture cible, flux, sécurité et ordre de livraison.
- `supabase/migrations/0001_core_schema.sql` : tables, contraintes, index et activation RLS.
- `supabase/migrations/0002_atomic_reservations.sql` : réservation transactionnelle, idempotence et expiration des quotas.
- `supabase/tests/0001_schema_contract.sql` et `0002_reservation_security.sql` : contrats structurels et permissions.

## Attention
La migration est une base de travail, pas une version certifiée production. Elle n'a pas été exécutée contre PostgreSQL/Supabase dans cette livraison. Elle ne doit pas être appliquée à une base de production. La réservation atomique et l'expiration sont spécifiées dans la migration 0002, mais elles ne sont pas encore exécutées ni validées sur PostgreSQL. Les fonctions de confirmation de paiement, émission, scan et récupération, ainsi que les tests d'intégration RLS multi-utilisateurs, restent à réaliser.

Aucun projet cloud, secret, compte marchand ou donnée réelle n'est créé ici.
