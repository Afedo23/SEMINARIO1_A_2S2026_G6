import { useEffect, useRef, useState } from 'react';
import { api, auth, fecha } from '../api.js';

function Conversation({ friend }) {
  const me = auth.user;
  const [msgs, setMsgs] = useState([]);
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const lastId = useRef(0);
  const endRef = useRef(null);

  // Polling cada 2.5 s con ?desde=<ultimo id>. Los mensajes viven en RDS, asi que funciona
  // aunque cada amigo este atendido por una instancia distinta del balanceador.
  useEffect(() => {
    let alive = true;
    lastId.current = 0; setMsgs([]);
    const tick = async () => {
      try {
        const nuevos = await api.get(`/api/chat/${friend.id}?desde=${lastId.current}`);
        if (alive && nuevos.length) {
          lastId.current = nuevos[nuevos.length - 1].id;
          setMsgs((m) => [...m, ...nuevos]);
        }
      } catch (e) { if (alive) setError(e.message); }
    };
    tick();
    const id = setInterval(tick, 2500);
    return () => { alive = false; clearInterval(id); };
  }, [friend.id]);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [msgs.length]);

  const send = async (e) => {
    e.preventDefault();
    const t = text.trim();
    if (!t) return;
    setText(''); setError('');
    try { await api.post(`/api/chat/${friend.id}`, { texto: t }); } catch (err) { setError(err.message); setText(t); }
  };

  return (
    <div className="conv">
      <header className="conv-head"><img className="avatar" src={friend.foto_perfil_url} alt="" /><strong>{friend.nombre_completo}</strong></header>
      <div className="conv-body">
        {msgs.length === 0 && <p className="empty">Aún no hay mensajes. Escribe el primero.</p>}
        {msgs.map((m) => (
          <div key={m.id} className={`bubble ${m.de_usuario === me.id ? 'mine' : ''}`}>
            <p>{m.texto}</p><time>{fecha(m.creado_en)}</time>
          </div>
        ))}
        <div ref={endRef} />
      </div>
      {error && <p className="error">{error}</p>}
      <form className="row conv-form" onSubmit={send}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Escribe un mensaje" maxLength={2000} />
        <button className="btn small">Enviar</button>
      </form>
    </div>
  );
}

export default function Chat() {
  const [friends, setFriends] = useState(null);
  const [sel, setSel] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    api.get('/api/amigos').then((f) => { setFriends(f); if (f[0]) setSel(f[0]); }).catch((e) => { setError(e.message); setFriends([]); });
  }, []);

  if (friends === null) return <p className="muted">Cargando amigos…</p>;
  if (friends.length === 0) return <p className="empty">Todavía no tienes amigos. Agrega personas en la sección Personas para chatear.</p>;

  return (
    <div className="chat">
      <nav className="chat-list" aria-label="Amigos">
        {friends.map((f) => (
          <button key={f.id} className={`person-btn ${sel?.id === f.id ? 'on' : ''}`} onClick={() => setSel(f)}>
            <img className="avatar" src={f.foto_perfil_url} alt="" />{f.nombre_completo}
          </button>
        ))}
      </nav>
      {error && <p className="error">{error}</p>}
      {sel && <Conversation friend={sel} />}
    </div>
  );
}
