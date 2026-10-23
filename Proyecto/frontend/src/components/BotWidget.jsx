import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';

const SUGERENCIAS = ['¿A qué hora abren?', '¿Dónde queda la facultad?', '¿Qué carreras hay?'];

// Botón de acceso al bot de Amazon Lex (consultas sobre la Facultad de Ingeniería)
export default function BotWidget() {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [msgs, setMsgs] = useState([{ from: 'bot', text: 'Hola, soy el asistente de la Facultad de Ingeniería. ¿En qué te ayudo?' }]);
  const [busy, setBusy] = useState(false);
  const endRef = useRef(null);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [msgs, open]);

  const ask = async (q) => {
    const t = q.trim();
    if (!t || busy) return;
    setText(''); setBusy(true);
    setMsgs((m) => [...m, { from: 'me', text: t }]);
    try {
      const r = await api.post('/api/bot', { texto: t });
      setMsgs((m) => [...m, { from: 'bot', text: r.respuesta }]);
    } catch (e) {
      setMsgs((m) => [...m, { from: 'bot', text: `No pude responder: ${e.message}` }]);
    } finally { setBusy(false); }
  };

  return (
    <>
      <button className="bot-fab" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? 'Cerrar asistente' : 'Preguntar a la facultad'}
      </button>
      {open && (
        <section className="bot-panel" aria-label="Asistente de la facultad">
          <div className="bot-body">
            {msgs.map((m, i) => <p key={i} className={`bot-msg ${m.from}`}>{m.text}</p>)}
            {msgs.length === 1 && (
              <div className="filters">{SUGERENCIAS.map((s) => <button key={s} className="chip-btn" onClick={() => ask(s)}>{s}</button>)}</div>
            )}
            <div ref={endRef} />
          </div>
          <form className="row" onSubmit={(e) => { e.preventDefault(); ask(text); }}>
            <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Escribe tu pregunta" />
            <button className="btn small" disabled={busy}>Enviar</button>
          </form>
        </section>
      )}
    </>
  );
}
