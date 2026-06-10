#!/bin/sh
#==============================================================================
# fakegps.sh - Générateur de trames NMEA 0183 (GPS + GLONASS)
#------------------------------------------------------------------------------
# But : simuler un récepteur GNSS qui parle sur un port série, afin d'alimenter
#       une application qui lit du NMEA (carte, tableau de bord, enregistreur,
#       gpsd...) sans avoir besoin d'un vrai GPS ni d'un fix réel. Pratique pour
#       des captures d'écran, des tests automatisés ou des démonstrations.
#
# Le script écrit en boucle des trames NMEA :
#   - sur un périphérique série passé en argument (vrai port ou pty socat), ou
#   - sur la sortie standard si aucun périphérique n'est fourni (pour debug).
#
# Position simulée : Paris ou « Null Island » (0,0), avec un bruit optionnel de
# quelques mètres pour imiter le tremblement d'un vrai récepteur immobile.
#
# Usage :
#   ./fakegps.sh [paris|null] [périphérique-série] [intervalle-secondes]
#
# Variable d'environnement :
#   JITTER_M   amplitude du bruit de position en mètres (défaut 3 ; 0 = figé)
#
# Exemples :
#   ./fakegps.sh                                # Paris, stdout, 1 s, bruit ~3 m
#   ./fakegps.sh paris /dev/ttyV0 1             # Paris vers le pty socat ttyV0
#   JITTER_M=0 ./fakegps.sh null /dev/ttyV0 1   # Null Island figé sur 0,0
#
# Portabilité : POSIX sh strict (aucun bashisme), validé par shellcheck.
#==============================================================================

# set -e : on stoppe à la première commande qui échoue.
# set -u : toute variable non définie est une erreur (attrape les fautes de frappe).
set -eu

#------------------------------------------------------------------------------
# Paramètres de ligne de commande et réglages
#------------------------------------------------------------------------------
LOC="${1:-paris}"           # 1er argument : lieu simulé (paris | null). Défaut : paris.
DEV="${2:-}"                # 2e argument : périphérique série cible. Vide => stdout.
INTERVAL="${3:-1}"          # 3e argument : délai entre deux salves, en secondes.
BAUD=9600                   # Débit série appliqué au périphérique (standard NMEA).
JITTER_M="${JITTER_M:-3}"   # Amplitude du bruit de position, en mètres.

# Conversion mètres -> unités internes de coordonnées.
# Les coordonnées NMEA sont en degrés + minutes décimales (ddmm.mmmm). Le dernier
# chiffre de la fraction de minute (1/10000 de minute) vaut environ 0,185 m. Donc
# 1 mètre ≈ 5 unités de 1/10000 de minute. AMP est l'amplitude maximale du bruit,
# en unités, appliquée de part et d'autre de la position de base.
AMP=$(( JITTER_M * 5 ))

#------------------------------------------------------------------------------
# Choix de la position de base selon le lieu demandé.
#
# Chaque coordonnée est stockée en composants ENTIERS pour pouvoir appliquer le
# bruit en arithmétique entière (pas de calcul flottant en POSIX sh) :
#   _DEG  : degrés
#   _MIN  : minutes entières
#   _FRAC : fraction de minute en 1/10000 (ex. : .3960' -> 3960)
# La latitude s'écrit ddmm.mmmm, la longitude dddmm.mmmm (3 chiffres de degrés).
#------------------------------------------------------------------------------
case "$LOC" in
    paris)
        # Paris ≈ 48,8566 N / 2,3522 E  ->  4851.3960 N / 00221.1320 E
        LAT_DEG=48; LAT_MIN=51; LAT_FRAC=3960; NS=N
        LON_DEG=2;  LON_MIN=21; LON_FRAC=1320; EW=E
        ALT="35.0"          # Altitude simulée en mètres (champ de la trame GGA).
        ;;
    null)
        # Null Island : intersection équateur / méridien de Greenwich (0,0).
        LAT_DEG=0; LAT_MIN=0; LAT_FRAC=0; NS=N
        LON_DEG=0; LON_MIN=0; LON_FRAC=0; EW=E
        ALT="0.0"
        ;;
    *)
        # Lieu inconnu : message d'usage sur stderr puis sortie en erreur.
        echo "usage: $0 [paris|null] [device-serie] [intervalle-sec]" >&2
        exit 1
        ;;
esac

#------------------------------------------------------------------------------
# rand_delta : tire un entier aléatoire dans l'intervalle [-AMP, +AMP].
#
# On lit 2 octets dans /dev/urandom (entier non signé 0..65535) plutôt que
# d'utiliser $RANDOM, qui est une extension bash absente en POSIX sh.
#   span = 2*AMP + 1   (nombre de valeurs possibles)
#   r % span           ramène dans [0, span-1]
#   - AMP              recentre dans [-AMP, +AMP]
# Si AMP vaut 0 (bruit désactivé), on renvoie 0 immédiatement.
#------------------------------------------------------------------------------
rand_delta() {
    if [ "$AMP" -le 0 ]; then printf '0'; return; fi
    span=$(( AMP * 2 + 1 ))
    r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')   # 2 octets -> entier 0..65535
    printf '%d' "$(( r % span - AMP ))"
}

#------------------------------------------------------------------------------
# mk_lat : construit le champ latitude NMEA (ddmm.mmmm) avec le bruit appliqué.
#
# On ajoute le bruit à la fraction de minute, puis :
#   - on borne à 0 si le tirage rend la valeur négative (évite de basculer dans
#     l'hémisphère opposé, notamment autour de 0,0 pour Null Island) ;
#   - si la fraction atteint 10000 (soit une minute entière), on reporte la
#     retenue sur les minutes (cas rare avec un petit bruit, mais propre).
# Format final : 2 chiffres de degrés, 2 de minutes, point, 4 de fraction.
#------------------------------------------------------------------------------
mk_lat() {
    dlt=$(rand_delta)                 # bruit tiré pour cette latitude
    frac=$(( LAT_FRAC + dlt ))        # fraction de minute bruitée
    if [ "$frac" -lt 0 ]; then frac=0; fi
    min=$LAT_MIN
    while [ "$frac" -ge 10000 ]; do frac=$(( frac - 10000 )); min=$(( min + 1 )); done
    printf '%02d%02d.%04d' "$LAT_DEG" "$min" "$frac"
}

#------------------------------------------------------------------------------
# mk_lon : identique à mk_lat mais pour la longitude.
# Différence : 3 chiffres de degrés au lieu de 2 (format dddmm.mmmm).
#------------------------------------------------------------------------------
mk_lon() {
    dlt=$(rand_delta)
    frac=$(( LON_FRAC + dlt ))
    if [ "$frac" -lt 0 ]; then frac=0; fi
    min=$LON_MIN
    while [ "$frac" -ge 10000 ]; do frac=$(( frac - 10000 )); min=$(( min + 1 )); done
    printf '%03d%02d.%04d' "$LON_DEG" "$min" "$frac"
}

#------------------------------------------------------------------------------
# nmea_checksum : calcule la somme de contrôle NMEA d'un corps de trame.
#
# La norme NMEA 0183 définit le checksum comme le XOR (ou exclusif) de tous les
# octets situés entre le « $ » de début et le « * » de fin, exprimé en deux
# chiffres hexadécimaux majuscules.
#
# Astuce POSIX pour parcourir la chaîne caractère par caractère sans tableau :
#   ${s#?}            = la chaîne privée de son 1er caractère
#   ${s%"${s#?}"}     = la chaîne privée de tout sauf son 1er caractère => 1er car.
# Et pour obtenir le code ASCII d'un caractère, l'astuce printf "%d" "'c" :
#   un argument commençant par une apostrophe vaut le code du caractère suivant.
#------------------------------------------------------------------------------
nmea_checksum() {
    s="$1"
    cs=0
    while [ -n "$s" ]; do
        c=${s%"${s#?}"}                       # 1er caractère de la chaîne restante
        s=${s#?}                              # on retire ce caractère
        cs=$(( cs ^ $(printf '%d' "'$c") ))   # XOR avec le code ASCII du caractère
    done
    printf '%02X' "$cs"
}

#------------------------------------------------------------------------------
# Ouverture de la sortie sur le descripteur de fichier 3.
#
# Toutes les écritures de trames passent par le fd 3 : soit le périphérique série
# demandé, soit la sortie standard. Ouvrir le port une seule fois (et non à chaque
# trame) évite de le réinitialiser en permanence.
#   stty ... raw -echo : mode brut, sans écho, pour ne pas altérer les octets émis.
#------------------------------------------------------------------------------
if [ -n "$DEV" ]; then
    stty -F "$DEV" "$BAUD" raw -echo    # configure le port série cible
    exec 3>"$DEV"                       # le fd 3 écrit dans le périphérique
else
    exec 3>&1                           # pas de périphérique : le fd 3 = stdout
fi

# À l'arrêt (Ctrl-C ou kill), on referme proprement le fd 3 puis on sort.
trap 'exec 3>&-; exit 0' INT TERM

#------------------------------------------------------------------------------
# emit : emballe un CORPS de trame en trame NMEA complète et l'écrit sur le fd 3.
#
# On ne fournit QUE le corps (ce qui se trouve entre le « $ » et le « * »), sans
# « $ » ni « *XX ». La fonction calcule le checksum, puis ajoute le « $ » initial,
# le « * », le checksum et la fin de ligne CR LF (\r\n) attendue par la norme.
#   Exemple : emit "GNVTG,0.0,T,,M,0.0,N,0.0,K,A"
#   produit sur le fil : $GNVTG,0.0,T,,M,0.0,N,0.0,K,A*<somme>\r\n
#------------------------------------------------------------------------------
emit() {
    body="$1"
    cs=$(nmea_checksum "$body")
    printf '$%s*%s\r\n' "$body" "$cs" >&3
}

#------------------------------------------------------------------------------
# Boucle principale : une salve de trames par intervalle.
#
# À chaque tour on rafraîchit l'heure et la date UTC, on (re)calcule la position
# bruitée, puis on émet l'ensemble des trames d'un cycle GNSS typique GPS+GLONASS.
#------------------------------------------------------------------------------
while :; do
    tm=$(date -u +%H%M%S.00)            # heure UTC hhmmss.00 (champ temps NMEA)
    dt=$(date -u +%d%m%y)               # date UTC jjmmaa (champ date du RMC)
    lat=$(mk_lat); lon=$(mk_lon)        # position bruitée de ce cycle

    # --- Trames de position / fix : talker « GN » car le fix est combiné GPS+GLONASS ---
    # RMC = données minimales recommandées : heure, validité (A=valide), position,
    #       vitesse (nœuds), cap, date, mode (A=autonome).
    emit "GNRMC,$tm,A,$lat,$NS,$lon,$EW,0.0,0.0,$dt,,,A"
    # GGA = fix : heure, position, qualité (1=fix GPS), nombre de sats utilisés (09),
    #       HDOP, altitude (M=mètres), hauteur du géoïde (M), champs DGPS vides.
    emit "GNGGA,$tm,$lat,$NS,$lon,$EW,1,09,0.9,$ALT,M,47.0,M,,"

    # --- Satellites UTILISÉS dans la solution : une trame GSA par constellation ---
    # Champs : mode (A=auto), type de fix (3=3D), 12 emplacements de PRN (complétés
    #          par des champs vides), puis PDOP, HDOP, VDOP.
    emit "GNGSA,A,3,01,02,03,04,05,,,,,,,,1.7,0.9,1.4"   # 5 satellites GPS
    emit "GNGSA,A,3,68,69,70,71,,,,,,,,,1.7,0.9,1.4"     # 4 satellites GLONASS (PRN 65-96)

    # --- Satellites EN VUE : « GP » pour le GPS, « GL » pour le GLONASS ---
    # En-tête : nombre total de messages, numéro du message, nombre de sats en vue ;
    # puis, pour chaque satellite : PRN, élévation (deg), azimut (deg), SNR (dB).
    # Un message GSV liste au plus 4 satellites, d'où le découpage en 2 pour le GPS.
    emit "GPGSV,2,1,05,01,40,083,42,02,17,308,40,03,07,344,39,04,22,228,44"
    emit "GPGSV,2,2,05,05,57,045,41"
    emit "GLGSV,1,1,04,68,45,120,40,69,33,250,38,70,12,065,35,71,60,300,41"

    sleep "$INTERVAL"                   # attente avant la salve suivante
done
