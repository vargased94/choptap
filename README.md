<p align="center">
  <img src="Resources/AppIcon.png" width="150" alt="Icono de ChopTap">
</p>

<h1 align="center">ChopTap</h1>

<p align="center">
  <b>Graba cualquier sonido de tu Mac, córtalo en chops y arrástralo directo a tu sampler.</b><br>
  Hecha para samplear desde YouTube, Spotify o cualquier app hacia Koala Sampler, tu DAW o el Finder.
</p>

<p align="center">
  <img alt="macOS 14.2+" src="https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-optimizado-6E40C9">
  <img alt="Sin Xcode" src="https://img.shields.io/badge/compila-sin%20Xcode-2ea44f">
  <a href="LICENSE"><img alt="Licencia MIT" src="https://img.shields.io/badge/licencia-MIT-blue"></a>
</p>

<p align="center">
  <img src="docs/images/screenshot.png" alt="ChopTap: forma de onda troceada en chops de colores y pads arrastrables">
</p>

---

## ✨ Qué hace

| | |
|---|---|
| 🎙️ **Graba el audio del sistema** | Todo lo que suena en el Mac, en 48 kHz / float 32 bits, sin cables ni drivers virtuales. |
| 👂 **Arranca sola** | Se arma y empieza a grabar en cuanto detecta audio (con pre-roll para no perder el ataque). Puede parar sola tras unos segundos de silencio. |
| ✂️ **Chops estilo Slicex** | Corta a mano con doble clic o al vuelo con la tecla **C** mientras suena. Cada chop tiene su color y su número. |
| 🔁 **Loop por chop** | Repite cualquier chop sin cortes para comprobar que encaja. |
| 📼 **Sonido lo-fi de sampler clásico** | Vinilo estilo SP-303/404, 12 bits a 26 kHz con aliasing, cinta y más. En tiempo real: cámbialo mientras suena. |
| 🖐️ **Arrastrar y soltar** | Cada pad se arrastra como WAV a Koala Sampler, Ableton, Logic, FL Studio o el Finder. O todos a la vez. |
| 🔍 **Zoom fino** | Pellizco en el trackpad hasta ver las muestras individuales, para cortar justo donde quieres. |

## 🚀 Instalación

Necesitas **macOS 14.2 o posterior** y las **Command Line Tools** (no hace falta Xcode):

```bash
xcode-select --install   # solo si no las tienes
```

Clona, compila e instala:

```bash
git clone https://github.com/vargased94/choptap.git
cd choptap
./build.sh
cp -R build/ChopTap.app /Applications/
```

Abre **ChopTap** desde Aplicaciones y, si quieres, ánclala al Dock (clic derecho → Opciones → Mantener en el Dock).

> **Permiso de audio:** la primera vez que grabes, macOS pedirá permiso. Actívalo en **Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema → Solo grabación de audio del sistema**, y vuelve a abrir la app.

## 🎛️ Cómo se usa

### 1. Graba

1. Pulsa el **botón rojo** (o **⌘R**). La app queda en *Esperando audio…*
2. Reproduce la canción en YouTube, Spotify o donde sea. La grabación empieza sola.
3. Pulsa otra vez para detener (o deja que pare sola tras el silencio, desde ⚙️ ajustes).

### 2. Corta tus chops

- **Clic** en la onda → la escuchas desde ese punto.
- Mientras suena, pulsa **C** al ritmo → corta en ese instante.
- **Doble clic** → añade un corte exacto donde haces clic.
- **Arrastra un corte** (por su línea o su pestaña numerada) para ajustarlo. Con **⇧** el movimiento es fino.
- **⌥ + clic** sobre un corte → lo borra.

### 3. Afina con zoom

<p align="center">
  <img src="docs/images/zoom.png" width="760" alt="Zoom a nivel de muestra sobre un corte">
</p>

- **Pellizco** en el trackpad para acercar o alejar alrededor del cursor.
- **Dos dedos** en horizontal para desplazarte.
- La **mini vista** de abajo muestra toda la grabación: arrástrala para moverte, doble clic para ver todo.

### 4. Escucha y loopea

- **Clic en un pad** o teclas **1–9** → dispara el chop.
- Botón **🔁** del pad (o **L**) → lo repite en loop.

### 5. Dale sabor lo-fi

<p align="center">
  <img src="docs/images/lofi.png" width="760" alt="Panel LO-FI con presets y controles">
</p>

Activa **LO-FI** y elige un preset. El efecto va **en tiempo real**: pon la canción o un chop en loop y cambia de preset o mueve los controles mientras suena para comparar cuál te gusta más. Los chops que arrastras salen exactamente como los escuchas (llevan "LoFi" en el nombre).

| Preset | Inspirado en |
|---|---|
| **Vinilo 303** | El Vinyl Sim del SP-303: compresión sucia que "bombea", crujido de vinilo y wow. |
| **Vinilo 404** | El Vinyl Sim del SP-404: más suave y oscuro. |
| **12-bit 26k** | Samplers de 12 bits a 26,04 kHz sin filtro antialias: el brillo metálico del boom bap. |
| **Sampler 90s** | 12 bits filtrado y cálido, como los samplers de rack de los 90. |
| **Cassette** | Saturación de cinta, siseo y wow. |
| **Destrozado** | 8 bits a 11 kHz, sucio a propósito. |

En **Ajustes** del panel controlas cada etapa: bits, frecuencia de muestreo, aliasing, filtro, compresión, saturación, ruido de vinilo y wow/flutter (al tocar cualquiera pasa a *Personalizado*).

> Cómo funciona: la investigación en foros (KVR) coincide en que un bitcrusher no basta; el carácter de estos samplers viene de bajar la frecuencia de muestreo **dejando el aliasing** y del **filtro de salida**. La cadena de ChopTap es: wow/flutter → reducción de muestreo (sample & hold, con o sin antialias) → bits (truncado sin dither) → ruido de vinilo → compresión → saturación → filtro de salida de 4 polos. Los presets son aproximaciones inspiradas en esos equipos, no emulaciones oficiales.

### 6. Arrástralo a tu sampler

Arrastra cualquier **pad** a Koala Sampler (o a tu DAW o al Finder) y suelta: se crea un WAV al momento. Con **Arrastrar todos** sueltas todos los chops de una vez.

## ⌨️ Atajos

| Tecla | Acción |
|---|---|
| **⌘R** | Grabar / detener |
| **Espacio** | Reproducir / parar |
| **Clic** · **Doble clic** | Oír desde ahí · cortar |
| **C** | Cortar en el cursor (también mientras suena) |
| **1–9, 0** | Disparar chops 1–10 |
| **L** | Loop del chop seleccionado |
| **← →** | Chop anterior / siguiente |
| **⌥← ⌥→** | Mover el corte 10 ms (con **⇧**, 1 ms) |
| **⌫** | Unir el chop con el anterior |
| **⌥ + clic** | Borrar un corte |
| **⌘+ ⌘- ⌘0** | Acercar · alejar · ver todo |
| **Esc** | Parar |

## 🎧 Consejos para samplear de YouTube

- Pon el **volumen del reproductor de YouTube al 100 %** (el volumen del Mac da igual).
- Desactiva **Volumen estable** en el ⚙️ del reproductor: comprime la dinámica y los golpes pierden pegada.
- Se graba **todo** lo que suena en el Mac: silencia notificaciones y otras pestañas.
- La calidad máxima es la de la fuente: YouTube ya viene comprimido. Si tienes el tema en mejor calidad, úsalo.

## ⚙️ Ajustes

Desde el botón ⚙️ (arriba a la derecha):

- **Empezar al detectar audio** y su **umbral** (-60 a -20 dB).
- **Parar tras silencio** (1–10 s): descarta el silencio final.
- **Exportar chops:** normalizar a -0,3 dB, fade de 0–20 ms en los bordes (evita clics) y WAV de 16 o 24 bits.

## 🔬 Calidad de audio

ChopTap captura el audio con **Core Audio Process Taps**, antes del volumen del sistema y de los altavoces o auriculares. Medido con una señal de prueba (barrido de 20 Hz a 20 kHz):

- El nivel grabado es idéntico al original y no hay recortes ni huecos.
- La respuesta en frecuencia es plana (±0,01 dB entre 50 Hz y 15 kHz).
- Graba a la frecuencia nativa del tap (48 kHz) para evitar conversiones innecesarias.

Puedes repetir la prueba con:

```bash
build/ChopTap.app/Contents/MacOS/ChopTap --selftest /tmp/prueba.caf 8
```

## 🗂️ Estructura

```
Sources/ChopTap/
├── SystemAudioRecorder.swift   Captura con Core Audio Process Taps, detección y auto-stop
├── WaveData.swift              Forma de onda multirresolución (mín/máx + muestras)
├── WaveformView.swift          Onda, cortes, zoom y mini vista general
├── ContentView.swift           Interfaz: barra superior, transporte y pads
├── AppModel.swift              Estado, chops, reproducción y exportación
├── AudioTools.swift            Lectura, exportación WAV y reproductor
├── LoFi.swift                  Efecto lo-fi (DSP) y presets
├── LoFiView.swift              Panel LO-FI
├── DragOut.swift               Arrastrar archivos a otras apps
└── TrackpadCatcher.swift       Pellizco y scroll del trackpad
tools/
└── icon/make-icon.swift        Genera el icono
```

## 📄 Licencia

[MIT](LICENSE): puedes usar, modificar y compartir el código libremente, manteniendo el aviso de copyright.

## 🙏 Créditos

- Inspirada en el flujo de trabajo de Slicex y Koala Sampler.

> ChopTap está firmada ad-hoc. Si al recompilar macOS te vuelve a pedir el permiso, crea un certificado de firma de código llamado **"ChopTap Dev"** en Acceso a Llaveros: `build.sh` lo usará y el permiso se conservará.
