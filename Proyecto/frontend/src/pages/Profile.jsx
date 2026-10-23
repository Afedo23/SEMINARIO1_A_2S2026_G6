import { useEffect, useState } from 'react';
import { api, auth, uploadImage } from '../api.js';
import ImagePicker from '../components/ImagePicker.jsx';

export default function Profile({ onUpdated }) {
  const [me, setMe] = useState(null);
  const [nombre, setNombre] = useState('');
  const [dpi, setDpi] = useState('');
  const [foto, setFoto] = useState(null);
  const [password, setPassword] = useState('');
  const [msg, setMsg] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api.get('/api/me').then((m) => { setMe(m); setNombre(m.nombre_completo); setDpi(m.dpi); }).catch((e) => setError(e.message));
  }, []);

  const save = async (e) => {
    e.preventDefault();
    setError(''); setMsg(''); setBusy(true);
    try {
      let fotoUrl;
      if (foto) fotoUrl = (await uploadImage('Fotos_Perfil', foto)).url;
      await api.put('/api/me', { nombre, dpi, fotoUrl, password });
      const nuevo = await api.get('/api/me');
      setMe(nuevo); setPassword('');
      auth.setUser({ ...auth.user, nombre_completo: nuevo.nombre_completo, foto_perfil_url: nuevo.foto_perfil_url });
      onUpdated();
      setMsg('Perfil actualizado');
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  };

  if (!me) return <p className="muted">{error || 'Cargando perfil…'}</p>;

  return (
    <form className="card profile" onSubmit={save}>
      <h2>Tu perfil</h2>
      <div className="profile-id">
        <img className="avatar big" src={me.foto_perfil_url} alt="Tu foto de perfil" />
        <div><strong>@{me.username}</strong><span className="muted">{me.correo}</span></div>
      </div>
      <label>Nombre completo<input value={nombre} onChange={(e) => setNombre(e.target.value)} required /></label>
      <label>DPI<input value={dpi} onChange={(e) => setDpi(e.target.value)} inputMode="numeric" pattern="\d{13}" required /></label>
      <ImagePicker label="Cambiar foto de perfil (opcional)" onChange={setFoto} />
      <label>Contraseña actual (para guardar los cambios)
        <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" required />
      </label>
      {msg && <p className="ok">{msg}</p>}
      {error && <p className="error">{error}</p>}
      <button className="btn" disabled={busy}>{busy ? 'Guardando…' : 'Guardar cambios'}</button>
    </form>
  );
}
