# B-OUI — Checkout invité et multi-catégories V1

## Décision de conception

Le checkout V1 accepte deux profils d'acheteurs :
- acheteur connecté : la réservation est rattachée à son profil authentifié ;
- acheteur invité : aucun compte n'est créé et `buyer_user_id` reste NULL.

Dans les deux cas, le nom et le téléphone au format international E.164 sont obligatoires. L'adresse e-mail est facultative. Le téléphone fourni n'est pas considéré comme vérifié par cette seule saisie.

## Panier

- Une commande porte sur un seul événement.
- Elle peut contenir plusieurs catégories de billets.
- Quantité totale maximale : 10 billets par commande.\n- Durée de réservation temporaire fixe en V1 : 10 minutes.
- Les lignes répétées d'une même catégorie sont regroupées.
- Le montant est recalculé côté base depuis les prix actuels des catégories ; aucun prix envoyé par le navigateur n'est accepté.
- Les quotas de toutes les catégories sont verrouillés dans l'ordre UUID croissant, contrôlés puis réservés dans la même transaction.
- La clé d'idempotence est globale et sa réutilisation avec un autre acheteur, contact ou panier est rejetée.

## Sécurité et limites à traiter avant lancement

La migration ajoute `create_checkout_reservation(jsonb,uuid,text,text,text,integer)` sans modifier ni supprimer l'ancienne fonction `create_reservation`. Elle est appelable par anon et authenticated ; elle ne donne pas de droits de lecture directs sur les réservations.

Le parcours invité nécessite encore, avant exposition publique :
1. une protection anti-abus et anti-robot au niveau edge/API (limitation par IP/téléphone, challenge adapté, quotas) ;
2. une politique de conservation et de minimisation des données personnelles ;
3. un parcours sécurisé de consultation/récupération de réservation et de billet, avec vérification OTP et réponses ne révélant pas l'existence d'une commande ;
4. une couche backend pour créer les paiements et communiquer avec le fournisseur ;
5. une validation du contrat officiel Orange Money Guinée.

La saisie d'un numéro ne prouve pas que l'acheteur en est propriétaire. Aucun billet ni QR code ne doit être émis sur la seule base de la création d'une réservation.

## Paiement et émission

Cette migration ne crée aucun paiement, n'appelle aucun fournisseur et n'émet aucun billet. Le cycle existant de confirmation serveur vérifiée reste la seule voie d'émission. Les paiements tardifs ou ambigus restent soumis à revue.

## Validation

Les contrats SQL et tests runtime sont exécutés sur Supabase/PostgreSQL local par GitHub Actions. Cette évolution n'est pas appliquée à une base distante et n'autorise aucun paiement réel.
