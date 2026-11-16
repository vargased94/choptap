#!/bin/zsh
# Instala Demucs (separación de voces) en un entorno Python aislado para ChopTap.
set -euo pipefail
ENV="$HOME/Library/Application Support/ChopTap/demucs-env"
PY="${CHOPTAP_PYTHON:-/usr/bin/python3}"
mkdir -p "$(dirname "$ENV")"
if [ ! -x "$ENV/bin/python" ]; then
  "$PY" -m venv "$ENV"
fi
"$ENV/bin/python" -m pip install --upgrade pip
"$ENV/bin/python" -m pip install "demucs==4.0.1" soundfile numpy
# Descarga los pesos del modelo htdemucs (~80 MB) para que la primera separación sea rápida.
"$ENV/bin/python" -c "from demucs.pretrained import get_model; get_model('htdemucs'); print('Modelo listo')"
cp "$(dirname "$0")/separate.py" "$ENV/separate.py"
echo "Demucs instalado en: $ENV"
