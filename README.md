# B-OUI

Billetterie des événements scolaires en Guinée.

## État du dépôt
La branche `feature/fondations-techniques-v1` contient les premiers documents de cadrage technique et une migration PostgreSQL de fondation.

- `docs/ARCHITECTURE.md` : architecture cible, flux, sécurité et ordre de livraison.
- `supabase/migrations/0001_core_schema.sql` : tables, contraintes, index et activation RLS.

## Attention
La migration est une base de travail, pas une version certifiée production. Elle n'a pas été exécutée contre PostgreSQL/Supabase dans cette livraison. Elle ne doit pas être appliquée à une base de production. Les fonctions transactionnelles de réservation, paiement, émission, scan et récupération ainsi que les tests RLS restent à réaliser.

Aucun projet cloud, secret, compte marchand ou donnée réelle n'est créé ici.
