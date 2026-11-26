# B-OUI — Contrat d'intégration Orange Money Guinée

## Statut et règle de prudence

Document de conception uniquement. Aucun endpoint Orange Money, identifiant marchand, secret, webhook réel ou environnement sandbox n'est configuré par ce document.

La documentation publique Orange Developer confirme l'existence de l'offre Orange Money Web Payment / M Payment en Guinée (Conakry), destinée aux marchands Orange Money enregistrés et conformes aux exigences KYA. Elle indique que le client valide le paiement par un mécanisme OTP Orange Money. Elle ne fournit pas, dans ses pages publiques générales, le contrat technique propre au compte marchand guinéen : URLs exactes, authentification, signature des notifications, champs, statuts, délais, annulation et rapprochement doivent être obtenus auprès d'Orange Guinée ou du partenaire d'intégration agréé.

Sources officielles consultées :
- https://developer.orange.com/apis/om-webpay
- https://developer.orange.com/apis/om-webpay/faq

Ne pas reprendre automatiquement les exemples ou endpoints Orange d'un autre pays (notamment Orange Sonatel/Sénégal). Le pays, le produit marchand et le contrat remis au marchand doivent correspondre à la Guinée.

## 1. Éléments confirmés et éléments à obtenir

### Confirmés par Orange Developer (information publique)
- L'offre Web Payment / M Payment est disponible en Guinée Conakry.
- Elle est réservée aux marchands Orange Money enregistrés et conformes KYA.
- Des documents et conditions locales s'appliquent ; le marchand doit se rapprocher de l'opérateur local.
- Le client doit disposer d'un compte Orange Money actif et autoriser le paiement via le parcours OTP décrit par Orange.
- Les tests d'intégration doivent précéder l'activation commerciale.

### À obtenir par écrit d'Orange Guinée
1. Nom exact du produit marchand accessible en Guinée et procédure d'inscription/KYA.
2. Documentation API versionnée et OpenAPI/Postman, si disponible.
3. URL de sandbox et URL de production distinctes.
4. Méthode d'authentification API, durée de vie/renouvellement des jetons et portée des accès.
5. Endpoint et paramètres de création de paiement ; format de référence marchand.
6. Réponse synchrone : identifiant de transaction, statut initial, URL de paiement ou instructions client.
7. Méthode officielle de consultation du statut et règles de polling.
8. Contrat de notification : méthode HTTP, en-têtes, signature, algorithme, canonicalisation, timestamp, tolérance d'horloge, identifiant unique d'événement, politique de rejeu et accusé attendu.
9. Champs de rapprochement garantis : référence marchand, identifiant transaction, montant, devise, statut, compte marchand et horodatage.
10. Liste exhaustive des statuts et transitions, y compris pending, success, failed, cancelled, expired, reversed et refunded si applicables.
11. Délais de notification, politique de retry, ordre des événements et durée de conservation.
12. Limites de montant, frais, délais de règlement, règles de remboursement/annulation et support litiges.
13. Jeux de tests sandbox couvrant succès, échec, expiration, notification répétée, notification retardée, montant erroné et transaction inconnue.
14. Conditions de certification et procédure d'activation production.

Tant que ces éléments ne sont pas obtenus, les détails fournisseur sont marqués TBD et aucun code HTTP, champ JSON, en-tête, algorithme de signature ou statut fournisseur ne doit être inventé.

## 2. Contrat interne B-OUI (indépendant du fournisseur)

Le backend expose une interface interne stable. L'adaptateur Orange traduit le contrat fournisseur vers ce modèle ; le frontend ne communique jamais directement avec Orange.

### Création d'une tentative
Entrée interne :
- reservation_id
- payment_id créé côté serveur
- amount_gnf (entier positif)
- currency = GNF
- merchant_reference unique et non réutilisable
- buyer_phone_e164 si le produit Orange l'exige
- idempotency_key générée côté serveur

Sortie interne :
- payment_id
- provider = orange_money_gn
- provider_reference / transaction_id lorsqu'il existe
- payment_url ou instructions d'autorisation si le produit les retourne
- état normalisé initial
- expires_at si le fournisseur le définit

Règles :
- Le montant et la devise proviennent de la réservation en base, jamais du navigateur.
- La même clé d'idempotence ne crée pas une deuxième demande fournisseur.
- Une référence fournisseur ne peut pas être rattachée à deux paiements B-OUI.
- Les secrets sont conservés dans le gestionnaire de secrets du backend, jamais dans le dépôt ni le frontend.
- Les timeouts réseau donnent un état inconnu/en vérification, jamais un échec présumé. Le backend interroge le statut officiel avant toute nouvelle création.

### États internes
- created : tentative B-OUI créée, demande fournisseur pas encore confirmée.
- awaiting_customer : le fournisseur attend l'autorisation du client.
- pending_verification : réponse ambiguë, timeout ou notification à rapprocher.
- succeeded : succès vérifié par une source serveur authentifiée.
- failed : échec terminal vérifié.
- cancelled : annulation confirmée par le fournisseur.
- expired : expiration confirmée selon les règles fournisseur et réservation.
- review_required : incohérence, paiement tardif, doublon contradictoire ou preuve insuffisante.
- refunded : remboursement confirmé par le fournisseur et rapproché.

Les valeurs Orange réelles doivent être mappées explicitement vers ces états après réception de la documentation. Un statut inconnu est conservé comme inconnu et mis en revue ; il ne devient jamais succeeded par défaut.

## 3. Réception et traitement d'une notification

Pipeline obligatoire :
1. Recevoir le corps brut et les en-têtes sur une route serveur dédiée.
2. Vérifier TLS, méthode, taille maximale, format et authentification/signature exacte selon la documentation Orange Guinée.
3. Vérifier timestamp et protection anti-rejeu si le contrat fournisseur les prévoit.
4. Construire la clé de déduplication selon une garantie documentée : ID d'événement stable de préférence ; à défaut, règle déterministe validée avec Orange. Ne pas supposer qu'un ID existe.
5. Calculer SHA-256 du corps brut avant parsing et enregistrer l'événement dans payment_webhook_events ; ne conserver que les données minimales expurgées.
6. Si événement déjà reçu, ne pas répéter les effets métier ; répondre selon le code d'accusé officiellement exigé.
7. Charger le paiement par référence connue et rapprocher au minimum prestataire, transaction, référence, montant, devise, compte marchand et état.
8. En cas d'incohérence ou de transaction inconnue : review_required, journal d'audit, aucune émission de billet.
9. En cas de succès intégralement vérifié : appeler confirm_verified_payment une seule fois avec les données recalculées côté serveur et les billets préparés côté serveur.
10. Marquer l'événement traité et enregistrer un code de résultat non sensible.

La confirmation SQL et l'émission des billets doivent rester atomiques. Le retour navigateur, une capture d'écran, un SMS du client ou un champ fourni par le frontend ne sont jamais une preuve de paiement.

## 4. Paiements tardifs et cas ambigus

- Un paiement reçu après expiration de la réservation ne réactive pas la réservation et n'émet pas de billet automatiquement.
- Il passe en review_required avec référence, montant, transaction et preuve serveur expurgée.
- Le rapprochement humain décide de la suite selon la convention marchande : remboursement, régularisation autorisée ou autre traitement.
- Une réponse réseau perdue après création fournisseur déclenche une consultation du statut par référence/idempotence ; ne jamais créer une nouvelle transaction à l'aveugle.
- Un même événement avec contenu différent ou une même transaction liée à plusieurs références déclenche une alerte et une revue.
- Les notifications peuvent arriver en retard ou dans le désordre : les transitions d'état doivent être monotones et validées selon les règles officielles, sans rétrograder un paiement confirmé.

## 5. Journalisation et confidentialité

À conserver :
- fournisseur, clé de déduplication, ID événement si disponible, transaction fournisseur, empreinte SHA-256, type d'événement normalisé ;
- dates de réception et de traitement, nombre de tentatives, résultat non sensible ;
- référence paiement/réservation interne et décisions d'audit.

À ne jamais conserver dans les logs :
- secret API, jeton d'accès, code OTP, PIN Orange Money ;
- corps brut contenant des données personnelles non nécessaires ;
- données d'authentification complètes ou en-têtes secrets.

Limiter les accès à service_role/backend, définir une durée de conservation et contrôler les accès administratifs.

## 6. Matrice minimale de recette sandbox

| Scénario | Résultat attendu |
|---|---|
| Paiement réussi, notification valide | Un paiement confirmé et billets émis une seule fois |
| Même notification reçue plusieurs fois | Un seul effet métier |
| Deux notifications distinctes pour la même transaction | Pas de double émission ; déduplication/contrôle transaction |
| Signature absente ou invalide | Rejet, aucune écriture métier ni billet |
| Timestamp hors fenêtre ou rejeu | Rejet selon contrat fournisseur |
| Montant ou devise différents | Mise en revue, aucun billet |
| Mauvaise référence ou compte marchand | Mise en revue, aucun billet |
| Notification d'échec après succès | Aucun retour arrière automatique |
| Notification succès après expiration | Revue manuelle, aucun billet automatique |
| Timeout après création de paiement | Consultation de statut ; pas de seconde création aveugle |
| Statut fournisseur inconnu | Revue, aucune confirmation |
| Deux paiements concurrents pour une réservation | Un seul paiement confirmé et un seul jeu de billets |

Compléter par tests de concurrence PostgreSQL sur création/expiration/confirmation, tests de charge, restauration et audit.

## 7. Critères d'autorisation de mise en production

Aucun passage en production avant :
- contrat technique officiel Guinée reçu et archivé ;
- marchand et accès API approuvés par Orange ;
- secrets séparés sandbox/production et rotation testée ;
- sandbox entièrement réussie avec preuves de tests ;
- tests de signature, anti-rejeu, doublons, montants, statuts, timeouts et concurrence réussis ;
- rapprochement financier et procédure de remboursement/tardif documentés ;
- surveillance, alertes, support et plan de retour arrière validés ;
- autorisation explicite du propriétaire B-OUI.

## Décision actuelle

Le contrat interne B-OUI peut être développé sans dépendre des endpoints Orange. L'adaptateur réseau concret reste bloqué jusqu'à réception de la documentation officielle du produit marchand Orange Money Guinée. Aucune connexion, aucun secret et aucun paiement réel ne sont activés.
