# fakeGPS

![shell](https://img.shields.io/badge/shell-POSIX_sh-89e051)
![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen)
![deps](https://img.shields.io/badge/d%C3%A9pendances-coreutils%20%2B%20socat-lightgrey)

---

![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)
![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=plastic&logo=gnu&logoColor=white)

---

Générateur de trames **NMEA 0183** (GPS + GLONASS) en shell POSIX. Il simule un
récepteur GNSS qui parle sur un port série, pour alimenter n'importe quelle
application lisant du NMEA (carte, tableau de bord, enregistreur, `gpsd`, etc.)
sans vrai GPS ni fix réel.

Pensé pour les captures d'écran, les tests et les démonstrations : la position
simulée peut être figée ou "respirer" de quelques mètres comme un vrai
récepteur immobile, sans jamais exposer une localisation réelle.

## Fonctionnalités

- Trames d'un cycle GNSS GPS+GLONASS : `GNRMC`, `GNGGA`, deux `GNGSA` (un par
  constellation), `GPGSV` et `GLGSV` (satellites en vue).
- Somme de contrôle NMEA calculée automatiquement pour chaque trame.
- Bruit de position réaliste et réglable (de 0 à N mètres), pour éviter le rendu
  « trop parfait » d'une position constante.
- Sortie vers un port série (vrai périphérique ou pseudo-terminal `socat`) ou vers
  la sortie standard pour inspection.
- Deux positions prêtes à l'emploi : Paris et Null Island (0,0).
- POSIX sh strict, sans bashisme, validé par `shellcheck`.

## Prérequis

- Un système Unix/Linux avec `/bin/sh` POSIX.
- Outils standard : `od`, `stty`, `tr`, `date`, `printf` (présents via coreutils
  et util-linux), et `/dev/urandom`.
- `socat` uniquement pour la méthode à port série virtuel (voir plus bas).

## Installation

```sh
chmod +x fakegps.sh
```

## Utilisation

```text
./fakegps.sh [paris|null] [périphérique-série] [intervalle-secondes]
```

| Argument | Rôle | Défaut |
|----------|------|--------|
| 1 | Lieu simulé : `paris` ou `null` | `paris` |
| 2 | Périphérique série de sortie. Vide = sortie standard | sortie standard |
| 3 | Intervalle entre deux salves, en secondes | `1` |

| Variable d'env. | Rôle | Défaut |
|-----------------|------|--------|
| `JITTER_M` | Amplitude du bruit de position, en mètres (`0` = figé) | `3` |

Le débit série (`BAUD`, 9600 par défaut) se règle en tête de script.

## Exemples

```sh
# Paris, sortie standard, une salve par seconde, bruit ~3 m (pour vérifier le flux)
./fakegps.sh

# Null Island figé exactement sur 0,0, vers un port série virtuel
JITTER_M=0 ./fakegps.sh null /dev/ttyV0 1

# Paris vers un adaptateur USB-série, une salve toutes les 2 secondes
./fakegps.sh paris /dev/ttyUSB0 2
```

Sans périphérique en argument, le script écrit sur la sortie standard, ce qui
permet de contrôler les trames avant tout branchement :

```text
$GNRMC,123519.00,A,4851.3960,N,00221.1320,E,0.0,0.0,090626,,,A*XX
$GNGGA,123519.00,4851.3960,N,00221.1320,E,1,09,0.9,35.0,M,47.0,M,,*XX
$GNGSA,A,3,01,02,03,04,05,,,,,,,,1.7,0.9,1.4*27
$GNGSA,A,3,68,69,70,71,,,,,,,,,1.7,0.9,1.4*26
$GPGSV,2,1,05,01,40,083,42,02,17,308,40,03,07,344,39,04,22,228,44*7D
$GPGSV,2,2,05,05,57,045,41*4F
$GLGSV,1,1,04,68,45,120,40,69,33,250,38,70,12,065,35,71,60,300,41*6D
```

## Intégration via un port série virtuel (socat)

Quand l'application et le générateur tournent sur la même machine, `socat` crée
une paire de pseudo-terminaux reliés : ce qui est écrit dans l'un ressort dans
l'autre. Le générateur écrit dans un bout, l'application lit l'autre.

```sh
socat -d -d pty,raw,echo=0,link=/dev/ttyV0 pty,raw,echo=0,perm=0660,group=dialout,link=/dev/ttyV1
```

Puis, dans un second terminal :

```sh
./fakegps.sh paris /dev/ttyV0 1
```

L'application est configurée pour lire `/dev/ttyV1` à 9600 bauds.

> **Permissions du pseudo-terminal.** Par défaut, le pty créé par `socat` n'est
> lisible que par root (`root:root`, mode `0600`). Si l'application s'exécute en
> service systemd sous un utilisateur dédié (par exemple `Group=dialout`), elle
> obtient un *Permission denied* à l'ouverture : la connexion applicative reste
> établie mais aucune trame n'arrive. D'où l'option `perm=0660,group=dialout`
> posée sur le bout **lu par l'application** (`/dev/ttyV1`) : le groupe obtient le
> droit de lecture, et le service membre de ce groupe peut alors lire le flux. Le
> bout d'écriture (`/dev/ttyV0`) n'a besoin d'aucune option.
>
> Vérification des permissions effectives :
> ```sh
> stat -c '%U:%G %a' "$(readlink -f /dev/ttyV1)"   # attendu : root:dialout 660
> ```

Astuce : sur une machine où `/dev/ttyAMA0` n'existe pas, `socat` peut nommer le
lien directement `/dev/ttyAMA0`, ce qui dispense de reconfigurer une application
dont le port serait codé en dur.

## Trames générées

Une salve, émise à chaque intervalle, reproduit un cycle d'un récepteur
GPS+GLONASS :

| Trame | Talker | Contenu |
|-------|--------|---------|
| `RMC` | `GN` | Heure, validité, position, vitesse, cap, date |
| `GGA` | `GN` | Heure, position, qualité du fix, nombre de satellites, HDOP, altitude |
| `GSA` ×2 | `GN` | Satellites utilisés et DOP, une trame par constellation (GPS puis GLONASS) |
| `GSV` | `GP` / `GL` | Satellites en vue (PRN, élévation, azimut, SNR), GPS et GLONASS séparés |

Le talker `GN` correspond à une solution combinée multi-constellations ; les
satellites en vue restent séparés par système (`GP` pour le GPS, `GL` pour le
GLONASS).

## Personnaliser les trames

Le cœur du script est la fonction `emit`. Une trame NMEA s'écrit :

```text
$  +  CORPS  +  *  +  CHECKSUM  +  CR LF
```

Le checksum est le XOR de tous les octets du corps (entre `$` et `*`). `emit`
réalise cet emballage : on lui passe **uniquement le corps**, sans `$` initial ni
`*XX` final, et elle ajoute le préfixe, l'astérisque, la somme calculée et la fin
de ligne.

Pour ajouter une trame, il suffit d'appeler `emit` dans la boucle principale, par
exemple pour une trame route/vitesse `VTG` :

```sh
emit "GNVTG,0.0,T,,M,0.0,N,0.0,K,A"
```

Pour modifier le nombre de satellites, on édite les corps `GSA`/`GSV` : une trame
`GSA` comporte toujours douze emplacements de PRN (complétés par des champs
vides), et chaque message `GSV` liste au plus quatre satellites. Le champ
« satellites en vue » d'un groupe `GSV` doit rester cohérent avec le nombre
réellement listé.

## Bruit de position

Par défaut, la position varie de quelques mètres à chaque salve, comme un
récepteur immobile soumis au bruit, au multipath, etc. L'amplitude se règle via
`JITTER_M` (en mètres) :

```sh
./fakegps.sh paris /dev/ttyV0 1              # bruit ~3 m (défaut)
JITTER_M=8 ./fakegps.sh paris /dev/ttyV0 1   # ~8 m, récepteur plus nerveux
JITTER_M=0 ./fakegps.sh paris /dev/ttyV0 1   # position figée
```

Le tirage est indépendant à chaque salve (bruit blanc), ce qui suffit à un rendu
crédible. Pour Null Island, `JITTER_M=0` est recommandé afin de conserver le point
exactement sur 0,0.

## Licence

!(WFTPL)[https://www.wtfpl.net/]
