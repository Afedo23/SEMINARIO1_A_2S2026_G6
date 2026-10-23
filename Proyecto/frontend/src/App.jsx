import { useState } from 'react';
import { auth } from './api.js';
import Auth from './pages/Auth.jsx';
import Feed from './pages/Feed.jsx';
import People from './pages/People.jsx';
import Chat from './pages/Chat.jsx';
import Profile from './pages/Profile.jsx';
import BotWidget from './components/BotWidget.jsx';
import Fx from './components/Fx.jsx';

const VIEWS = [['inicio', 'Inicio'], ['personas', 'Personas'], ['chat', 'Chat'], ['perfil', 'Perfil']];

export default function App() {
  const [user, setUser] = useState(auth.user && auth.token ? auth.user : null);
  const [view, setView] = useState('inicio');

  const logout = () => { auth.clear(); setUser(null); setView('inicio'); };

  return (
    <>
      <Fx />
      {!user ? <Auth onLogged={setUser} /> : (
        <div className="app">
          <header className="topbar">
            <span className="brand">semi<span>·</span>social</span>
            <nav aria-label="Secciones">
              {VIEWS.map(([k, n]) => (
                <button key={k} className={view === k ? 'on' : ''} onClick={() => setView(k)}>{n}</button>
              ))}
            </nav>
            <div className="me">
              <img className="avatar" src={user.foto_perfil_url} alt="" />
              <span>{user.nombre_completo}</span>
              <button className="link" onClick={logout}>Cerrar sesión</button>
            </div>
          </header>
          <main className="content view-enter" key={view}>
            {view === 'inicio' && <Feed />}
            {view === 'personas' && <People />}
            {view === 'chat' && <Chat />}
            {view === 'perfil' && <Profile onUpdated={() => setUser(auth.user)} />}
          </main>
          <BotWidget />
        </div>
      )}
    </>
  );
}
