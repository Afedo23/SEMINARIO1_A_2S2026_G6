import { useEffect, useRef } from 'react';

// Efectos de puntero (no reemplazan el cursor del sistema):
//  - halo que sigue al mouse y crece sobre elementos clicables
//  - onda al pulsar botones
// Se desactiva con "reducir movimiento" y en pantallas tactiles.
const CLICKABLE = 'a,button,select,input,textarea,label,[role="button"]';
const RIPPLE_ON = '.btn,.chip-btn,.seg button,.topbar nav button,.bot-fab,.like-btn';

export default function Fx() {
  const dot = useRef(null);
  const ring = useRef(null);

  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) return undefined;
    const fine = window.matchMedia('(pointer: fine)').matches;
    const body = document.body;
    let x = 0, y = 0, rx = 0, ry = 0, raf = 0, seen = false;

    const ripple = (e) => {
      const el = e.target.closest?.(RIPPLE_ON);
      if (!el || el.disabled) return;
      const r = el.getBoundingClientRect();
      const size = Math.max(r.width, r.height) * 2;
      const s = document.createElement('span');
      s.className = 'ripple';
      s.style.cssText = `width:${size}px;height:${size}px;left:${e.clientX - r.left - size / 2}px;top:${e.clientY - r.top - size / 2}px`;
      el.appendChild(s);
      setTimeout(() => s.remove(), 650);
    };

    const move = (e) => {
      x = e.clientX; y = e.clientY;
      if (!seen) { seen = true; rx = x; ry = y; body.classList.add('fx-on'); }
      body.classList.toggle('fx-hover', !!e.target.closest?.(CLICKABLE));
    };
    const down = (e) => { body.classList.add('fx-down'); ripple(e); };
    const up = () => body.classList.remove('fx-down');
    const leave = () => { seen = false; body.classList.remove('fx-on'); };
    const loop = () => {
      rx += (x - rx) * 0.2; ry += (y - ry) * 0.2;
      if (dot.current) dot.current.style.transform = `translate3d(${x}px,${y}px,0)`;
      if (ring.current) ring.current.style.transform = `translate3d(${rx}px,${ry}px,0)`;
      raf = requestAnimationFrame(loop);
    };

    document.addEventListener('pointerdown', down);
    document.addEventListener('pointerup', up);
    if (fine) {
      document.addEventListener('pointermove', move);
      document.addEventListener('mouseleave', leave);
      raf = requestAnimationFrame(loop);
    }
    return () => {
      cancelAnimationFrame(raf);
      document.removeEventListener('pointerdown', down);
      document.removeEventListener('pointerup', up);
      document.removeEventListener('pointermove', move);
      document.removeEventListener('mouseleave', leave);
      body.classList.remove('fx-on', 'fx-hover', 'fx-down');
    };
  }, []);

  return (
    <>
      <div className="fx-ring" ref={ring} aria-hidden="true"><i /></div>
      <div className="fx-dot" ref={dot} aria-hidden="true"><i /></div>
    </>
  );
}
