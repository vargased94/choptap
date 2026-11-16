"""Separa voz e instrumental con Demucs (htdemucs) para Recorded.

Uso: python separate.py entrada salida_instrumental.wav salida_voz.wav
Imprime líneas JSON de progreso y un resultado final:
  {"status": "done", "vocal_ratio": 0.31}
  {"status": "no_vocals", "vocal_ratio": 0.02}
"""
import json
import os
import sys

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def emit(**kw):
    print(json.dumps(kw), flush=True)


def main():
    src, out_inst, out_voc = sys.argv[1], sys.argv[2], sys.argv[3]
    import numpy as np
    import soundfile as sf
    import torch
    from demucs.apply import apply_model
    from demucs.audio import convert_audio
    from demucs.pretrained import get_model

    emit(status="loading")
    data, sr = sf.read(src, dtype="float32", always_2d=True)  # (frames, channels)
    mix = torch.from_numpy(data.T.copy())
    model = get_model("htdemucs")
    model.eval()
    wav = convert_audio(mix, sr, model.samplerate, model.audio_channels)

    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    normed = (wav - mean) / std

    devices = []
    if torch.backends.mps.is_available():
        devices.append("mps")
    devices.append("cpu")
    sources = None
    for device in devices:
        try:
            emit(status="separating", device=device)
            with torch.no_grad():
                sources = apply_model(model, normed[None], device=device, split=True,
                                      overlap=0.25, progress=False)[0]
            break
        except Exception as exc:  # p. ej. operación no soportada en MPS
            emit(status="retry", device=device, error=str(exc)[:200])
    if sources is None:
        emit(status="error", error="No se pudo separar el audio")
        sys.exit(1)

    sources = sources * std + mean
    names = model.sources
    vocals = sources[names.index("vocals")]
    inst = sum(sources[i] for i, n in enumerate(names) if n != "vocals")

    def rms(x):
        return float(torch.sqrt((x ** 2).mean()) + 1e-12)

    ratio = rms(vocals) / max(rms(wav), 1e-9)

    # Volver a la frecuencia y canales originales
    inst = convert_audio(inst, model.samplerate, sr, mix.shape[0])
    vocals = convert_audio(vocals, model.samplerate, sr, mix.shape[0])
    n = mix.shape[1]
    inst, vocals = inst[:, :n], vocals[:, :n]

    sf.write(out_inst, inst.T.numpy(), sr, subtype="FLOAT")
    sf.write(out_voc, vocals.T.numpy(), sr, subtype="FLOAT")
    # Por debajo de ~-24 dB respecto a la mezcla consideramos que no hay voz.
    emit(status="done" if ratio >= 0.063 else "no_vocals", vocal_ratio=round(ratio, 4))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit(status="error", error=str(exc)[:500])
        sys.exit(1)
