#!/bin/bash
# Compile, assemble et signe OpenConnectMenu.app (app de barre de menu + helper privilégié).
#
#   ./build.sh            compile et signe l'app (sortie dans $BUILD)
#   ./build.sh install    idem, puis installe dans /Applications et lance l'app
#   ./build.sh pkg        idem, puis fabrique un .pkg signé avec écran d'accueil (copié dans dist/)
#                         avec NOTARY_PROFILE : le notarise, agrafe le ticket et vérifie Gatekeeper
#   ./build.sh test       compile et exécute les tests (Tests/) ; ne demande ni config.env ni certificat
#   ./build.sh mobileconfig   fabrique un profil de configuration macOS (.mobileconfig, dans dist/) qui apporte une ou
#                         plusieurs configurations VPN en lecture seule (PROFILE=a,b), à installer à la main
#                         dans Réglages Système ou à déployer par MDM
#
# Configuration : copiez config.env.example en config.env et renseignez TEAM_ID et BUNDLE_ID.
#                 Toute variable de l'environnement prime sur config.env.
#
# Variables : TEAM_ID             identifiant d'équipe Apple (10 caractères)           [obligatoire]
#             BUNDLE_ID           identifiant de bundle de l'app (ex. com.example.X)   [obligatoire]
#             IDENTITY            identité de signature de l'app (défaut : détectée dans le trousseau)
#             INSTALLER_IDENTITY  identité de signature du .pkg (défaut : détectée dans le trousseau)
#             NOTARY_PROFILE      profil notarytool (xcrun notarytool store-credentials) ; sans lui, pas de notarisation
#             CONFIG              chemin d'un autre fichier de configuration (défaut : ./config.env)
#             PROFILE             commande mobileconfig : nom(s) de profils profiles/<nom>.env, séparés par des virgules
#                                 (une configuration par profil ; modèle : profiles/example.env)
#             VPN_NAME, VPN_SERVER, VPN_PROTOCOL, VPN_AUTHGROUP, VPN_USERAGENT, VPN_USERNAME
#                                 réglages imposés (normalement lus dans profiles/<nom>.env ; l'environnement prime)
#             BUILD               dossier de sortie (hors iCloud Drive)
#             DIST                dossier où est copié le .pkg (défaut : ./dist)
#             NO_TIMESTAMP=1      signature hors ligne
#             ARCHS               architectures à compiler (défaut : « arm64 x86_64 », binaire universel)
#                                 ex. ARCHS=arm64 ./build.sh pour un build rapide, natif Apple silicon
#
# Exemple : NOTARY_PROFILE=mon-profil ./build.sh pkg
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

die() { echo "✘ $*" >&2; exit 1; }

# --- Configuration -------------------------------------------------------------------------------
load_config() {
  local file="${CONFIG:-$ROOT/config.env}" v kv
  local -a saved=()
  [ -f "$file" ] || die "Configuration introuvable : $file
  Copiez config.env.example en config.env, puis renseignez TEAM_ID et BUNDLE_ID."
  # Les variables déjà définies dans l'environnement priment sur les fichiers.
  for v in TEAM_ID BUNDLE_ID IDENTITY INSTALLER_IDENTITY NOTARY_PROFILE PROFILE; do
    [ -n "${!v+x}" ] && saved+=("$v=${!v}")
  done
  apply_saved() { for kv in "${saved[@]+"${saved[@]}"}"; do export "${kv%%=*}=${kv#*=}"; done; }
  # shellcheck disable=SC1090
  source "$file"
  apply_saved

  [[ "${TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
    || die "TEAM_ID invalide ou absent dans $file : 10 caractères (lettres majuscules et chiffres) attendus."
  [[ "${BUNDLE_ID:-}" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] \
    || die "BUNDLE_ID invalide ou absent dans $file : notation DNS inversée attendue (ex. com.example.OpenConnectMenu)."
  [ "$TEAM_ID" != "ABCDE12345" ] && [[ "$BUNDLE_ID" != com.example.* ]] \
    || die "$file contient encore les valeurs d'exemple : renseignez votre TEAM_ID et votre BUNDLE_ID."
}

# Cherche dans le trousseau l'identité « $1: … (TEAM_ID) » ; échoue s'il y en a zéro ou plusieurs.
find_identity() {
  local kind="$1" var="$2" found count
  found="$(security find-identity -v 2>/dev/null \
    | sed -nE "s/^ *[0-9]+\) [0-9A-F]+ \"(${kind}: .*\($TEAM_ID\))\".*/\1/p" | sort -u)"
  count="$(printf '%s' "$found" | grep -c . || true)"
  [ "$count" -eq 1 ] && { printf '%s' "$found"; return; }
  if [ "$count" -eq 0 ]; then
    die "Aucun certificat « $kind » pour l'équipe $TEAM_ID dans le trousseau. Installez-le ou renseignez $var."
  fi
  die "Plusieurs certificats « $kind » pour l'équipe $TEAM_ID : renseignez $var parmi
$(printf '%s\n' "$found" | sed 's/^/    /')"
}

# Remplace les marqueurs @…@ des fichiers modèles (plists, scripts, distribution) par la configuration.
substitute() {
  sed -i '' \
    -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
    -e "s|@HELPER_LABEL@|$HELPER_LABEL|g" \
    -e "s|@PKG_ID@|$PKG_ID|g" \
    -e "s|@TEAM_ID@|$TEAM_ID|g" \
    "$@"
  # Garde-fou : un marqueur oublié ferait un paquet silencieusement faux.
  if grep -qE '@(BUNDLE_ID|HELPER_LABEL|PKG_ID|TEAM_ID|VERSION|ARCH)@' "$@"; then
    die "Marqueur non remplacé dans : $*"
  fi
}

if [ "${1:-}" = test ]; then
  TEAM_ID=TESTTEAM00; BUNDLE_ID=test.bundle   # valeurs fictives : les tests n'en dépendent pas
else
  load_config
fi
APP_NAME=OpenConnectMenu
APP_ID="$BUNDLE_ID"
HELPER_LABEL="$BUNDLE_ID.helper"
PKG_ID="$BUNDLE_ID.pkg"
# La signature échoue dans iCloud Drive (attributs étendus) : on construit ailleurs.
BUILD="${BUILD:-$HOME/Library/Caches/OpenConnectMenu/build}"
DIST="${DIST:-$ROOT/dist}"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS=13.0
TS="--timestamp"; [ -n "${NO_TIMESTAMP:-}" ] && TS="--timestamp=none"
APP="$BUILD/$APP_NAME.app"

build_app() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD"

  # iCloud Drive peut toucher les fichiers pendant la compilation (« modified during the build ») :
  # on compile donc une copie des sources, hors iCloud.
  local src="$BUILD/src"
  mkdir -p "$src"
  cp -R Shared App Helper "$src/"
  substitute "$src/App/Info.plist" "$src/Helper/Info.plist" "$src/Helper/launchd.plist"

  # Identifiant de build partagé : permet à l'app de détecter un ancien helper resté en mémoire.
  echo "let buildStamp = \"$(date +%Y%m%d-%H%M%S)\"" > "$BUILD/BuildStamp.swift"

  # Identifiants issus de la configuration (utilisés par la vérification de signature XPC).
  cat > "$BUILD/BuildConfig.swift" <<SWIFT
enum BuildConfig {
    static let bundleID = "$BUNDLE_ID"
    static let teamID = "$TEAM_ID"
}
SWIFT

  # Une compilation par architecture, puis fusion en un binaire universel avec lipo.
  local arch helper_slices=() app_slices=()
  for arch in $ARCHS; do
    echo "▸ Compilation du helper ($arch)"
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" \
      "$src"/Shared/*.swift "$BUILD/BuildStamp.swift" "$BUILD/BuildConfig.swift" "$src"/Helper/*.swift \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$src/Helper/Info.plist" \
      -o "$BUILD/helper-$arch"
    helper_slices+=("$BUILD/helper-$arch")

    echo "▸ Compilation de l'app ($arch)"
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" \
      "$src"/Shared/*.swift "$BUILD/BuildStamp.swift" "$BUILD/BuildConfig.swift" "$src"/App/*.swift \
      -o "$BUILD/app-$arch"
    app_slices+=("$BUILD/app-$arch")
  done
  echo "▸ Fusion des architectures ($ARCHS)"
  lipo -create "${helper_slices[@]}" -output "$BUILD/helper-bin"
  lipo -create "${app_slices[@]}" -output "$BUILD/app-bin"
  echo "    helper : $(lipo -archs "$BUILD/helper-bin")  |  app : $(lipo -archs "$BUILD/app-bin")"

  echo "▸ Assemblage du bundle"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
  mkdir -p "$APP/Contents/Resources"
  cp "$src/App/Info.plist" "$APP/Contents/Info.plist"
  cp "$src/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  # Traductions (en = langue par défaut, fr) : App/Resources/<langue>.lproj/Localizable.strings
  cp -R "$src/App/Resources/." "$APP/Contents/Resources/"
  cp "$BUILD/app-bin" "$APP/Contents/MacOS/$APP_NAME"
  cp "$BUILD/helper-bin" "$APP/Contents/MacOS/$HELPER_LABEL"
  cp "$src/Helper/launchd.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"
  xattr -cr "$APP"

  echo "▸ Signature de l'app ($IDENTITY)"
  codesign --force --options runtime $TS -s "$IDENTITY" -i "$HELPER_LABEL" "$APP/Contents/MacOS/$HELPER_LABEL"
  codesign --force --options runtime $TS -s "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  echo "✔ $APP"
}

install_app() {
  echo "▸ Installation dans /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto --noextattr --noqtn "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "✔ Installé et lancé"
}

notarize_pkg() {
  local file="$1" out id verdict
  echo "▸ Notarisation (profil : $NOTARY_PROFILE) — l'analyse d'Apple prend de quelques minutes"
  # Le code de retour de notarytool ne suffit pas : on lit le statut.
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  echo "$out" | sed 's/^/    /'
  id="$(echo "$out" | awk '/^  id:/ {print $2; exit}')"
  verdict="$(echo "$out" | awk '/^  status:/ {print $2}' | tail -1)"
  if [ "$verdict" != "Accepted" ]; then
    echo "✘ Notarisation non acceptée (statut : ${verdict:-inconnu}). Le paquet n'est PAS notarisé : $file"
    if [ -n "$id" ]; then
      echo "  Journal d'Apple :"
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /' || true
    fi
    exit 1
  fi

  echo "▸ Agrafage du ticket"
  xcrun stapler staple "$file" | tail -1
  xcrun stapler validate "$file" | tail -1
  echo "  Évaluation Gatekeeper :"
  spctl --assess --type install -vv "$file" 2>&1 | sed 's/^/    /' \
    || { echo "✘ Gatekeeper refuse le paquet après notarisation."; exit 1; }
}

make_pkg() {
  local version stage components pkg
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
  stage="$BUILD/pkgroot"
  components="$BUILD/components.plist"
  pkg="$BUILD/$APP_NAME-$version.pkg"

  echo "▸ Préparation du contenu du paquet"
  mkdir -p "$stage/Applications"
  ditto --noextattr --noqtn "$APP" "$stage/Applications/$APP_NAME.app"

  # L'app doit toujours atterrir dans /Applications (pas relocalisée vers une copie trouvée
  # ailleurs) et remplacer une version identique ou plus ancienne.
  pkgbuild --analyze --root "$stage" "$components" >/dev/null
  # Certaines clés sont absentes du fichier d'analyse : on les modifie ou on les ajoute.
  set_component() {
    /usr/libexec/PlistBuddy -c "Set :0:$1 $3" "$components" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :0:$1 $2 $3" "$components"
  }
  set_component BundleIsRelocatable bool false
  set_component BundleIsVersionChecked bool false
  set_component BundleOverwriteAction string upgrade

  # Scripts d'installation : copie de travail avec les identifiants de la configuration.
  rm -rf "$BUILD/pkg-scripts"
  cp -R "$ROOT/pkg-scripts" "$BUILD/pkg-scripts"
  substitute "$BUILD/pkg-scripts"/*
  chmod +x "$BUILD/pkg-scripts"/*

  echo "▸ Construction du paquet composant"
  local component="$BUILD/component.pkg"
  pkgbuild --root "$stage" \
    --component-plist "$components" \
    --identifier "$PKG_ID" \
    --version "$version" \
    --install-location / \
    --scripts "$BUILD/pkg-scripts" \
    "$component"

  # Paquet « produit » : ajoute l'écran d'accueil, les textes localisés et la vérification
  # de la présence d'openconnect avant l'installation (Distribution).
  echo "▸ Assemblage et signature du paquet produit ($INSTALLER_IDENTITY)"
  local distribution="$BUILD/Distribution.xml"
  sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/${ARCHS// /,}/g" pkg-distribution.xml.in > "$distribution"
  substitute "$distribution"
  productbuild --distribution "$distribution" \
    --resources "$ROOT/pkg-resources" \
    --package-path "$BUILD" \
    --version "$version" \
    --sign "$INSTALLER_IDENTITY" $TS \
    "$pkg"

  mkdir -p "$DIST"
  cp "$pkg" "$DIST/"

  echo "▸ Vérification"
  pkgutil --check-signature "$DIST/$(basename "$pkg")" | sed -n '1,6p'
  local tmp; tmp="$(mktemp -d)"
  pkgutil --expand-full "$pkg" "$tmp/x"
  local extracted
  extracted="$(find "$tmp/x" -type d -name "$APP_NAME.app" | head -1)"
  echo "  Contenu :"
  find "$extracted/Contents" -type f \( -name "$APP_NAME" -o -name "$HELPER_LABEL" -o -name "$HELPER_LABEL.plist" \) | sed "s|^$extracted/|    |"
  echo "  Architectures (attendu : $ARCHS) :"
  for f in "$extracted/Contents/MacOS/$APP_NAME" "$extracted/Contents/MacOS/$HELPER_LABEL"; do
    echo "    $(basename "$f") : $(lipo -archs "$f")"
  done
  echo "  Écran d'accueil et textes :"
  find "$tmp/x/Resources" -type f | sed "s|^$tmp/x/Resources/|    |" | sort
  echo "  Signature de l'app extraite :"
  codesign --verify --strict "$extracted" 2>&1 | sed 's/^/    /' && echo "    valide"
  rm -rf "$tmp"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize_pkg "$DIST/$(basename "$pkg")"
    echo "✔ $DIST/$(basename "$pkg")  (signé, notarisé, agrafé)"
  else
    echo "  Évaluation Gatekeeper (un refus « Unnotarized » est attendu sans notarisation) :"
    spctl --assess --type install -vv "$DIST/$(basename "$pkg")" 2>&1 | sed 's/^/    /' || true
    echo "✔ $DIST/$(basename "$pkg")  (signé, non notarisé — relancez avec NOTARY_PROFILE=<profil> pour notariser)"
  fi
}

# Certificats résolus avant toute compilation : une erreur de configuration apparaît tout de suite.
case "${1:-build}" in
  build|install|pkg) IDENTITY="${IDENTITY:-$(find_identity "Developer ID Application" IDENTITY)}" ;;
esac
[ "${1:-}" = pkg ] && INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(find_identity "Developer ID Installer" INSTALLER_IDENTITY)}"

# Tests de la logique des configurations (App/ConfigModel.swift, App/ConfigStore.swift), sans interface.
run_tests() {
  local out="$BUILD/tests"
  mkdir -p "$out"
  cat > "$out/BuildConfig.swift" <<SWIFT
enum BuildConfig {
    static let bundleID = "test.bundle"
    static let teamID = "TESTTEAM00"
}
SWIFT
  echo "▸ Compilation des tests"
  swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos$MIN_MACOS" \
    Shared/Shared.swift "$out/BuildConfig.swift" App/ConfigModel.swift App/ConfigStore.swift \
    Tests/ConfigStoreTests.swift -o "$out/tests"
  echo "▸ Exécution"
  "$out/tests"
}

# Profil de configuration macOS (.mobileconfig) : apporte des configurations VPN en lecture seule à l'app. macOS range les
# valeurs dans le domaine de préférences de l'app (son identifiant de bundle), sous la clé « configurations » (un tableau
# de {name, server, protocol, authgroup, useragent, username}) ; l'app les affiche verrouillées. Le mot de passe et le
# secret TOTP ne sont jamais dans un profil.
make_mobileconfig() {
  local pb="/usr/libexec/PlistBuddy" v n i
  local -a profile_names=() rows=()
  local -a envvars=(VPN_NAME VPN_SERVER VPN_PROTOCOL VPN_AUTHGROUP VPN_USERAGENT VPN_USERNAME)
  # Séparateur des champs d'une configuration. Ce n'est pas un « blanc » pour IFS (la tabulation en est un : read
  # fusionnerait alors les champs vides et décalerait les valeurs). C'est un caractère de contrôle : refusé dans les valeurs.
  local FS=$'\x1f'

  # Une configuration par profil (PROFILE=a,b) ; sans profil, une seule, décrite par l'environnement (VPN_*).
  if [ -n "${PROFILE:-}" ]; then IFS=',' read -r -a profile_names <<< "$PROFILE"; else profile_names=(""); fi

  # Protocoles gérés : lus dans Shared/Shared.swift, qui est la liste de référence (app et helper).
  local ids; ids="$(sed -nE 's/.*VPNProtocol\(id: "([a-z0-9]+)".*/\1/p' "$ROOT/Shared/Shared.swift" | tr '\n' ' ')"

  # Valeurs de l'environnement d'origine : elles priment sur les fichiers de profil.
  local -a saved=()
  for v in "${envvars[@]}"; do [ -n "${!v+x}" ] && saved+=("$v=${!v}"); done

  for n in "${profile_names[@]}"; do
    if [ -n "$n" ]; then
      [[ "$n" =~ ^[A-Za-z0-9._-]+$ && "$n" != .* ]] \
        || die "Nom de profil invalide : « $n » (lettres, chiffres, point, tiret et tiret bas uniquement)."
      [ -f "$ROOT/profiles/$n.env" ] || die "Profil introuvable : profiles/$n.env (modèle : profiles/example.env)"
    fi
    # Chaque profil est lu dans un sous-shell : les variables ne se mélangent pas d'un profil à l'autre.
    local row
    row="$(
      unset "${envvars[@]}"
      # shellcheck disable=SC1090
      [ -n "$n" ] && source "$ROOT/profiles/$n.env"
      for kv in "${saved[@]+"${saved[@]}"}"; do export "${kv%%=*}=${kv#*=}"; done
      printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" "${VPN_NAME:-${n:-VPN}}" "${VPN_SERVER:-}" "${VPN_PROTOCOL:-}" \
        "${VPN_AUTHGROUP:-}" "${VPN_USERAGENT:-}" "${VPN_USERNAME:-}"
    )"
    rows+=("$row")
  done

  # Validation. Les valeurs sont passées à PlistBuddy : ni guillemet, ni antislash, ni caractère de contrôle
  # (le séparateur de champs ci-dessus est un caractère de contrôle).
  local name server proto group agent user label
  for i in "${!rows[@]}"; do
    IFS="$FS" read -r name server proto group agent user <<< "${rows[$i]}"
    label="${profile_names[$i]:-environnement}"
    for v in "$name" "$server" "$proto" "$group" "$agent" "$user"; do
      case "$v" in *\"*|*\\*) die "Profil « $label » : guillemets et antislash interdits (« $v »)." ;; esac
      [[ "$v" != *[[:cntrl:]]* ]] || die "Profil « $label » : caractères de contrôle interdits."
    done
    [ -n "${name// /}" ] || die "Profil « $label » : VPN_NAME vide."
    [ "${#name}" -le 60 ] || die "Profil « $label » : VPN_NAME trop long (60 caractères au plus)."
    [ -n "$server$proto$group$agent$user" ] \
      || die "Profil « $label » : rien à imposer. Renseignez au moins VPN_SERVER (voir profiles/example.env)."
    [[ -z "$server" || "$server" == https://* ]] || die "Profil « $label » : VPN_SERVER doit commencer par https:// (valeur : $server)."
    if [ -n "$proto" ]; then
      [[ " $ids" == *" $proto "* ]] || die "Profil « $label » : VPN_PROTOCOL inconnu : « $proto ». Valeurs possibles : ${ids% }"
    fi
  done

  local tag="${PROFILE//,/-}"
  local out="$DIST/$APP_NAME${tag:+-$tag}.mobileconfig"
  local tmp; tmp="$(mktemp -d)"
  local f="$tmp/profile.mobileconfig"
  local id="$BUNDLE_ID.config${tag:+.$tag}" shown_label="${PROFILE:-generic}"
  local base=":PayloadContent:0" cfgs=":PayloadContent:0:PayloadContent:$BUNDLE_ID:Forced:0:mcx_preference_settings:configurations"

  plutil -create xml1 "$f"
  # Une commande par appel : PlistBuddy plante (« Abort trap ») à partir de 15 arguments -c.
  pbadd() { "$pb" -c "Add $1" "$f"; }
  pbadd ":PayloadType string Configuration"
  pbadd ":PayloadVersion integer 1"
  pbadd ":PayloadIdentifier string $id"
  pbadd ":PayloadUUID string $(uuidgen)"
  pbadd ":PayloadScope string System"
  pbadd ":PayloadDisplayName string $APP_NAME ($shown_label)"
  pbadd ":PayloadDescription string Apporte des configurations VPN en lecture seule à $APP_NAME."
  pbadd ":PayloadRemovalDisallowed bool false"
  pbadd ":PayloadContent array"
  pbadd "$base dict"
  pbadd "$base:PayloadType string com.apple.ManagedClient.preferences"
  pbadd "$base:PayloadVersion integer 1"
  pbadd "$base:PayloadIdentifier string $id.settings"
  pbadd "$base:PayloadUUID string $(uuidgen)"
  pbadd "$base:PayloadDisplayName string $APP_NAME : configurations VPN"
  pbadd "$base:PayloadContent dict"
  pbadd "$base:PayloadContent:$BUNDLE_ID dict"
  pbadd "$base:PayloadContent:$BUNDLE_ID:Forced array"
  pbadd "$base:PayloadContent:$BUNDLE_ID:Forced:0 dict"
  pbadd "$base:PayloadContent:$BUNDLE_ID:Forced:0:mcx_preference_settings dict"
  pbadd "$cfgs array"
  # Les noms de clés sont ceux lus par l'app ; un champ vide n'est pas imposé (l'utilisateur le règle).
  for i in "${!rows[@]}"; do
    IFS="$FS" read -r name server proto group agent user <<< "${rows[$i]}"
    pbadd "$cfgs:$i dict"
    pbadd "$cfgs:$i:name string $name"
    [ -n "$server" ] && pbadd "$cfgs:$i:server string $server"
    [ -n "$proto" ]  && pbadd "$cfgs:$i:protocol string $proto"
    [ -n "$group" ]  && pbadd "$cfgs:$i:authgroup string $group"
    [ -n "$agent" ]  && pbadd "$cfgs:$i:useragent string $agent"
    [ -n "$user" ]   && pbadd "$cfgs:$i:username string $user"
  done

  plutil -lint "$f" >/dev/null || die "Profil généré invalide."
  mkdir -p "$DIST"
  cp "$f" "$out"
  rm -rf "$tmp"
  echo "✔ $out"
  echo "  Domaine géré : $BUNDLE_ID (${#rows[@]} configuration(s))"
  for i in "${!rows[@]}"; do
    IFS="$FS" read -r name server proto group agent user <<< "${rows[$i]}"
    local shown="${server:+server=$server}"
    [ -n "$proto" ] && shown="${shown:+$shown | }protocol=$proto"
    [ -n "$group" ] && shown="${shown:+$shown | }authgroup=$group"
    [ -n "$agent" ] && shown="${shown:+$shown | }useragent=$agent"
    [ -n "$user" ]  && shown="${shown:+$shown | }username=$user"
    echo "  « $name » : $shown"
  done
  echo "  Profil non signé : macOS l'affiche comme « non signé » à l'installation manuelle ; un MDM le signe lui-même."
}


case "${1:-build}" in
  test)    run_tests ;;
  mobileconfig) make_mobileconfig ;;
  build)   build_app ;;
  install) build_app; install_app ;;
  pkg)     build_app; make_pkg ;;
  *)       echo "Usage : $0 [build|install|pkg|test|mobileconfig]"; exit 2 ;;
esac
