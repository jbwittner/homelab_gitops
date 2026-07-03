#!/bin/bash

# Remplacez par l'URL ou l'IP de votre cible (http ou https)
TARGET_URL="https://forgejo.wittnerlab.com"

echo "🚀 Lancement du scan HTTP malveillant vers $TARGET_URL..."

# Nous envoyons 50 requêtes rapides pour déclencher le scénario http-probing ou http-bad-user-agent
for i in {1..50}; do
    echo "Requête $i/50 (Tentative d'accès à des fichiers sensibles)..."
    
    # On utilise curl en mode silencieux (-s) et on ignore la sortie (-o /dev/null).
    # L'argument -A "Nuclei" simule l'identité d'un outil de hack bien connu.
    curl -s -k -o /dev/null -A "Nuclei" "$TARGET_URL/.env.backup.$i"
    
    # Petite pause pour imiter un outil automatisé sans pour autant spammer aveuglément
    sleep 0.2
done

echo ""
echo "✅ Attaque terminée."
echo "Testez le résultat en ouvrant $TARGET_URL dans votre navigateur web."
echo "Si la page charge indéfiniment ou renvoie une erreur de connexion, le Bouncer vous a bloqué !"