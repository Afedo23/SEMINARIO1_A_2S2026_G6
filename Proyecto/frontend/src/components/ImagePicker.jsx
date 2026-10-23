import { useEffect, useRef, useState } from 'react';
import { prepareImage } from '../api.js';

// Elegir un archivo o tomar una foto con la webcam. Llama onChange(blob) con la imagen elegida.
export default function ImagePicker({ onChange, label = 'Imagen' }) {
  const [preview, setPreview] = useState(null);
  const [camOn, setCamOn] = useState(false);
  const [error, setError] = useState('');
  const videoRef = useRef(null);
  const streamRef = useRef(null);

  const stopCam = () => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    setCamOn(false);
  };
  useEffect(() => stopCam, []);

  const choose = async (blob) => {
    const { dataUrl } = await prepareImage(blob, 640);
    setPreview(dataUrl);
    onChange(blob);
  };

  const onFile = async (e) => {
    const f = e.target.files?.[0];
    if (!f) return;
    setError('');
    try { await choose(f); } catch { setError('No se pudo leer esa imagen. Prueba con un JPG o PNG.'); }
  };

  const openCam = async () => {
    setError('');
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user' } });
      streamRef.current = stream;
      setCamOn(true);
      requestAnimationFrame(() => { if (videoRef.current) videoRef.current.srcObject = stream; });
    } catch {
      setError('No hay acceso a la cámara. El navegador solo la permite en páginas HTTPS (o localhost) y con permiso concedido. Mientras tanto, elige un archivo.');
    }
  };

  const snap = () => {
    const v = videoRef.current;
    const c = document.createElement('canvas');
    c.width = v.videoWidth; c.height = v.videoHeight;
    c.getContext('2d').drawImage(v, 0, 0);
    c.toBlob(async (b) => { await choose(b); stopCam(); }, 'image/jpeg', 0.9);
  };

  return (
    <div className="picker">
      <span className="field-label">{label}</span>
      {camOn ? (
        <div className="cam">
          <video ref={videoRef} autoPlay playsInline muted />
          <div className="row">
            <button type="button" className="btn" onClick={snap}>Tomar foto</button>
            <button type="button" className="btn ghost" onClick={stopCam}>Cancelar</button>
          </div>
        </div>
      ) : (
        <div className="picker-body">
          {preview ? <img src={preview} alt="Vista previa" /> : <div className="picker-empty">Sin imagen</div>}
          <div className="row">
            <label className="btn ghost">
              Elegir archivo
              <input type="file" accept="image/*" hidden onChange={onFile} />
            </label>
            <button type="button" className="btn ghost" onClick={openCam}>Usar cámara</button>
          </div>
        </div>
      )}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
