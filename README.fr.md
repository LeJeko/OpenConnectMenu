# OpenConnectMenu

**Français** · [English](README.md)

Une app de barre de menus macOS qui se connecte à un VPN avec **[openconnect](https://www.infradead.org/openconnect/)**, et ne redemande plus jamais de mot de passe administrateur après la configuration initiale. Elle gère tous les protocoles d'openconnect (Cisco AnyConnect / ocserv, Juniper, GlobalProtect, Pulse, F5, Fortinet, Array) ; AnyConnect est le seul qui a été testé.

- Connexion et déconnexion en un clic depuis la barre de menus. `openconnect` calcule tout seul le code TOTP à 6 chiffres.
- Le mot de passe et le secret TOTP sont stockés dans le Trousseau.
- Un petit assistant privilégié (un LaunchDaemon exécuté en root) fait le travail qui demande les droits administrateur, et ne répond qu'à l'app signée.
- Icône de la barre de menus : cadenas fermé (connecté) · cadenas barré (déconnecté) · cadenas avec flèche circulaire (opération en cours).
- Anglais et français, selon la langue du système.
- Configurable par un profil de configuration macOS (installation manuelle ou MDM).

## Sommaire

1. [Installation](#installation)
2. [Premier lancement](#premier-lancement)
3. [Utilisation quotidienne](#utilisation-quotidienne)
4. [Profil de configuration (MDM)](#profil-de-configuration-mdm)
5. [Fonctionnement](#fonctionnement)
6. [Modèle de sécurité](#modèle-de-sécurité)
7. [Compiler depuis les sources](#compiler-depuis-les-sources)
8. [Langues](#langues)
9. [Dépannage](#dépannage)
10. [Désinstallation](#désinstallation)
11. [Organisation du projet](#organisation-du-projet)
12. [Limites et problèmes connus](#limites-et-problèmes-connus)
13. [Licence](#licence)

## Installation

### Avec Homebrew (recommandé)

```bash
brew install --cask LeJeko/openconnectmenu/openconnectmenu
```

Cela installe le paquet signé et notarisé et, comme dépendance, la formule `openconnect`. Mise à jour : `brew upgrade --cask openconnectmenu`.

### Avec le paquet d'installation

Téléchargez `OpenConnectMenu-<version>.pkg` depuis la page des [Releases](../../releases) et ouvrez-le. `openconnect` doit être installé à part (`brew install openconnect`) ; l'installateur vous avertit s'il ne le trouve pas.

### Prérequis

- macOS 13 ou plus récent, sur **Apple silicon et Intel** (binaire universel).
- [Homebrew](https://brew.sh) avec `openconnect`.
- Un serveur VPN qui parle l'un des protocoles gérés par **openconnect** (AnyConnect / ocserv, Juniper Network Connect, Palo Alto GlobalProtect, Pulse Connect Secure, F5 BIG-IP, Fortinet FortiGate, Array Networks) et authentifie par identifiant, mot de passe et code **TOTP**. Seul AnyConnect a été testé : voir les [Limites](#limites-et-problèmes-connus).

## Premier lancement

À faire une seule fois.

1. **Autoriser l'assistant.** Au premier lancement, l'app enregistre son assistant et macOS affiche une notification. Allez dans **Réglages Système → Général → Éléments de connexion et extensions** et activez l'assistant *OpenConnectMenu*. Le menu propose aussi *Ouvrir Éléments de connexion…*.
2. **Approuver openconnect.** Le menu affiche « openconnect n'a pas encore été approuvé ». Cliquez sur **Approuver openconnect…**, vérifiez le chemin et la version, puis saisissez votre mot de passe administrateur. C'est le seul mot de passe administrateur qu'on vous demandera. Voir [Épinglage des binaires](#épinglage-des-binaires).
3. **Renseigner les réglages.** Menu → **Réglages…** :

| Champ | Valeur |
|---|---|
| Adresse | Le serveur VPN, `https://…` (obligatoire) |
| Protocole | Le protocole du VPN, `Cisco AnyConnect / ocserv` par défaut (voir la liste ci-dessus) |
| Groupe d'authentification | Le groupe de connexion de votre profil VPN (facultatif ; son sens dépend du protocole) |
| User-Agent | Facultatif. Laissé vide, openconnect utilise celui qui convient au protocole. |
| Identifiant | Votre identifiant VPN |
| Mot de passe | Votre mot de passe VPN (stocké dans le Trousseau) |
| Secret TOTP | Clé Base32 seule, `base32:…`, ou l'URL `otpauth://…` complète (stocké dans le Trousseau) |

Le secret est normalisé : les espaces sont retirés, les lettres passées en majuscules, et le préfixe `base32:` ainsi que les URL `otpauth://` sont acceptés.

### Obtenir le secret TOTP

Le secret n'est affiché qu'une fois, quand vous enrôlez une nouvelle app d'authentification auprès du fournisseur d'identité de votre VPN (cherchez « impossible de scanner le QR code ? » ou « saisir la clé manuellement »). Les étapes exactes dépendent du fournisseur.

- Si le secret est déjà dans l'app **Mots de passe** d'Apple, ouvrez l'entrée, cliquez sur le champ du code de vérification, puis sur **Copy Setup URL**, et collez l'URL dans les réglages. Le même secret produit alors les mêmes codes aux deux endroits : pas besoin de nouvelle méthode.
- La plupart des apps d'authentification ne peuvent pas révéler le secret d'une entrée existante. Notez-le au moment de l'enrôlement.

Ne collez jamais ce secret dans une conversation ou un terminal partagé : il équivaut à votre second facteur. S'il a été exposé, supprimez cette méthode dans les réglages de sécurité de votre compte et enrôlez-en une nouvelle.

## Utilisation quotidienne

| Entrée du menu | Effet |
|---|---|
| Se connecter / Se déconnecter | Aucun mot de passe demandé. Une alerte signale un échec. |
| Adresse, Depuis | L'adresse IP du tunnel et la durée de connexion. |
| openconnect n'est pas installé | Affiché avant tout autre état si `openconnect` est introuvable. **Copier la commande d'installation…** copie `brew install openconnect`. |
| Assistant injoignable → Réparer l'assistant… | Affiché quand macOS indique que l'assistant est activé mais qu'il ne répond pas. Voir [Dépannage](#dépannage). |
| Réglages… | La fenêtre des réglages. |
| Voir le journal | Ouvre `/Library/Logs/OpenConnectMenu.log` (sortie d'openconnect, sans secret). |
| Ouvrir au démarrage | Lance l'app à l'ouverture de session. |
| Désinstaller l'assistant | Retire l'enregistrement de l'assistant. |
| Quitter | Quitte l'app. Un VPN connecté reste actif. |

La connexion prend une dizaine de secondes ; la déconnexion, quelques secondes.

## Profil de configuration (MDM)

Une organisation peut imposer les réglages du serveur avec un **profil de configuration macOS** (`.mobileconfig`), installé à la main ou déployé par un MDM. macOS range les valeurs dans le domaine de préférences de l'app (son identifiant de bundle), et l'app affiche les champs imposés grisés, avec une note.

Clés imposables (toutes facultatives, de type chaîne) :

| Clé | Signification |
|---|---|
| `server` | Adresse du VPN, `https://…` |
| `protocol` | `anyconnect`, `nc`, `gp`, `pulse`, `f5`, `fortinet` ou `array` |
| `authgroup` | Groupe d'authentification |
| `useragent` | User-Agent |
| `username` | Identifiant |

Le mot de passe et le secret TOTP ne sont jamais imposés : ils sont personnels et restent dans le Trousseau de chacun.

**Générer un profil.** `build.sh` impose `server`, `protocol`, `authgroup` et `useragent` (renseignez `VPN_SERVER`, `VPN_PROTOCOL`, `VPN_AUTHGROUP`, `VPN_USERAGENT` ; un champ laissé vide n'est pas imposé). Créez `profiles/<nom>.env` à partir de [`profiles/example.env`](profiles/example.env), puis :

```bash
PROFILE=<nom> ./build.sh mobileconfig      # → dist/OpenConnectMenu-<nom>.mobileconfig
```

Le profil est de portée système, avec le type de payload `com.apple.ManagedClient.preferences`. Il n'est **pas signé** : macOS le signale à l'installation manuelle, et un MDM le re-signe. Les profils de `profiles/` autres que l'exemple sont ignorés par git.

Pour imposer aussi `username`, ou pour écrire le profil à la main ou dans un MDM, utilisez un payload *Custom Settings* / `com.apple.ManagedClient.preferences` dont le domaine est l'identifiant de bundle de l'app et dont les réglages forcés sont les clés ci-dessus.

Vérifier ce que macOS a appliqué (le fichier n'existe que tant que le profil est installé) :

```bash
plutil -p "/Library/Managed Preferences/<bundle-id>.plist"
```

## Fonctionnement

```
┌──────────────────────┐   XPC (vérifié par signature)   ┌────────────────────────────┐
│ OpenConnectMenu.app  │ ──────────────────────────────▶ │ assistant (LaunchDaemon,   │
│ barre de menus       │ ◀────────────────────────────── │ root)                      │
│ réglages, Trousseau  │                                 │  · lance openconnect       │
└──────────────────────┘                                 │  · démonte le tunnel       │
                                                         │  · épingle les binaires    │
                                                         └─────────────┬──────────────┘
                                                                       │
                                                          openconnect + vpnc-script
                                                          (Homebrew, /opt/homebrew)
```

- **L'app** (sans icône dans le Dock) affiche l'état, lit vos réglages et envoie les commandes à l'assistant.
- **L'assistant** est enregistré avec `SMAppService.daemon` : macOS le lance à la demande, en root. Il n'accepte que les connexions XPC de l'app signée par l'équipe du build (`setConnectionCodeSigningRequirement`), et l'app ne parle qu'à un assistant signé par la même équipe.
- **Connexion** : l'assistant écrit une configuration temporaire lisible par root seul (elle contient le secret TOTP), lance `openconnect` en lui passant le mot de passe sur l'entrée standard, attend que le tunnel monte (40 s au plus), puis supprime la configuration.
- **Déconnexion** : voir les [Limites](#limites-et-problèmes-connus). `openconnect` ne réagit pas aux signaux sur le macOS testé, l'assistant rejoue donc le nettoyage à la main.
- **État** : le tunnel est détecté comme l'interface `utun` dont l'adresse IPv4 pointe sur elle-même (`inet A --> A`). La plage attribuée par le serveur varie ; rien n'est codé en dur.
- **Mises à jour** : le script `postinstall` de l'installateur relance l'assistant et rouvre l'app. Si macOS indique un jour que l'assistant est activé alors qu'il ne répond pas (par exemple après `brew upgrade`, qui retire puis réinstalle le service), l'app le réenregistre toute seule au bout d'une quinzaine de secondes, une seule fois, sauf si un VPN était actif.

## Modèle de sécurité

- **Assistant root et XPC.** L'assistant ne répond qu'à l'app signée : exigence `anchor apple generic` + identifiant + `certificate leaf[subject.OU]` égal à l'identifiant d'équipe. Sans signature valide, la connexion est refusée.
- **Entrées validées.** L'assistant valide chaque champ reçu (pas de caractère de contrôle, `https://` obligatoire, secret TOTP en Base32, protocole pris dans une liste fermée) et construit lui-même la configuration et la ligne de commande. Rien de ce qui vient de l'app n'est exécuté tel quel.
- **Secrets.** Le mot de passe et le secret TOTP vivent dans le Trousseau. Côté assistant, le mot de passe passe par l'entrée standard, et le secret TOTP n'existe que dans une configuration temporaire `0600` lisible par root, supprimée dès que la connexion est établie ou a échoué.
- **Journal.** Lisible par l'utilisateur (`0644`) ; il contient la sortie d'openconnect, pas les secrets.
- **Profil de configuration.** Il ne porte aucun secret. Un champ imposé ne peut pas être modifié depuis l'app.

### Épinglage des binaires

`openconnect` et `vpnc-script` se trouvent dans `/opt/homebrew`, un dossier que votre compte peut modifier. Un assistant qui exécuterait sans contrôle ce qu'il y trouve donnerait à tout programme lancé sous votre compte un moyen de faire exécuter du code en root, sans aucune demande. C'est pourquoi :

- à l'approbation, l'assistant enregistre le **SHA-256** d'`openconnect` et de `vpnc-script` dans `/Library/Application Support/OpenConnectMenu/trust.json` (propriété de root) ;
- avant chaque connexion, il recalcule les empreintes et **refuse** de lancer quoi que ce soit si elles ont changé ;
- après un `brew upgrade openconnect`, le menu redemande **Approuver openconnect…** (mot de passe administrateur, vérifié par l'assistant via Authorization Services).

**Limites** : les bibliothèques Homebrew qu'openconnect charge (GnuTLS, etc.) ne sont pas vérifiées, et une course théorique subsiste entre le contrôle et le lancement. C'est un garde-fou, pas une isolation complète.

## Compiler depuis les sources

Il faut les outils en ligne de commande de Xcode (`xcode-select --install` ; Xcode complet inutile) et, pour exécuter l'app, une inscription à l'Apple Developer Program : l'assistant est enregistré avec `SMAppService`, qui exige une vraie signature, et la connexion XPC entre l'app et l'assistant est vérifiée par rapport à votre identifiant d'équipe. **Chacun compile et signe sa propre copie.**

### Configurer

```bash
cp config.env.example config.env     # ignoré par git : ces valeurs vous sont propres
```

Modifiez `config.env` :

| Variable | Obligatoire | Signification |
|---|---|---|
| `TEAM_ID` | oui | Votre identifiant d'équipe Apple (10 caractères) |
| `BUNDLE_ID` | oui | Identifiant de bundle en notation DNS inversée, ex. `com.example.OpenConnectMenu`. Ceux de l'assistant (`<BUNDLE_ID>.helper`) et du paquet (`<BUNDLE_ID>.pkg`) en sont déduits. |
| `IDENTITY`, `INSTALLER_IDENTITY` | non | Identités de signature. Par défaut, `build.sh` retrouve dans le Trousseau les certificats *Developer ID Application* et *Developer ID Installer* de votre équipe, et s'arrête s'il n'y en a aucun ou plusieurs. |
| `NOTARY_PROFILE` | non | Un profil `notarytool`. Sans lui, le paquet est signé mais pas notarisé. |

Toute variable peut aussi être passée par l'environnement, qui prime sur le fichier.

### Compiler

```bash
./build.sh              # compile, assemble et signe (sortie hors du dossier source)
./build.sh install      # idem, puis installe dans /Applications et lance l'app
./build.sh pkg          # idem, puis fabrique un .pkg signé dans dist/
./build.sh mobileconfig # profil de configuration, voir plus haut
```

| Sujet | Explication |
|---|---|
| Dossier de sortie | `~/Library/Caches/OpenConnectMenu/build`. Le build compile une copie des sources à cet endroit : un dossier synchronisé (iCloud Drive…) ne peut pas le perturber. |
| Architectures | `arm64` et `x86_64` par défaut, fusionnées avec `lipo` en un binaire universel. `ARCHS=arm64 ./build.sh` donne un build plus rapide, Apple silicon seulement. |
| Build ad hoc | `IDENTITY=- NO_TIMESTAMP=1 ./build.sh build` compile avec une signature ad hoc et sans certificat, ce qui suffit à vérifier que le projet se compile. Il n'est pas fait pour être exécuté : l'assistant exige une vraie signature d'équipe. |
| Sortie du paquet | `DIST=<dossier> ./build.sh pkg` (défaut `./dist`). Un paquet de même version écrase le précédent. |
| Première signature | macOS demande l'accès à votre clé privée : choisissez **Toujours autoriser**, sinon `codesign` attend indéfiniment. |
| Garde-fous | Le build refuse les valeurs d'exemple, les identifiants mal formés et un certificat manquant avant de compiler quoi que ce soit, et échoue si un marqueur de modèle n'est pas remplacé. |

### Le paquet d'installation

`./build.sh pkg` compile et signe l'app et l'assistant (runtime renforcé), prépare le contenu, construit le paquet composant avec `pkgbuild`, assemble le paquet final avec `productbuild` (écran d'accueil, textes localisés, vérification préalable d'`openconnect`) et le signe avec un horodatage, puis vérifie la signature, le contenu, les architectures et la signature de l'app extraite.

- L'app atterrit toujours dans `/Applications` (elle n'est **pas relocalisable**) et remplace une version identique ou plus ancienne.
- `pkg-scripts/preinstall` retient si l'app tournait, puis la ferme. `pkg-scripts/postinstall` relance l'assistant et rouvre l'app (y compris quand le paquet est réinstallé, comme le fait `brew upgrade`).
- Le paquet liste des entrées `._*` : c'est l'attribut `com.apple.provenance` ajouté par macOS, pas de vrais fichiers.

### Notarisation

Sans `NOTARY_PROFILE`, Gatekeeper rejette le paquet sur un autre Mac (« Unnotarized Developer ID »). Pour notariser, créez une fois un profil :

```bash
xcrun notarytool store-credentials "mon-profil" --apple-id "<votre Apple ID>" --team-id <TEAM_ID>
```

Il demande un **mot de passe d'app** (généré sur <https://account.apple.com> → Connexion et sécurité). Votre mot de passe habituel est refusé. Ensuite :

```bash
NOTARY_PROFILE=mon-profil ./build.sh pkg
```

Le script envoie le paquet, attend le verdict et lit le **statut** (pas seulement le code de retour). S'il n'est pas `Accepted`, il affiche le journal d'Apple et s'arrête. Sinon il agrafe le ticket et vérifie Gatekeeper. Chaque exécution envoie le paquet à Apple : réservez-la à une version que vous comptez diffuser.

### Icône

L'icône (un tunnel rouge : trois arches concentriques et une lumière au fond) est dessinée en code dans `Icon/make-icon.swift` (CoreGraphics, sans dépendance) :

```bash
swift Icon/make-icon.swift Icon
iconutil -c icns Icon/AppIcon.iconset -o App/AppIcon.icns
```

L'icône de la barre de menus est construite avec des symboles système et s'adapte aux modes clair et sombre.

## Langues

L'interface et l'installateur existent en **anglais** (par défaut) et en **français**. Le français est utilisé s'il arrive en premier parmi les langues préférées du système que l'app gère.

- Les textes sont écrits **en anglais dans le code**, et le texte anglais sert de clé : `L("Connect")` dans `App/`, littéraux simples dans les vues SwiftUI. Les traductions sont dans `App/Resources/{en,fr}.lproj/Localizable.strings`.
- **L'assistant ne traduit rien.** Il tourne en root et ignore la langue de l'utilisateur : il renvoie des **codes** (`oc_exited`, `timeout`, `oc_not_approved`…), éventuellement suivis d'un détail brut. L'app les traduit (`HelperText` dans `App/L10n.swift`).
- Les traductions de l'installateur sont dans `pkg-resources/{en,fr}.lproj/`, avec une copie anglaise à la racine comme repli.
- Le journal est la sortie d'openconnect : il est en anglais.

**Ajouter ou modifier un texte** : écrivez la phrase anglaise dans le code, puis ajoutez la même clé aux deux fichiers `Localizable.strings` (les paramètres comme `%@` doivent correspondre). Une clé manquante s'affiche en anglais.

**Ajouter une langue** : créez `App/Resources/<langue>.lproj/Localizable.strings`, ajoutez la langue à `CFBundleLocalizations` dans `App/Info.plist`, et ajoutez `pkg-resources/<langue>.lproj/` pour l'installateur.

## Dépannage

| Symptôme | À essayer |
|---|---|
| « Assistant non activé » | Cliquez sur « Activer l'assistant… ». Si l'app n'est pas dans `/Applications`, l'enregistrement peut échouer. |
| « Assistant à autoriser » | Activez-le dans Réglages Système → Éléments de connexion et extensions. |
| « Assistant injoignable » | Le service est enregistré mais ne répond pas. L'app le répare toute seule au bout d'une quinzaine de secondes ; sinon, utilisez **Réparer l'assistant…**. |
| « openconnect n'a pas encore été approuvé » ou « a changé » | Normal au premier lancement et après une mise à jour Homebrew : « Approuver openconnect… ». |
| « openconnect n'est pas installé » | **Copier la commande d'installation…**, lancez-la dans le Terminal, puis rouvrez le menu. |
| « openconnect (ou son vpnc-script) est introuvable » | Installation incomplète : `brew reinstall openconnect`. |
| La connexion échoue | Ouvrez le journal. Vérifiez l'identifiant, le mot de passe et que le secret TOTP est le bon, en Base32. |
| `Invalid base32 token string` | Le secret TOTP est faux ou mal saisi. Saisissez-le à nouveau. |
| Des champs des réglages sont grisés | Un profil de configuration les impose. Retirez le profil dans Réglages Système pour les modifier. |
| Aucune recherche d'assistant n'aboutit, rien ne s'enregistre | Le démon des éléments d'arrière-plan de macOS est peut-être bloqué : `sudo killall backgroundtaskmanagementd`, ou redémarrez. |
| `is not a recognized network service` dans le journal | Sans gravité : `vpnc-script` cherche un service réseau pour l'interface `utun` ; le DNS est appliqué autrement. |

Vérifications en ligne de commande :

```bash
pgrep -l openconnect                                   # openconnect tourne-t-il ?
ifconfig | grep -B1 -A2 -- '-->'                       # interface du tunnel
route -n get default | egrep 'gateway|interface'       # route par défaut
scutil --dns | head -12                                # DNS actif
tail -n 30 /Library/Logs/OpenConnectMenu.log           # journal
```

## Désinstallation

Avec Homebrew : choisissez d'abord **Désinstaller l'assistant** dans le menu (pour que macOS oublie aussi l'élément d'arrière-plan), puis :

```bash
brew uninstall --cask openconnectmenu          # ajoutez --zap pour supprimer aussi réglages et journaux
```

À la main :

1. Menu → **Désinstaller l'assistant**, puis **Quitter**.
2. `rm -rf /Applications/OpenConnectMenu.app`
3. Nettoyage facultatif (`<bundle-id>` est l'identifiant de votre build ; la version officielle utilise `ch.jeko.OpenConnectMenu`) :

   ```bash
   sudo rm -rf "/Library/Application Support/OpenConnectMenu" /Library/Logs/OpenConnectMenu.log
   defaults delete <bundle-id>
   security delete-generic-password -s <bundle-id> -a password
   security delete-generic-password -s <bundle-id> -a totp
   ```

## Organisation du projet

```
.
├── build.sh               Compilation, assemblage, signature, installation, .pkg, notarisation, profil de configuration
├── config.env.example     Modèle de votre config.env local (TEAM_ID, BUNDLE_ID…)
├── profiles/
│   └── example.env        Modèle de profil de configuration
├── Icon/                  make-icon.swift, aperçu et iconset
├── pkg-scripts/           preinstall, postinstall
├── pkg-resources/         Écran d'accueil et textes de l'installateur (en, fr, repli anglais)
├── pkg-distribution.xml.in
├── Shared/Shared.swift    Constantes, exigences de signature, types et protocole XPC
├── App/                   App de barre de menus : menu, client XPC, réglages, traductions
└── Helper/                Assistant privilégié : écoute XPC, validation des demandes, connexion/déconnexion, épinglage SHA-256
```

Le bundle obtenu :

```
OpenConnectMenu.app/Contents/
├── Info.plist
├── MacOS/OpenConnectMenu                         l'app
├── MacOS/<bundle-id>.helper                      l'assistant
├── Resources/                                    icône et traductions
└── Library/LaunchDaemons/<bundle-id>.helper.plist
```

Les identifiants (`@BUNDLE_ID@`, `@HELPER_LABEL@`, `@PKG_ID@`, `@TEAM_ID@`) sont des marqueurs dans les plists, scripts et modèle de distribution, remplacés à partir de `config.env` sur une copie de travail lors du build. `Shared.swift` les lit dans un `BuildConfig.swift` généré.

## Limites et problèmes connus

- **`openconnect` ne réagit à aucun signal** (TERM, INT et USR1 ont été testés) sur macOS 27.2 bêta avec openconnect 9.21, alors que le noyau indique qu'il les intercepte. La cause n'est pas établie. La déconnexion fonctionne donc ainsi :
  1. `SIGTERM`, attente de 2 s (utile si le défaut disparaît un jour) ;
  2. sinon, exécution de `vpnc-script` avec `reason=disconnect` pour restaurer la route par défaut et le DNS sauvegardés, puis `SIGKILL` du processus ;
  3. suppression des routes d'exclusion ajoutées par la passerelle d'origine.
- **Nettoyage manuel** : si l'assistant est interrompu en plein nettoyage, des routes d'exclusion ou des réglages DNS peuvent rester en place. Couper puis rallumer le réseau remet tout à zéro.
- **Un seul VPN à la fois** : la détection du tunnel suppose qu'aucune autre interface `utun` n'a une adresse IPv4 point à point pointant sur elle-même.
- **Seul AnyConnect est testé.** Le réglage de protocole propose les sept protocoles d'openconnect, et l'assistant vérifie qu'openconnect les accepte, mais aucune connexion n'a été essayée avec autre chose qu'un serveur AnyConnect. Le déroulement de l'authentification et le sens du « groupe d'authentification » diffèrent selon les protocoles : attendez-vous à des aspérités, et signalez-les.
- **Le TOTP est obligatoire** : l'assistant configure toujours openconnect avec un jeton TOTP. Les autres seconds facteurs ne sont pas gérés.
- **Homebrew uniquement** : `openconnect` est cherché dans `/opt/homebrew` (Apple silicon), puis `/usr/local` (Intel).
- **La moitié Intel n'est pas testée** : la tranche `x86_64` compile, est signée et passe les contrôles `lipo`/`codesign`, mais n'a jamais été exécutée. À ma connaissance, macOS 26 est la dernière version qui gère les Mac Intel : cette tranche vise macOS 13 à 26.
- **Testé** sur Apple silicon avec macOS 27 (bêta), y compris `brew upgrade` et un profil de configuration installé à la main, face à un serveur AnyConnect. Pas testé avec un MDM, avec un autre protocole, ni sur un second Mac vierge.

## Licence

[MIT](LICENSE). `openconnect` est un programme à part (LGPL) que l'assistant lance ; il ne fait pas partie de ce projet.
