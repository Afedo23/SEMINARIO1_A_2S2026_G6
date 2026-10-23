import { useState } from 'react';
import { api, auth, prepareImage, uploadImage } from '../api.js';
import ImagePicker from '../components/ImagePicker.jsx';

function Login({ onLogged, goRegister }) {
  const [mode, setMode] = useState('clave'); // clave | rostro
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [shot, setShot] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setError(''); setBusy(true);
    try {
      let r;
      if (mode === 'clave') {
        r = await api.post('/api/auth/login', { username, password });
      } else {
        if (!shot) throw new Error('Toma una foto de tu rostro');
        const { base64 } = await prepareImage(shot, 800);
        r = await api.post('/api/auth/login-facial', { username, imageBase64: base64 });
      }
      auth.save(r.token, r.usuario);
      onLogged(r.usuario);
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  };

  return (
    <form className="auth-form" onSubmit={submit}>
      <h2>Inicia sesión</h2>
      <div className="seg">
        <button type="button" className={mode === 'clave' ? 'on' : ''} onClick={() => setMode('clave')}>Con contraseña</button>
        <button type="button" className={mode === 'rostro' ? 'on' : ''} onClick={() => setMode('rostro')}>Con mi rostro</button>
      </div>
      <label>Nombre de usuario<input value={username} onChange={(e) => setUsername(e.target.value)} autoComplete="username" required /></label>
      {mode === 'clave'
        ? <label>Contraseña<input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" required /></label>
        : <ImagePicker label="Tu rostro" onChange={setShot} />}
      {error && <p className="error">{error}</p>}
      <button className="btn" disabled={busy}>{busy ? 'Entrando…' : 'Entrar'}</button>
      <p className="switch">¿Aún no tienes cuenta? <button type="button" className="link" onClick={goRegister}>Crear cuenta</button></p>
    </form>
  );
}

function Register({ goLogin }) {
  const [f, setF] = useState({ username: '', nombre: '', correo: '', dpi: '', password: '', repetir: '' });
  const [foto, setFoto] = useState(null);
  const [step, setStep] = useState('datos'); // datos | codigo
  const [code, setCode] = useState('');
  const [msg, setMsg] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  const submit = async (e) => {
    e.preventDefault();
    setError(''); setBusy(true);
    try {
      if (!foto) throw new Error('La foto de perfil es obligatoria');
      if (f.password !== f.repetir) throw new Error('Las contraseñas no coinciden');
      const up = await uploadImage('Fotos_Perfil', foto);
      const r = await api.post('/api/auth/register', { ...f, fotoUrl: up.url });
      setMsg(r.mensaje); setStep('codigo');
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  };

  const confirm = async (e) => {
    e.preventDefault();
    setError(''); setBusy(true);
    try {
      await api.post('/api/auth/confirm', { username: f.username, code });
      goLogin();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  };

  if (step === 'codigo') {
    return (
      <form className="auth-form" onSubmit={confirm}>
        <h2>Verifica tu correo</h2>
        <p className="muted">{msg}</p>
        <label>Código de verificación<input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" required /></label>
        {error && <p className="error">{error}</p>}
        <button className="btn" disabled={busy}>{busy ? 'Verificando…' : 'Verificar correo'}</button>
      </form>
    );
  }

  return (
    <form className="auth-form" onSubmit={submit}>
      <h2>Crea tu cuenta</h2>
      <label>Nombre completo<input value={f.nombre} onChange={set('nombre')} required /></label>
      <label>Nombre de usuario<input value={f.username} onChange={set('username')} autoComplete="username" required /></label>
      <label>Correo electrónico<input type="email" value={f.correo} onChange={set('correo')} required /></label>
      <label>DPI (13 dígitos)<input value={f.dpi} onChange={set('dpi')} inputMode="numeric" pattern="\d{13}" required /></label>
      <label>Contraseña<input type="password" value={f.password} onChange={set('password')} minLength={8} autoComplete="new-password" required /></label>
      <label>Repetir contraseña<input type="password" value={f.repetir} onChange={set('repetir')} autoComplete="new-password" required /></label>
      <p className="hint">Mínimo 8 caracteres con mayúscula, minúscula y número.</p>
      <ImagePicker label="Foto de perfil (se usa para entrar con tu rostro)" onChange={setFoto} />
      {error && <p className="error">{error}</p>}
      <button className="btn" disabled={busy}>{busy ? 'Creando cuenta…' : 'Crear cuenta'}</button>
      <p className="switch">¿Ya tienes cuenta? <button type="button" className="link" onClick={goLogin}>Inicia sesión</button></p>
    </form>
  );
}

export default function Auth({ onLogged }) {
  const [view, setView] = useState('login');
  return (
    <main className="auth">
      <section className="auth-hero">
        <h1>semi<span>·</span>social</h1>
        <p>La red de tu grupo de Seminario. Comparte fotos, comenta con tus amigos y chatea en tiempo real.</p>
      </section>
      <section className="auth-card">
        {view === 'login'
          ? <Login onLogged={onLogged} goRegister={() => setView('registro')} />
          : <Register goLogin={() => setView('login')} />}
      </section>
    </main>
  );
}
