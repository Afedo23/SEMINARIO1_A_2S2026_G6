// URLs que inyecta el build (infra/09-frontend.sh las escribe en .env.production)
const API = (import.meta.env.VITE_API_URL || '').replace(/\/$/, '');     // http://<DNS del ALB>
const UPLOAD = import.meta.env.VITE_UPLOAD_URL || '';                    // https://<api-id>.execute-api.../upload

export const auth = {
  get token() { return localStorage.getItem('token'); },
  get user() { try { return JSON.parse(localStorage.getItem('usuario')); } catch { return null; } },
  save(token, usuario) { localStorage.setItem('token', token); localStorage.setItem('usuario', JSON.stringify(usuario)); },
  setUser(usuario) { localStorage.setItem('usuario', JSON.stringify(usuario)); },
  clear() { localStorage.removeItem('token'); localStorage.removeItem('usuario'); },
};

async function request(path, method = 'GET', body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(auth.token ? { Authorization: `Bearer ${auth.token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && auth.token && !path.startsWith('/api/auth') && path !== '/api/me') {
    auth.clear();
    window.location.reload();
  }
  if (!res.ok) throw new Error(data.error || 'No se pudo conectar con el servidor');
  return data;
}

export const api = {
  get: (p) => request(p),
  post: (p, b) => request(p, 'POST', b || {}),
  put: (p, b) => request(p, 'PUT', b || {}),
};

// Convierte cualquier imagen (archivo o foto de camara) a JPEG de maximo 1280px, para que
// pese poco (limite de 4 MB en Lambda) y Rekognition la acepte.
export async function prepareImage(blob, maxDim = 1280) {
  const bmp = await createImageBitmap(blob);
  const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bmp.width * scale);
  canvas.height = Math.round(bmp.height * scale);
  canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height);
  const dataUrl = canvas.toDataURL('image/jpeg', 0.85);
  return { dataUrl, base64: dataUrl.split(',')[1] };
}

// Sube por API Gateway -> Lambda -> S3. Devuelve { key, url, labels }
export async function uploadImage(folder, blob) {
  const { base64 } = await prepareImage(blob);
  const res = await fetch(UPLOAD, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folder, contentType: 'image/jpeg', imageBase64: base64 }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'No se pudo subir la imagen');
  return data;
}

export const fecha = (d) => new Date(d).toLocaleString('es-GT', { dateStyle: 'medium', timeStyle: 'short' });
