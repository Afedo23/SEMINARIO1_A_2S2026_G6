'use strict';
/**
 * Semi-Social | Grupo 6 | Backend Node.js (EC2 #1)
 * Variables de entorno: /etc/semisocial.env (las crea el user-data de 06-compute.sh)
 * Escrituras -> RDS primaria (DB_WRITE_HOST) | lecturas pesadas -> replica (DB_READ_HOST)
 */
const os = require('os');
const crypto = require('crypto');
const express = require('express');
const cors = require('cors');
const jwt = require('jsonwebtoken');
const { Pool } = require('pg');
const {
  CognitoIdentityProviderClient, SignUpCommand, ConfirmSignUpCommand, InitiateAuthCommand,
  AdminGetUserCommand, AdminUpdateUserAttributesCommand,
} = require('@aws-sdk/client-cognito-identity-provider');
const { RekognitionClient, CompareFacesCommand } = require('@aws-sdk/client-rekognition');
const { TranslateClient, TranslateTextCommand } = require('@aws-sdk/client-translate');
const { PollyClient } = require('@aws-sdk/client-polly');
const { getSynthesizeSpeechUrl } = require('@aws-sdk/polly-request-presigner');
const { LexRuntimeV2Client, RecognizeTextCommand } = require('@aws-sdk/client-lex-runtime-v2');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

const {
  PORT = 3000, AWS_REGION = 'us-east-1', DB_WRITE_HOST, DB_READ_HOST, DB_NAME, DB_USER, DB_PASSWORD,
  JWT_SECRET, USER_POOL_ID, COGNITO_CLIENT_ID, IMG_BUCKET, SSM_PREFIX = '/semisocial/g6',
} = process.env;

// ---------- Clientes ----------
const mkPool = (host) => new Pool({
  host, port: 5432, database: DB_NAME, user: DB_USER, password: DB_PASSWORD,
  ssl: { rejectUnauthorized: false }, max: 10, idleTimeoutMillis: 30000,
});
const dbW = mkPool(DB_WRITE_HOST);
const dbR = mkPool(DB_READ_HOST || DB_WRITE_HOST);

const cognito = new CognitoIdentityProviderClient({ region: AWS_REGION });
const rek = new RekognitionClient({ region: AWS_REGION });
const translate = new TranslateClient({ region: AWS_REGION });
const polly = new PollyClient({ region: AWS_REGION });
const lex = new LexRuntimeV2Client({ region: AWS_REGION });
const ssm = new SSMClient({ region: AWS_REGION });

// ---------- Utilidades ----------
const md5 = (s) => crypto.createHash('md5').update(s).digest('hex'); // MD5 exigido por la rubrica
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
const bad = (res, msg, code = 400) => res.status(code).json({ error: msg });
const keyFromUrl = (url) => decodeURIComponent(new URL(url).pathname.slice(1));
const okImgUrl = (url, folder) => typeof url === 'string' && url.includes(`${IMG_BUCKET}.s3.`) && url.includes(`/${folder}/`);
const signToken = (u) => jwt.sign({ id: u.id, username: u.username }, JWT_SECRET, { expiresIn: '8h' });

function auth(req, res, next) {
  const h = req.headers.authorization || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : null;
  if (!t) return bad(res, 'Token requerido', 401);
  try { req.user = jwt.verify(t, JWT_SECRET); next(); } catch { bad(res, 'Token invalido o expirado', 401); }
}

async function areFriends(a, b) {
  const r = await dbW.query('SELECT 1 FROM amigos WHERE usuario_id=$1 AND amigo_id=$2', [a, b]);
  return r.rowCount > 0;
}

const app = express();
app.use(cors());
app.use(express.json({ limit: '8mb' }));
app.use((req, res, next) => { res.setHeader('X-Servidor', `node-${os.hostname()}`); next(); });

// ---------- Salud / balanceador ----------
app.get('/health', (req, res) => res.status(200).send('ok'));          // el ALB usa esta ruta
app.get('/api/info', (req, res) => res.json({ servidor: 'node', host: os.hostname() }));

// ---------- Auth ----------
app.post('/api/auth/register', wrap(async (req, res) => {
  const { username, nombre, correo, dpi, password, repetir, fotoUrl } = req.body;
  if (!username || !nombre || !correo || !dpi || !password || !fotoUrl) return bad(res, 'Faltan datos obligatorios');
  if (password !== repetir) return bad(res, 'Las contrasenas no coinciden');
  if (!/^\d{13}$/.test(dpi)) return bad(res, 'El DPI debe tener 13 digitos');
  if (!okImgUrl(fotoUrl, 'Fotos_Perfil')) return bad(res, 'Foto de perfil invalida (subela por /upload)');

  const dup = await dbW.query('SELECT 1 FROM usuarios WHERE username=$1 OR correo=$2 OR dpi=$3', [username, correo, dpi]);
  if (dup.rowCount) return bad(res, 'Usuario, correo o DPI ya registrado', 409);

  const out = await cognito.send(new SignUpCommand({
    ClientId: COGNITO_CLIENT_ID, Username: username, Password: password,
    UserAttributes: [
      { Name: 'email', Value: correo }, { Name: 'name', Value: nombre }, { Name: 'custom:dpi', Value: dpi },
    ],
  }));
  await dbW.query(
    `INSERT INTO usuarios(cognito_sub,username,nombre_completo,correo,dpi,password_md5,foto_perfil_url)
     VALUES($1,$2,$3,$4,$5,$6,$7)`,
    [out.UserSub, username, nombre, correo, dpi, md5(password), fotoUrl],
  );
  res.status(201).json({ mensaje: 'Registrado. Revisa tu correo e ingresa el codigo de verificacion.' });
}));

app.post('/api/auth/confirm', wrap(async (req, res) => {
  const { username, code } = req.body;
  if (!username || !code) return bad(res, 'Faltan datos');
  await cognito.send(new ConfirmSignUpCommand({ ClientId: COGNITO_CLIENT_ID, Username: username, ConfirmationCode: code }));
  res.json({ mensaje: 'Correo verificado. Ya puedes iniciar sesion.' });
}));

app.post('/api/auth/login', wrap(async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return bad(res, 'Faltan credenciales');
  await cognito.send(new InitiateAuthCommand({
    AuthFlow: 'USER_PASSWORD_AUTH', ClientId: COGNITO_CLIENT_ID,
    AuthParameters: { USERNAME: username, PASSWORD: password },
  }));
  const r = await dbW.query('SELECT id,username,nombre_completo,foto_perfil_url FROM usuarios WHERE username=$1', [username]);
  if (!r.rowCount) return bad(res, 'Usuario no encontrado', 404);
  res.json({ token: signToken(r.rows[0]), usuario: r.rows[0] });
}));

app.post('/api/auth/login-facial', wrap(async (req, res) => {
  const { username, imageBase64 } = req.body;
  if (!username || !imageBase64) return bad(res, 'Faltan datos');
  const r = await dbW.query('SELECT id,username,nombre_completo,foto_perfil_url FROM usuarios WHERE username=$1', [username]);
  if (!r.rowCount) return bad(res, 'Usuario no encontrado', 404);
  const u = r.rows[0];

  const cu = await cognito.send(new AdminGetUserCommand({ UserPoolId: USER_POOL_ID, Username: username }));
  if (cu.UserStatus !== 'CONFIRMED') return bad(res, 'Cuenta sin verificar', 403);

  const bytes = Buffer.from(imageBase64.replace(/^data:image\/\w+;base64,/, ''), 'base64');
  const cmp = await rek.send(new CompareFacesCommand({
    SourceImage: { Bytes: bytes },
    TargetImage: { S3Object: { Bucket: IMG_BUCKET, Name: keyFromUrl(u.foto_perfil_url) } },
    SimilarityThreshold: 90,
  }));
  if (!cmp.FaceMatches || !cmp.FaceMatches.length) return bad(res, 'El rostro no coincide', 401);
  res.json({ token: signToken(u), usuario: u, similitud: cmp.FaceMatches[0].Similarity });
}));

// ---------- Perfil ----------
app.get('/api/me', auth, wrap(async (req, res) => {
  const r = await dbW.query('SELECT id,username,nombre_completo,correo,dpi,foto_perfil_url FROM usuarios WHERE id=$1', [req.user.id]);
  res.json(r.rows[0]);
}));

app.put('/api/me', auth, wrap(async (req, res) => {
  const { nombre, dpi, fotoUrl, password } = req.body;
  const cur = (await dbW.query('SELECT * FROM usuarios WHERE id=$1', [req.user.id])).rows[0];
  if (!password || md5(password) !== cur.password_md5) return bad(res, 'Contrasena incorrecta', 401);
  const n = nombre || cur.nombre_completo;
  const d = dpi || cur.dpi;
  const f = fotoUrl || cur.foto_perfil_url;
  if (!/^\d{13}$/.test(d)) return bad(res, 'El DPI debe tener 13 digitos');
  if (fotoUrl && !okImgUrl(fotoUrl, 'Fotos_Perfil')) return bad(res, 'Foto de perfil invalida');
  try {
    await dbW.query('UPDATE usuarios SET nombre_completo=$1, dpi=$2, foto_perfil_url=$3 WHERE id=$4', [n, d, f, cur.id]);
  } catch (e) { if (e.code === '23505') return bad(res, 'DPI ya registrado', 409); throw e; }
  await cognito.send(new AdminUpdateUserAttributesCommand({
    UserPoolId: USER_POOL_ID, Username: cur.username,
    UserAttributes: [{ Name: 'name', Value: n }, { Name: 'custom:dpi', Value: d }],
  }));
  res.json({ mensaje: 'Perfil actualizado' });
}));

// ---------- Usuarios y amistades ----------
app.get('/api/usuarios/no-amigos', auth, wrap(async (req, res) => {
  const r = await dbW.query(
    `SELECT u.id, u.username, u.nombre_completo, u.foto_perfil_url,
       CASE WHEN EXISTS (SELECT 1 FROM solicitudes_amistad s WHERE s.de_usuario=$1 AND s.para_usuario=u.id AND s.estado='pendiente') THEN 'enviada'
            WHEN EXISTS (SELECT 1 FROM solicitudes_amistad s WHERE s.de_usuario=u.id AND s.para_usuario=$1 AND s.estado='pendiente') THEN 'recibida'
       END AS solicitud
     FROM usuarios u
     WHERE u.id<>$1 AND NOT EXISTS (SELECT 1 FROM amigos a WHERE a.usuario_id=$1 AND a.amigo_id=u.id)
     ORDER BY u.nombre_completo`, [req.user.id]);
  res.json(r.rows);
}));

app.get('/api/amigos', auth, wrap(async (req, res) => {
  const r = await dbW.query(
    `SELECT u.id, u.username, u.nombre_completo, u.foto_perfil_url FROM amigos a
     JOIN usuarios u ON u.id=a.amigo_id WHERE a.usuario_id=$1 ORDER BY u.nombre_completo`, [req.user.id]);
  res.json(r.rows);
}));

app.post('/api/amigos/solicitudes', auth, wrap(async (req, res) => {
  const a = req.user.id; const b = Number(req.body.paraId);
  if (!b || a === b) return bad(res, 'Destino invalido');
  const ex = await dbW.query(
    `SELECT 1 FROM solicitudes_amistad WHERE estado IN ('pendiente','aceptada')
     AND ((de_usuario=$1 AND para_usuario=$2) OR (de_usuario=$2 AND para_usuario=$1))`, [a, b]);
  if (ex.rowCount) return bad(res, 'Ya existe una solicitud o amistad', 409);
  await dbW.query(
    `INSERT INTO solicitudes_amistad(de_usuario,para_usuario) VALUES($1,$2)
     ON CONFLICT (de_usuario,para_usuario) DO UPDATE SET estado='pendiente', creado_en=NOW()`, [a, b]);
  res.status(201).json({ mensaje: 'Solicitud enviada' });
}));

app.get('/api/amigos/solicitudes', auth, wrap(async (req, res) => {
  const r = await dbW.query(
    `SELECT s.id, u.id AS usuario_id, u.nombre_completo, u.foto_perfil_url, s.creado_en
     FROM solicitudes_amistad s JOIN usuarios u ON u.id=s.de_usuario
     WHERE s.para_usuario=$1 AND s.estado='pendiente' ORDER BY s.creado_en DESC`, [req.user.id]);
  res.json(r.rows);
}));

app.post('/api/amigos/solicitudes/:id/responder', auth, wrap(async (req, res) => {
  const { accion } = req.body;
  if (!['aceptar', 'rechazar'].includes(accion)) return bad(res, 'accion invalida');
  const r = await dbW.query(
    `UPDATE solicitudes_amistad SET estado=$1 WHERE id=$2 AND para_usuario=$3 AND estado='pendiente' RETURNING id`,
    [accion === 'aceptar' ? 'aceptada' : 'rechazada', req.params.id, req.user.id]);
  if (!r.rowCount) return bad(res, 'Solicitud no encontrada', 404);
  res.json({ mensaje: accion === 'aceptar' ? 'Ahora son amigos' : 'Solicitud rechazada' });
}));

// ---------- Publicaciones ----------
const VISIBLE = `(p.usuario_id=$1 OR p.usuario_id IN (SELECT amigo_id FROM amigos WHERE usuario_id=$1))`;

app.post('/api/publicaciones', auth, wrap(async (req, res) => {
  const { imagenUrl, descripcion, etiquetas = [] } = req.body;
  if (!okImgUrl(imagenUrl, 'Fotos_Publicadas')) return bad(res, 'Imagen invalida (subela por /upload)');
  const c = await dbW.connect();
  try {
    await c.query('BEGIN');
    const p = await c.query('INSERT INTO publicaciones(usuario_id,imagen_url,descripcion) VALUES($1,$2,$3) RETURNING id',
      [req.user.id, imagenUrl, descripcion || null]);
    for (const e of etiquetas.slice(0, 15)) {
      await c.query(
        'INSERT INTO etiquetas_publicacion(publicacion_id,etiqueta,confianza) VALUES($1,$2,$3) ON CONFLICT DO NOTHING',
        [p.rows[0].id, String(e.name).slice(0, 100), Number(e.confidence) || null]);
    }
    await c.query('COMMIT');
    res.status(201).json({ id: p.rows[0].id });
  } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
}));

// ?etiqueta=Perro (filtro exacto) | ?buscar=per (buscador) | ?fresh=1 (leer de la primaria)
app.get('/api/publicaciones', auth, wrap(async (req, res) => {
  const db = req.query.fresh ? dbW : dbR;
  const { etiqueta = null, buscar = null } = req.query;
  const posts = await db.query(
    `SELECT p.id, p.imagen_url, p.descripcion, p.creado_en, u.id AS usuario_id, u.nombre_completo, u.foto_perfil_url,
       COALESCE((SELECT json_agg(json_build_object('name', e.etiqueta, 'confidence', e.confianza))
                 FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id), '[]') AS etiquetas,
       (SELECT COUNT(*) FROM likes l WHERE l.publicacion_id=p.id)::int AS likes,
       EXISTS (SELECT 1 FROM likes l WHERE l.publicacion_id=p.id AND l.usuario_id=$1) AS me_gusta
     FROM publicaciones p JOIN usuarios u ON u.id=p.usuario_id
     WHERE ${VISIBLE}
       AND ($2::text IS NULL OR EXISTS (SELECT 1 FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id AND LOWER(e.etiqueta)=LOWER($2)))
       AND ($3::text IS NULL OR EXISTS (SELECT 1 FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id AND LOWER(e.etiqueta) LIKE '%'||LOWER($3)||'%'))
     ORDER BY p.creado_en DESC LIMIT 100`, [req.user.id, etiqueta, buscar]);
  const ids = posts.rows.map((p) => p.id);
  const com = ids.length ? await db.query(
    `SELECT c.id, c.publicacion_id, c.texto, c.creado_en, u.nombre_completo
     FROM comentarios c JOIN usuarios u ON u.id=c.usuario_id
     WHERE c.publicacion_id = ANY($1) ORDER BY c.creado_en`, [ids]) : { rows: [] };
  const by = {};
  com.rows.forEach((c) => { (by[c.publicacion_id] = by[c.publicacion_id] || []).push(c); });
  res.json(posts.rows.map((p) => ({ ...p, comentarios: by[p.id] || [] })));
}));

app.get('/api/etiquetas', auth, wrap(async (req, res) => {
  const r = await dbR.query(
    `SELECT DISTINCT e.etiqueta FROM etiquetas_publicacion e JOIN publicaciones p ON p.id=e.publicacion_id
     WHERE ${VISIBLE} ORDER BY 1`, [req.user.id]);
  res.json(['Todos', ...r.rows.map((x) => x.etiqueta)]);
}));

app.post('/api/publicaciones/:id/comentarios', auth, wrap(async (req, res) => {
  const texto = (req.body.texto || '').trim();
  if (!texto) return bad(res, 'Comentario vacio');
  const v = await dbW.query(`SELECT 1 FROM publicaciones p WHERE p.id=$2 AND ${VISIBLE}`, [req.user.id, req.params.id]);
  if (!v.rowCount) return bad(res, 'Solo puedes comentar publicaciones tuyas o de tus amigos', 403);
  await dbW.query('INSERT INTO comentarios(publicacion_id,usuario_id,texto) VALUES($1,$2,$3)', [req.params.id, req.user.id, texto]);
  res.status(201).json({ mensaje: 'Comentario agregado' });
}));

// Me gusta (alterna): solo en publicaciones propias o de amigos
app.post('/api/publicaciones/:id/like', auth, wrap(async (req, res) => {
  const v = await dbW.query(`SELECT 1 FROM publicaciones p WHERE p.id=$2 AND ${VISIBLE}`, [req.user.id, req.params.id]);
  if (!v.rowCount) return bad(res, 'Solo puedes dar me gusta a publicaciones tuyas o de tus amigos', 403);
  const del = await dbW.query('DELETE FROM likes WHERE publicacion_id=$1 AND usuario_id=$2', [req.params.id, req.user.id]);
  if (!del.rowCount) {
    await dbW.query('INSERT INTO likes(publicacion_id,usuario_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [req.params.id, req.user.id]);
  }
  const c = await dbW.query('SELECT COUNT(*)::int AS n FROM likes WHERE publicacion_id=$1', [req.params.id]);
  res.json({ meGusta: !del.rowCount, likes: c.rows[0].n });
}));

// ---------- Translate + Polly ----------
const IDIOMAS = { es: { voz: 'Mia', cod: 'es-MX' }, en: { voz: 'Joanna', cod: 'en-US' }, fr: { voz: 'Lea', cod: 'fr-FR' }, pt: { voz: 'Camila', cod: 'pt-BR' } };

app.post('/api/traducir', auth, wrap(async (req, res) => {
  const { texto, destino, origen } = req.body;
  if (!texto || !IDIOMAS[destino]) return bad(res, 'Datos invalidos (destino: es, en, fr, pt)');
  // Si el cliente indica el idioma de origen se usa tal cual; 'auto' requiere Comprehend (suscripcion aparte)
  const src = IDIOMAS[origen] ? origen : 'auto';
  if (src === destino) return res.json({ texto, origen: src, destino });
  try {
    const r = await translate.send(new TranslateTextCommand({
      Text: texto.slice(0, 4000), SourceLanguageCode: src, TargetLanguageCode: destino,
    }));
    res.json({ texto: r.TranslatedText, origen: r.SourceLanguageCode, destino });
  } catch (e) {
    if (e.name === 'UnsupportedLanguagePairException') return res.json({ texto, origen: destino, destino });
    throw e;
  }
}));

// URL prefirmada directa a Polly SynthesizeSpeech (sin guardar mp3 en S3)
app.post('/api/escuchar', auth, wrap(async (req, res) => {
  const { texto, idioma = 'es' } = req.body;
  if (!texto || !IDIOMAS[idioma]) return bad(res, 'Datos invalidos');
  const url = await getSynthesizeSpeechUrl({
    client: polly,
    params: { OutputFormat: 'mp3', Text: texto.slice(0, 1000), VoiceId: IDIOMAS[idioma].voz, Engine: 'standard', LanguageCode: IDIOMAS[idioma].cod },
  }, { expiresIn: 300 });
  res.json({ url });
}));

// ---------- Chat (persistido en RDS; el cliente hace polling con ?desde=<ultimo id>) ----------
app.get('/api/chat/:amigoId', auth, wrap(async (req, res) => {
  const amigo = Number(req.params.amigoId);
  if (!(await areFriends(req.user.id, amigo))) return bad(res, 'No son amigos', 403);
  const r = await dbW.query(
    `SELECT id, de_usuario, para_usuario, texto, creado_en FROM mensajes
     WHERE id > $3 AND ((de_usuario=$1 AND para_usuario=$2) OR (de_usuario=$2 AND para_usuario=$1))
     ORDER BY id LIMIT 200`, [req.user.id, amigo, Number(req.query.desde) || 0]);
  res.json(r.rows);
}));

app.post('/api/chat/:amigoId', auth, wrap(async (req, res) => {
  const amigo = Number(req.params.amigoId);
  const texto = (req.body.texto || '').trim();
  if (!texto) return bad(res, 'Mensaje vacio');
  if (!(await areFriends(req.user.id, amigo))) return bad(res, 'No son amigos', 403);
  const r = await dbW.query('INSERT INTO mensajes(de_usuario,para_usuario,texto) VALUES($1,$2,$3) RETURNING id,creado_en',
    [req.user.id, amigo, texto.slice(0, 2000)]);
  res.status(201).json(r.rows[0]);
}));

// ---------- Bot Lex ----------
let botCfg;
async function bot() {
  if (!botCfg) {
    const get = async (n) => (await ssm.send(new GetParameterCommand({ Name: `${SSM_PREFIX}/${n}` }))).Parameter.Value;
    botCfg = { id: await get('bot_id'), alias: await get('bot_alias_id') };
  }
  return botCfg;
}

app.post('/api/bot', auth, wrap(async (req, res) => {
  const texto = (req.body.texto || '').trim();
  if (!texto) return bad(res, 'Mensaje vacio');
  const b = await bot();
  const r = await lex.send(new RecognizeTextCommand({
    botId: b.id, botAliasId: b.alias, localeId: 'es_419', sessionId: `u${req.user.id}`, text: texto,
  }));
  res.json({ respuesta: (r.messages || []).map((m) => m.content).join(' ') || 'No entendi, intenta de otra forma.' });
}));

// ---------- Errores ----------
app.use((req, res) => bad(res, 'Ruta no encontrada', 404));
app.use((err, req, res, next) => { // eslint-disable-line no-unused-vars
  console.error(err.name, err.message);
  const http = err.$metadata && err.$metadata.httpStatusCode;
  const code = http && http < 500 ? http : 500;
  res.status(code).json({ error: code < 500 ? err.message : 'Error interno del servidor' });
});

app.listen(PORT, '0.0.0.0', () => console.log(`Semi-Social Node escuchando en ${PORT}`));
