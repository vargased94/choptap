<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Icono de Recorded"></p>

# Recorded

App de macOS para samplear: graba todo el audio que suena en el Mac, muestra la forma de onda, te deja cortarla en chops (estilo Slicex), quitar la voz con IA y arrastrar cada chop como WAV a Koala Sampler, a tu DAW o al Finder.

## Requisitos

- macOS 14.2 o posterior (usa Core Audio Process Taps para capturar el audio del sistema).
- Command Line Tools de Xcode (no hace falta Xcode completo).
- Opcional, para quitar la voz: Python 3 y ~430 MB para Demucs (Apple Silicon recomendado).

## Compilar e instalar

```bash
./build.sh
cp -R build/Recorded.app /Applications/
```

La primera vez que grabes, macOS pedirá permiso en **Ajustes → Privacidad y seguridad → Grabación de pantalla y audio del sistema → Solo grabación de audio del sistema**.

Graba a 48 kHz en float de 32 bits, antes del volumen del sistema; los chops se exportan como WAV de 16 o 24 bits.

## Uso

### Grabar
- Pulsa el botón rojo (⌘R). Con *Empezar al detectar audio* activado (menú de ajustes, arriba a la derecha) la app se arma y empieza sola cuando el sonido supera el umbral, con ~150 ms de pre-roll.
- *Parar tras silencio*: se detiene sola tras 1–10 s de silencio y descarta ese silencio final.
- Cada grabación sustituye a la anterior; no se guarda historial.

### Cortar (manual)
- **Clic** en la onda: reproduce desde ese punto. Mientras suena, pulsa **C** para cortar al vuelo.
- **Doble clic**: añadir un corte. **⌥ + clic** en un corte: borrarlo.
- **Mover un corte**: arrástralo por su línea o por su pestaña numerada. Con **⇧** el movimiento es fino (8× más lento). Si llegas al borde con zoom, la vista se desplaza sola.
- **⌥← / ⌥→** mueven el corte del chop seleccionado 10 ms (**⌥⇧** 1 ms).
- **1–9 / 0** disparan los chops 1–10, **← →** navegan, **⌫** une el chop con el anterior, **espacio** play/stop, **Esc** para.

### Loop
- Botón **🔁 de cada pad** (o tecla **L**): repite ese chop sin cortes; vuelve a pulsarlo para parar.
- El botón de loop de la barra de transporte hace que todos los chops se repitan al dispararlos; si lo cambias mientras suena, se aplica al momento.

### Quitar la voz (instrumental)
- Botón **Quitar voz** (arriba): separa la voz con IA (Demucs `htdemucs`, de Meta) usando la GPU. Tarda unos segundos.
- Si la grabación no tiene voz, lo detecta y deja el audio original (**Sin voz**).
- Pulsa **Instrumental** para volver al original y otra vez para el instrumental (no vuelve a separar).
- Lo que escuchas, la onda y los chops que arrastras usan la versión activa (los del instrumental llevan "Inst" en el nombre).
- Requiere instalar Demucs una vez (~430 MB en `~/Library/Application Support/Recorded/demucs-env`):

```bash
./tools/setup-demucs.sh
```

### Zoom
- **Pellizco en el trackpad**: acercar/alejar alrededor del cursor. Al alejar se detiene en la vista completa.
- **Dos dedos en horizontal**: desplazarte por la onda. **⌘ o ⌥ + scroll**: zoom (útil con ratón).
- Teclado: ⌘+ / ⌘- / ⌘0 (ver todo).

### Arrastrar a Koala
- Cada **pad** de abajo se arrastra como WAV (clic para oírlo).
- **Arrastrar todos** suelta todos los chops a la vez.
- Sin cortes, el pad único es la grabación entera.

Los WAV se generan en la carpeta temporal del sistema al arrastrar. La grabación se borra al cerrar la app.

> Nota: está firmada ad-hoc, así que al recompilar macOS puede volver a pedir el permiso. Si creas un certificado de firma de código llamado "Recorded Dev" en Acceso a Llaveros, `build.sh` lo usa y el permiso se conserva.

### Autoprueba de calidad

```bash
build/Recorded.app/Contents/MacOS/Recorded --selftest /tmp/prueba.caf 8
```

Graba 8 segundos del audio del sistema con el mismo grabador de la app y sale.
