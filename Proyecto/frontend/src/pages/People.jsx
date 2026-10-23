import { useCallback, useEffect, useState } from 'react';
import { api, fecha } from '../api.js';

export default function People() {
  const [users, setUsers] = useState(null);
  const [reqs, setReqs] = useState([]);
  const [msg, setMsg] = useState('');
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      const [u, r] = await Promise.all([api.get('/api/usuarios/no-amigos'), api.get('/api/amigos/solicitudes')]);
      setUsers(u); setReqs(r);
    } catch (e) { setError(e.message); setUsers([]); }
  }, []);
  useEffect(() => { load(); }, [load]);

  const act = async (fn) => {
    setError(''); setMsg('');
    try { const r = await fn(); setMsg(r.mensaje); await load(); } catch (e) { setError(e.message); }
  };

  return (
    <div className="stack">
      {msg && <p className="ok">{msg}</p>}
      {error && <p className="error">{error}</p>}

      <section className="card">
        <h2>Solicitudes recibidas</h2>
        {reqs.length === 0 && <p className="muted">No tienes solicitudes pendientes.</p>}
        {reqs.map((r) => (
          <div key={r.id} className="person">
            <img className="avatar" src={r.foto_perfil_url} alt="" />
            <div className="grow"><strong>{r.nombre_completo}</strong><time>{fecha(r.creado_en)}</time></div>
            <button className="btn small" onClick={() => act(() => api.post(`/api/amigos/solicitudes/${r.id}/responder`, { accion: 'aceptar' }))}>Aceptar</button>
            <button className="btn small ghost" onClick={() => act(() => api.post(`/api/amigos/solicitudes/${r.id}/responder`, { accion: 'rechazar' }))}>Rechazar</button>
          </div>
        ))}
      </section>

      <section className="card">
        <h2>Personas que quizá conoces</h2>
        {users === null && <p className="muted">Cargando…</p>}
        {users && users.length === 0 && <p className="empty">No hay más usuarios por agregar.</p>}
        {users && users.map((u) => (
          <div key={u.id} className="person">
            <img className="avatar" src={u.foto_perfil_url} alt="" />
            <div className="grow"><strong>{u.nombre_completo}</strong><span className="muted">@{u.username}</span></div>
            {u.solicitud === 'enviada' && <span className="muted">Solicitud enviada</span>}
            {u.solicitud === 'recibida' && <span className="muted">Te envió una solicitud</span>}
            {!u.solicitud && <button className="btn small" onClick={() => act(() => api.post('/api/amigos/solicitudes', { paraId: u.id }))}>Agregar amigo</button>}
          </div>
        ))}
      </section>
    </div>
  );
}
