# mac-app-updates

Actualizaciones automáticas ([Sparkle 2](https://sparkle-project.org)) de mis apps de macOS.

Este repositorio es **público** y solo contiene binarios firmados, los feeds y las herramientas de publicación.
El código de cada app vive en su propio repositorio, que puede ser privado.
Las apps no llevan ningún token: leen el feed y descargan los ZIP públicos.

```
apps/<slug>/appcast.xml     feed de Sparkle (URL fija: raw.githubusercontent.com/fernandorm/mac-app-updates/main/apps/<slug>/appcast.xml)
apps/<slug>/releases.json   historial de versiones (fuente de verdad del feed)
GitHub Releases             <slug>-vX.Y.Z → <App>-X.Y.Z.zip (la .app firmada, notarizada y grapada)
tools/publish-app.sh        publica una versión (comprobaciones → notarización → ZIP → firma Sparkle → release → feed)
tools/appcast.py            genera el feed
tools/setup-sparkle.sh      descarga las herramientas oficiales de Sparkle (no se suben al repo)
```

| App | Slug | Feed |
|---|---|---|
| MyPaste | `mypaste` | [`apps/mypaste/appcast.xml`](apps/mypaste/appcast.xml) |
| ClipMaker | `clipmaker` | [`apps/clipmaker/appcast.xml`](apps/clipmaker/appcast.xml) |
| ReCast | `recast` | [`apps/recast/appcast.xml`](apps/recast/appcast.xml) |
| ReVoice | `revoice` | [`apps/revoice/appcast.xml`](apps/revoice/appcast.xml) (solo la app; el motor de Python vive en su repositorio) |
| MyDublivo (antes DubLocal) | `mydublivo` | [`apps/mydublivo/appcast.xml`](apps/mydublivo/appcast.xml) (solo la app; el motor de Python vive en ~/Projects/MyDublivo/engine) |
| MyNewFile | `mynewfile` | [`apps/mynewfile/appcast.xml`](apps/mynewfile/appcast.xml) (incluye la extensión de Finder) |
| MyDato | `mydato` | [`apps/mydato/appcast.xml`](apps/mydato/appcast.xml) (app con sandbox: usa los servicios XPC de Sparkle) |
| MyMRemoteNG | `mymremoteng` | [`apps/mymremoteng/appcast.xml`](apps/mymremoteng/appcast.xml) |

## Requisitos en el Mac que publica (una sola vez)

1. **Certificado Developer ID Application** en el llavero (`security find-identity -v -p codesigning`).
2. **Perfil de notarización** en el llavero para el equipo KQMP2NUSS7. Se usa el perfil existente `ClipMaker` (cuenta fernandorm86@gmail.com); otro se elige con `NOTARY_PROFILE=nombre`. Para crear uno nuevo, con una contraseña específica de app de account.apple.com que nunca debe ir a un archivo ni a un chat:
   ```bash
   xcrun notarytool store-credentials "NOMBRE" --apple-id "APPLE_ID" --team-id KQMP2NUSS7
   ```
3. **`gh` autenticado** con permiso `repo` (`gh auth status`).
4. **Herramientas de Sparkle:** `tools/setup-sparkle.sh`. `publish-app.sh` las descarga solo si faltan.
5. **Clave EdDSA de cada app** en el llavero. Ver «Añadir una app».

No hay secretos en este repositorio. El certificado, la contraseña de notarización y las claves privadas de Sparkle viven solo en el llavero del Mac que publica.

## Copia de seguridad de las claves de Sparkle (imprescindible)

Si se pierde la clave privada de una app, las copias ya instaladas **no aceptarán ninguna actualización más** y habría que reinstalar a mano en cada Mac. Exporta la clave a un archivo, guárdalo en tu gestor de contraseñas y borra el archivo:

```bash
tools/sparkle/bin/generate_keys --account mypaste -x ~/Desktop/mypaste-sparkle-key.txt
# … guárdalo en 1Password/Bitwarden y luego:
rm ~/Desktop/mypaste-sparkle-key.txt
```

Para restaurarla en otro Mac: `tools/sparkle/bin/generate_keys --account mypaste -f archivo-de-la-clave`.

## Publicar una versión

Desde el repositorio de la app (cada app tiene un `scripts/release.sh` que llama a `tools/publish-app.sh`):

```bash
scripts/release.sh 1.2.0 "Qué cambia"              # publica de verdad
scripts/release.sh 1.2.0 "Qué cambia" --dry-run    # ensayo completo sin publicar nada
```

`publish-app.sh` se niega a publicar en estos casos:
- la app no está firmada con Developer ID, o su `SUPublicEDKey` no coincide con la clave del llavero;
- la versión no es mayor que la última publicada, o la release ya existe;
- la notarización falla (salvo con `--skip-notarize`).

Solo se publica una versión a la vez (candado `.publish.lock`), y cada ejecución usa su propia carpeta temporal.

El **feed se actualiza el último**, solo cuando el ZIP ya es público y descargable con el tamaño correcto. Si algo falla antes, ninguna Mac ve la versión.

## Añadir otra app

1. **Clave:** `tools/sparkle/bin/generate_keys --account <slug>` y apunta la clave pública. Haz la copia de seguridad descrita arriba.
2. **Sparkle en la app:** por SwiftPM (`https://github.com/sparkle-project/Sparkle`, versión exacta). Inicia `SPUStandardUpdaterController` y añade «Buscar actualizaciones…». MyPaste sirve de ejemplo (`Sources/MyPaste/Updater.swift`).
3. **`Info.plist`:**
   - `SUFeedURL` = `https://raw.githubusercontent.com/fernandorm/mac-app-updates/main/apps/<slug>/appcast.xml`
   - `SUPublicEDKey` = la clave pública
   - `SUEnableAutomaticChecks` = `true`
   - `CFBundleVersion` con formato X.Y.Z, siempre creciente
4. **Firma:** incrusta y firma `Sparkle.framework` con la misma Developer ID (ver `scripts/build-app.sh` de MyPaste). Si la app es de Xcode, Xcode lo hace al exportar con Developer ID.
5. **Script de publicación:** un `scripts/release.sh` que compile la `.app` y llame a `tools/publish-app.sh --app-path … --slug <slug>`.
6. **Primera instalación:** instala esa primera versión a mano en cada Mac. A partir de ahí se actualiza sola.

## Recuperarse de una versión defectuosa

Sparkle **nunca baja de versión**: la solución siempre es publicar una versión **mayor** con el arreglo.

1. Corrige el código, o vuelve al último commit bueno, en el repo de la app.
2. Publica con el número siguiente: `scripts/release.sh 1.2.1 "Corrige el fallo de 1.2.0"`.
3. Opcional: marca la release mala en GitHub como *pre-release* para no ofrecerla en descargas manuales. No la quites del feed: las Macs que ya la tienen se actualizarán a 1.2.1.

Si una versión rompe la propia actualización (por ejemplo, la app no arranca), la versión corregida no podrá llegar sola a esas Macs. En ese caso, descarga el ZIP corregido de Releases e instálalo a mano en cada una.
