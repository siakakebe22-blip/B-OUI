# B-OUI

Billetterie des événements scolaires en Guinée.

## État actuel

Le dépôt contient une première fondation PostgreSQL, un flux de réservation transactionnel et un point d'entrée serveur en préparation pour le checkout invité et connecté.

- Interface publique de démonstration : https://b-oui.pages.dev
- Architecture cible : `docs/ARCHITECTURE.md`
- Contrat de checkout invité / panier multi-catégories : `docs/CHECKOUT_INVITE_MULTI_CATEGORIES_V1.md`
- Edge Function checkout : `supabase/functions/create-checkout-reservation/index.ts`
- Validateurs et tests Deno : `supabase/functions/create-checkout-reservation/validation.ts` et `validation_test.ts`
- Configuration locale : `supabase/config.toml`
- Configuration et prérequis du checkout : `docs/CHECKOUT_EDGE_FUNCTION_V1.md`
- Contrat d'intégration Orange Money Guinée : `docs/ORANGE_MONEY_GN_INTEGRATION_CONTRACT.md`

## Sécurité du checkout

Le navigateur ne reçoit jamais la clé `service_role`. Les acheteurs connectés sont identifiés à partir d'un JWT validé par Supabase Auth. Les acheteurs invités doivent fournir une preuve Cloudflare Turnstile vérifiée côté serveur. La base recalcule les prix, limite le panier à un seul événement et dix billets, réserve les quotas de manière atomique et utilise une clé d'idempotence.

La création d'une réservation ne crée pas de paiement et n'émet aucun billet. Les billets et QR codes ne peuvent être émis qu'après confirmation serveur d'un paiement réellement vérifié.

## Tests

Les migrations et contrats SQL sont exécutés sur une instance Supabase/PostgreSQL locale éphémère dans GitHub Actions. Les tests runtime couvrent les réservations concurrentes, l'idempotence des paiements, le cycle des webhooks, le checkout invité/multi-catégories et l'isolation entre écoles. Deno vérifie le formatage, le lint, les validateurs et les types de l'Edge Function.

## Limites avant lancement

- L'Edge Function n'est pas déployée et ses secrets ne sont pas configurés.
- Une limitation de débit persistante et des tests d'intégration Edge Runtime restent obligatoires avant exposition publique.
- L'adaptateur réseau Orange Money Guinée dépend de la documentation officielle du contrat marchand et de son sandbox.
- Aucun paiement réel, aucune migration distante et aucune donnée de production ne sont activés par les tests locaux.

Ce dépôt décrit une base en développement, pas une plateforme certifiée prête pour les transactions commerciales.
