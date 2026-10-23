import { useCallback, useEffect, useState } from 'react';
import { api, fecha, uploadImage } from '../api.js';
import ImagePicker from '../components/ImagePicker.jsx';
import TextBlock from '../components/TextBlock.jsx';

// Cada etiqueta de Rekognition recibe un color propio (siempre el mismo para el mismo nombre)
const hue = (s) => { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 360; return h; };

const Heart = ({ filled }) => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
    <path
      d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"
      fill={filled ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="2" strokeLinejoin="round"
    />
  </svg>
);

function Composer({ onPosted }) {
  const [img, setImg] = useState(null);
  const [desc, setDesc] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [key, setKey] = useState(0); // reinicia el selector de imagen

  const publish = async (e) => {
    e.preventDefault();
    setError('');
    if (!img) return setError('Elige o toma una imagen para publicar');
    setBusy(true);
    try {
      const up = await uploadImage('Fotos_Publicadas', img);   // API Gateway -> Lambda -> S3 + Rekognition
      await api.post('/api/publicaciones', { imagenUrl: up.url, descripcion: desc, etiquetas: up.labels });
      setImg(null); setDesc(''); setKey((k) => k + 1);
      onPosted();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  };

  return (
    <form className="card composer" onSubmit={publish}>
      <ImagePicker key={key} label="Nueva publicación" onChange={setImg} />
      <label>Descripción (opcional)
        <textarea value={desc} onChange={(e) => setDesc(e.target.value)} rows={2} maxLength={500} />
      </label>
      {error && <p className="error">{error}</p>}
      <button className="btn" disabled={busy}>{busy ? 'Publicando…' : 'Publicar'}</button>
    </form>
  );
}

function Post({ p, index, onCommented }) {
  const [texto, setTexto] = useState('');
  const [error, setError] = useState('');
  const [liked, setLiked] = useState(p.me_gusta);
  const [likes, setLikes] = useState(p.likes);
  const [pop, setPop] = useState(false);
  const [burst, setBurst] = useState(false);

  useEffect(() => { setLiked(p.me_gusta); setLikes(p.likes); }, [p.me_gusta, p.likes]);

  const toggleLike = async () => {
    const prev = { liked, likes };
    setLiked(!liked); setLikes(likes + (liked ? -1 : 1));      // respuesta inmediata
    setPop(true); setTimeout(() => setPop(false), 450);
    try {
      const r = await api.post(`/api/publicaciones/${p.id}/like`);
      setLiked(r.meGusta); setLikes(r.likes);
    } catch (err) { setLiked(prev.liked); setLikes(prev.likes); setError(err.message); }
  };

  const doubleTap = () => {
    if (!liked) toggleLike();
    setBurst(true); setTimeout(() => setBurst(false), 750);
  };

  const send = async (e) => {
    e.preventDefault();
    if (!texto.trim()) return;
    setError('');
    try {
      await api.post(`/api/publicaciones/${p.id}/comentarios`, { texto });
      setTexto('');
      onCommented();
    } catch (err) { setError(err.message); }
  };

  return (
    <article className="card post" style={{ animationDelay: `${Math.min(index, 6) * 70}ms` }}>
      <header className="post-head">
        <img className="avatar" src={p.foto_perfil_url} alt="" />
        <div>
          <strong>{p.nombre_completo}</strong>
          <time>{fecha(p.creado_en)}</time>
        </div>
      </header>
      <div className="post-media" onDoubleClick={doubleTap}>
        <img className="post-img" src={p.imagen_url} alt={p.descripcion || 'Publicación'} loading="lazy" />
        {burst && <span className="burst"><Heart filled /></span>}
      </div>
      <div className="post-actions">
        <button type="button" className={`like-btn ${liked ? 'liked' : ''} ${pop ? 'pop' : ''}`} onClick={toggleLike} aria-pressed={liked} aria-label="Me gusta">
          <Heart filled={liked} />
          <span>{likes}</span>
        </button>
        <span className="muted">{p.comentarios.length} {p.comentarios.length === 1 ? 'comentario' : 'comentarios'}</span>
      </div>
      {p.etiquetas.length > 0 && (
        <ul className="tags">
          {p.etiquetas.map((t) => <li key={t.name} className="tag" style={{ '--h': hue(t.name) }}>{t.name}</li>)}
        </ul>
      )}
      {p.descripcion && <TextBlock text={p.descripcion} />}
      <section className="comments">
        {p.comentarios.map((c) => (
          <div key={c.id} className="comment">
            <strong>{c.nombre_completo}</strong>
            <TextBlock text={c.texto} />
          </div>
        ))}
        <form className="row" onSubmit={send}>
          <input value={texto} onChange={(e) => setTexto(e.target.value)} placeholder="Escribe un comentario" maxLength={500} />
          <button className="btn small">Comentar</button>
        </form>
        {error && <p className="error">{error}</p>}
      </section>
    </article>
  );
}

const Skeleton = () => (
  <div className="card post" aria-hidden="true">
    <div className="skeleton line short" /><div className="skeleton img" /><div className="skeleton line" />
  </div>
);

export default function Feed() {
  const [posts, setPosts] = useState(null);
  const [tags, setTags] = useState(['Todos']);
  const [tag, setTag] = useState('Todos');
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');

  const load = useCallback(async (fresh = false) => {
    setError('');
    const qs = new URLSearchParams();
    if (tag !== 'Todos') qs.set('etiqueta', tag);
    if (search.trim()) qs.set('buscar', search.trim());
    if (fresh) qs.set('fresh', '1');
    try {
      const [p, t] = await Promise.all([api.get(`/api/publicaciones?${qs}`), api.get('/api/etiquetas')]);
      setPosts(p); setTags(t);
    } catch (e) { setError(e.message); setPosts([]); }
  }, [tag, search]);

  useEffect(() => { const id = setTimeout(load, 250); return () => clearTimeout(id); }, [load]);

  return (
    <div className="feed">
      <div className="feed-main">
        <Composer onPosted={() => load(true)} />
        {error && <p className="error">{error}</p>}
        {posts === null && <><Skeleton /><Skeleton /></>}
        {posts && posts.length === 0 && !error && (
          <p className="empty">
            {tag !== 'Todos' || search ? 'Ninguna publicación coincide con ese filtro.' : 'Todavía no hay publicaciones. Sube la primera o agrega amigos para ver las suyas.'}
          </p>
        )}
        {posts && posts.map((p, i) => <Post key={p.id} p={p} index={i} onCommented={() => load(true)} />)}
      </div>
      <aside className="feed-side">
        <label>Buscar etiqueta
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Por ejemplo: dog, person…" />
        </label>
        <div className="filters" role="group" aria-label="Filtrar por etiqueta">
          {tags.map((t) => (
            <button
              key={t}
              className={`chip-btn ${t === 'Todos' ? '' : 'tagchip'} ${t === tag ? 'on' : ''}`}
              style={t === 'Todos' ? undefined : { '--h': hue(t) }}
              onClick={() => setTag(t)}
            >{t}</button>
          ))}
        </div>
        <p className="hint">Las etiquetas las genera Amazon Rekognition al publicar una imagen. Solo aparecen las de las publicaciones que puedes ver.</p>
      </aside>
    </div>
  );
}
