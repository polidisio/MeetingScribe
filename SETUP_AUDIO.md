# Audio MIDI Setup para MeetingScribe con BlackHole

## Objetivo
Capturar AMBOS lados de una llamada de Teams:
- Tu voz (micrófono)
- Audio de participantes remotos (lo que escuchas)

## Pasos en Audio MIDI Setup

### 1. Crear Multi-Output Device (para reproducción)

Este dispositivo es para Teams y sistema. Envía audio a tus AirPods Y a BlackHole simultáneamente.

1. Abre **Audio MIDI Setup** (Aplicaciones > Utilidades)
2. Haz clic en el botón **+** en la esquina inferior izquierda
3. Selecciona **"Create Multi-Output Device"**
4. Dale el nombre: `Meeting Capture Output`
5. En la lista, activa (checkbox):
   - **BlackHole 2ch**
   - **AirPods** (o tu dispositivo de auriculares)
6. Selecciona **AirPods como master device** (radio button)
7. En la columna "Drift Correction", activa solo **BlackHole** (no AirPods)
8. Click en **Done** o presiona Enter

### 2. Crear Aggregate Device (para captura de MeetingScribe)

Este dispositivo es SOLO para MeetingScribe. Combina el audio remoto (BlackHole) + tu micrófono (AirPods).

1. Haz clic de nuevo en **+**
2. Selecciona **"Create Aggregate Device"**
3. Dale el nombre: `MeetingScribe Capture`
4. En la lista inferior, activa:
   - **BlackHole 2ch**
   - **AirPods** (el dispositivo, no solo el micrófono)
5. Selecciona **BlackHole como master device** (importante para sincronización)
6. Click en **Done** o presiona Enter

### 3. Configurar Teams

1. Abre **Teams > Preferencias**
2. Ve a **Audio Devices**
3. **Speaker (salida)**: `Meeting Capture Output` (el Multi-Output Device)
4. **Microphone (entrada)**: Selecciona tu micrófono físico:
   - Si tienes AirPods: `AirPods Pro` o similar (el mic físico, NO el Aggregate)
   - Si no: `Built-in Microphone` o tu micrófono USB
5. **Speaker volume**: Ajusta al nivel normal
6. Cierra Preferencias

### 4. Configurar MeetingScribe

1. Haz clic en el icono de MeetingScribe en la barra de menú
2. En el menú que aparece, verás un dropdown "Audio Source"
3. Selecciona: **`MeetingScribe Capture`** (el Aggregate Device que acabas de crear)
4. Verifica que aparezca en el dropdown. Si no lo ves, reinicia la app.

## Verificación

1. En una llamada de Teams con otro dispositivo:
2. Habla desde ambos lados (desde tu Mac Y desde la otra parte)
3. Inicia grabación en MeetingScribe
4. Verifica que:
   - ✅ Se captura tu voz Y la voz remota
   - ✅ La transcripción no está cortada
   - ✅ Aparecen todas las personas hablando (no solo una)

## Diagrama del Flujo

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  RED / INTERNET                                                 │
│  (llamada de Teams)                                             │
│                                                                 │
└──────────────┬──────────────────────────────────────────────────┘
               │
               ↓
         ┌─────────────┐
         │   TEAMS     │
         └──┬──────┬───┘
            │      │
      Input │      │ Output
            │      ↓
            │   ┌──────────────────────────────────┐
            │   │ Multi-Output Device              │
            │   │ "Meeting Capture Output"         │
            │   │ (AirPods + BlackHole)            │
            │   └────┬─────────────────┬───────────┘
            │        │                 │
            │        ↓ Output          ↓ Output
            │     ┌────────┐      ┌──────────┐
            │     │AirPods │ ← ← ← BlackHole │ (capturado)
            │     │(oyes)  │      │ (loopback)
            │     └────────┘      └──────────┘
            │        ↑                  ↑
            │        │                  │
            │    Tu voz              Tu voz +
            │   (auriculares)        Audio remoto
            │        │                  │
            │        ↓ Input             ↓ Input
            │     ┌──────────────────────────────────┐
            │     │ Aggregate Device                 │
            │     │ "MeetingScribe Capture"          │
            │     │ (AirPods mic + BlackHole)        │
            │     └──────────────┬───────────────────┘
            │                    │
            │                    ↓
            └─→ AirPods mic   MeetingScribe
                               (app)
                                 │
                                 ↓
                          Speech Recognition
                          (transcripción)
```

## Solución de Problemas

**Q: MeetingScribe dice "No audio device found"**
- R: Verifica que el Aggregate Device `MeetingScribe Capture` existe en Audio MIDI Setup
- R: Asegúrate de que BlackHole está instalado (`brew install blackhole-2ch`)

**Q: Mi voz sigue sin capturarse**
- R: Verifica que el Aggregate Device incluye el dispositivo de micrófono (AirPods)
- R: Selecciona el Aggregate Device en el picker de MeetingScribe (no simplemente "Auto-detect")

**Q: Escucho eco o feedback**
- R: Verifica que Teams NO está usando el Aggregate Device como entrada
- R: Teams debe usar SOLO el micrófono físico (AirPods), no el Aggregate

**Q: La transcripción sigue siendo de pésima calidad**
- R: Verifica que el Master Device en el Aggregate es BlackHole
- R: Reinicia MeetingScribe después de cambiar dispositivos en Audio MIDI Setup
