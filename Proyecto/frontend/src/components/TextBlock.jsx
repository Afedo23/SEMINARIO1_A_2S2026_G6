import { useState } from 'react';
import { api } from '../api.js';

const IDIOMAS = [['es', 'Español'], ['en', 'Inglés'], ['fr', 'Francés'], ['pt', 'Portugués']];

// Muestra un texto (descripcion o comentario) con "Traducir" (Translate) y "Escuchar" (Polly).
// "Texto en" = idioma en que esta escrito el original (por defecto español).
export default function TextBlock({ text }) {
  const [src, setSrc] = useState('es');      // idioma del texto original
  const [dest, setDest] = useState('en');    // idioma al que se traduce
  const [shown, setShown] = useState(text);
  const [translatedTo, setTranslatedTo] = useState(null); // null = se muestra el original
  const [audio, setAudio] = useState(null);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');

  const lang = translatedTo || src;          // idioma del texto que se ve (para la voz de Polly)

  const translate = async () => {
    setError(''); setAudio(null); setBusy('t');
    try {
      const r = await api.post('/api/traducir', { texto: text, origen: src, destino: dest });
      setShown(r.texto); setTranslatedTo(dest);
    } catch (e) { setError(e.message); } finally { setBusy(''); }
  };

  const listen = async () => {
    setError(''); setBusy('l');
    try {
      const r = await api.post('/api/escuchar', { texto: shown, idioma: lang });
      setAudio(r.url);
    } catch (e) { setError(e.message); } finally { setBusy(''); }
  };

  const original = () => { setShown(text); setTranslatedTo(null); setAudio(null); };

  return (
    <div className="tb">
      <p className="tb-text">{shown}</p>
      <div className="tb-tools">
        <select value={src} onChange={(e) => { setSrc(e.target.value); original(); }} aria-label="Idioma del texto original" title="Idioma en que está escrito">
          {IDIOMAS.map(([k, n]) => <option key={k} value={k}>Texto en {n}</option>)}
        </select>
        <select value={dest} onChange={(e) => setDest(e.target.value)} aria-label="Idioma de destino">
          {IDIOMAS.map(([k, n]) => <option key={k} value={k}>Traducir a {n}</option>)}
        </select>
        <button type="button" className="chip-btn" onClick={translate} disabled={busy === 't'}>{busy === 't' ? 'Traduciendo…' : 'Traducir'}</button>
        <button type="button" className="chip-btn" onClick={listen} disabled={busy === 'l'}>{busy === 'l' ? 'Generando…' : 'Escuchar'}</button>
        {translatedTo && <button type="button" className="chip-btn" onClick={original}>Ver original</button>}
      </div>
      {audio && <audio controls autoPlay src={audio} />}
      {error && <p className="error">{error}</p>}
    </div>
  );
}
