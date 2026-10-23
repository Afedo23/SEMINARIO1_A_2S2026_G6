"""
Semi-Social | Grupo 6 | Backend Python / FastAPI (EC2 #2)
Mismos endpoints, mismo JWT_SECRET y mismas respuestas que backend-node, para que el ALB
pueda mandar cualquier peticion a cualquiera de las dos instancias.
Variables de entorno: /etc/semisocial.env (las crea el user-data de 06-compute.sh)
Escrituras -> RDS primaria (DB_WRITE_HOST) | lecturas pesadas -> replica (DB_READ_HOST)
"""
import base64
import hashlib
import os
import re
import socket
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, unquote, urlencode, urlparse

import boto3
import jwt
import psycopg2
import psycopg2.errors
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest
from botocore.exceptions import ClientError
from fastapi import Body, Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool

REGION = os.environ.get("AWS_REGION", "us-east-1")
DB_WRITE_HOST = os.environ["DB_WRITE_HOST"]
DB_READ_HOST = os.environ.get("DB_READ_HOST") or DB_WRITE_HOST
DB_NAME, DB_USER, DB_PASSWORD = os.environ["DB_NAME"], os.environ["DB_USER"], os.environ["DB_PASSWORD"]
JWT_SECRET = os.environ["JWT_SECRET"]
USER_POOL_ID, CLIENT_ID = os.environ["USER_POOL_ID"], os.environ["COGNITO_CLIENT_ID"]
IMG_BUCKET = os.environ["IMG_BUCKET"]
SSM_PREFIX = os.environ.get("SSM_PREFIX", "/semisocial/g6")

# ---------- Clientes ----------
session = boto3.Session(region_name=REGION)
cognito = session.client("cognito-idp")
rek = session.client("rekognition")
translate = session.client("translate")
lex = session.client("lexv2-runtime")
ssm = session.client("ssm")


def mk_pool(host):
    return ThreadedConnectionPool(
        1, 10, host=host, port=5432, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD,
        sslmode="require", cursor_factory=RealDictCursor,
    )


dbw, dbr = mk_pool(DB_WRITE_HOST), mk_pool(DB_READ_HOST)


@contextmanager
def tx(pool):
    c = pool.getconn()
    try:
        yield c
        c.commit()
    except Exception:
        c.rollback()
        raise
    finally:
        pool.putconn(c)


def q(pool, sql, params=None, one=False):
    """Ejecuta una consulta. one=True devuelve una fila o None. Sin RETURNING devuelve rowcount."""
    with tx(pool) as c, c.cursor() as cur:
        cur.execute(sql, params)
        if cur.description:
            rows = cur.fetchall()
            return (rows[0] if rows else None) if one else rows
        return cur.rowcount


# ---------- Utilidades ----------
def md5(s):  # MD5 exigido por la rubrica
    return hashlib.md5(s.encode()).hexdigest()


def key_from_url(url):
    return unquote(urlparse(url).path[1:])


def ok_img_url(url, folder):
    return isinstance(url, str) and f"{IMG_BUCKET}.s3." in url and f"/{folder}/" in url


def sign_token(u):
    exp = datetime.now(timezone.utc) + timedelta(hours=8)
    return jwt.encode({"id": u["id"], "username": u["username"], "exp": exp}, JWT_SECRET, algorithm="HS256")


def auth(request: Request):
    h = request.headers.get("authorization", "")
    if not h.startswith("Bearer "):
        raise HTTPException(401, "Token requerido")
    try:
        return jwt.decode(h[7:], JWT_SECRET, algorithms=["HS256"])
    except Exception:
        raise HTTPException(401, "Token invalido o expirado")


def are_friends(a, b):
    return q(dbw, "SELECT 1 FROM amigos WHERE usuario_id=%s AND amigo_id=%s", (a, b), one=True) is not None


app = FastAPI(title="Semi-Social Python")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
                   expose_headers=["X-Servidor"])


@app.middleware("http")
async def servidor_header(request: Request, call_next):
    resp = await call_next(request)
    resp.headers["X-Servidor"] = f"python-{socket.gethostname()}"
    return resp


@app.exception_handler(HTTPException)
async def http_exc(request, exc):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


@app.exception_handler(RequestValidationError)
async def val_exc(request, exc):
    return JSONResponse({"error": "Datos invalidos"}, status_code=400)


@app.exception_handler(ClientError)
async def aws_exc(request, exc):
    http = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 500)
    code = http if http < 500 else 500
    msg = exc.response.get("Error", {}).get("Message", "Error") if code < 500 else "Error interno del servidor"
    return JSONResponse({"error": msg}, status_code=code)


@app.exception_handler(Exception)
async def any_exc(request, exc):
    print("ERROR", type(exc).__name__, exc, flush=True)
    return JSONResponse({"error": "Error interno del servidor"}, status_code=500)


# ---------- Salud / balanceador ----------
@app.get("/health")
def health():
    return JSONResponse("ok")  # el ALB usa esta ruta


@app.get("/api/info")
def info():
    return {"servidor": "python", "host": socket.gethostname()}


# ---------- Auth ----------
@app.post("/api/auth/register", status_code=201)
def register(b: dict = Body(...)):
    username, nombre, correo, dpi = b.get("username"), b.get("nombre"), b.get("correo"), b.get("dpi")
    password, repetir, foto = b.get("password"), b.get("repetir"), b.get("fotoUrl")
    if not all([username, nombre, correo, dpi, password, foto]):
        raise HTTPException(400, "Faltan datos obligatorios")
    if password != repetir:
        raise HTTPException(400, "Las contrasenas no coinciden")
    if not re.fullmatch(r"\d{13}", str(dpi)):
        raise HTTPException(400, "El DPI debe tener 13 digitos")
    if not ok_img_url(foto, "Fotos_Perfil"):
        raise HTTPException(400, "Foto de perfil invalida (subela por /upload)")
    if q(dbw, "SELECT 1 FROM usuarios WHERE username=%s OR correo=%s OR dpi=%s", (username, correo, dpi), one=True):
        raise HTTPException(409, "Usuario, correo o DPI ya registrado")

    out = cognito.sign_up(
        ClientId=CLIENT_ID, Username=username, Password=password,
        UserAttributes=[{"Name": "email", "Value": correo}, {"Name": "name", "Value": nombre},
                        {"Name": "custom:dpi", "Value": dpi}],
    )
    q(dbw, """INSERT INTO usuarios(cognito_sub,username,nombre_completo,correo,dpi,password_md5,foto_perfil_url)
              VALUES(%s,%s,%s,%s,%s,%s,%s)""",
      (out["UserSub"], username, nombre, correo, dpi, md5(password), foto))
    return {"mensaje": "Registrado. Revisa tu correo e ingresa el codigo de verificacion."}


@app.post("/api/auth/confirm")
def confirm(b: dict = Body(...)):
    if not b.get("username") or not b.get("code"):
        raise HTTPException(400, "Faltan datos")
    cognito.confirm_sign_up(ClientId=CLIENT_ID, Username=b["username"], ConfirmationCode=b["code"])
    return {"mensaje": "Correo verificado. Ya puedes iniciar sesion."}


@app.post("/api/auth/login")
def login(b: dict = Body(...)):
    username, password = b.get("username"), b.get("password")
    if not username or not password:
        raise HTTPException(400, "Faltan credenciales")
    cognito.initiate_auth(AuthFlow="USER_PASSWORD_AUTH", ClientId=CLIENT_ID,
                          AuthParameters={"USERNAME": username, "PASSWORD": password})
    u = q(dbw, "SELECT id,username,nombre_completo,foto_perfil_url FROM usuarios WHERE username=%s", (username,), one=True)
    if not u:
        raise HTTPException(404, "Usuario no encontrado")
    return {"token": sign_token(u), "usuario": u}


@app.post("/api/auth/login-facial")
def login_facial(b: dict = Body(...)):
    username, img = b.get("username"), b.get("imageBase64")
    if not username or not img:
        raise HTTPException(400, "Faltan datos")
    u = q(dbw, "SELECT id,username,nombre_completo,foto_perfil_url FROM usuarios WHERE username=%s", (username,), one=True)
    if not u:
        raise HTTPException(404, "Usuario no encontrado")
    cu = cognito.admin_get_user(UserPoolId=USER_POOL_ID, Username=username)
    if cu["UserStatus"] != "CONFIRMED":
        raise HTTPException(403, "Cuenta sin verificar")
    raw = base64.b64decode(re.sub(r"^data:image/\w+;base64,", "", img))
    cmp = rek.compare_faces(
        SourceImage={"Bytes": raw},
        TargetImage={"S3Object": {"Bucket": IMG_BUCKET, "Name": key_from_url(u["foto_perfil_url"])}},
        SimilarityThreshold=90,
    )
    if not cmp.get("FaceMatches"):
        raise HTTPException(401, "El rostro no coincide")
    return {"token": sign_token(u), "usuario": u, "similitud": cmp["FaceMatches"][0]["Similarity"]}


# ---------- Perfil ----------
@app.get("/api/me")
def me(user=Depends(auth)):
    return q(dbw, "SELECT id,username,nombre_completo,correo,dpi,foto_perfil_url FROM usuarios WHERE id=%s",
             (user["id"],), one=True)


@app.put("/api/me")
def update_me(b: dict = Body(...), user=Depends(auth)):
    cur = q(dbw, "SELECT * FROM usuarios WHERE id=%s", (user["id"],), one=True)
    if not b.get("password") or md5(b["password"]) != cur["password_md5"]:
        raise HTTPException(401, "Contrasena incorrecta")
    n = b.get("nombre") or cur["nombre_completo"]
    d = b.get("dpi") or cur["dpi"]
    f = b.get("fotoUrl") or cur["foto_perfil_url"]
    if not re.fullmatch(r"\d{13}", str(d)):
        raise HTTPException(400, "El DPI debe tener 13 digitos")
    if b.get("fotoUrl") and not ok_img_url(b["fotoUrl"], "Fotos_Perfil"):
        raise HTTPException(400, "Foto de perfil invalida")
    try:
        q(dbw, "UPDATE usuarios SET nombre_completo=%s, dpi=%s, foto_perfil_url=%s WHERE id=%s", (n, d, f, cur["id"]))
    except psycopg2.errors.UniqueViolation:
        raise HTTPException(409, "DPI ya registrado")
    cognito.admin_update_user_attributes(
        UserPoolId=USER_POOL_ID, Username=cur["username"],
        UserAttributes=[{"Name": "name", "Value": n}, {"Name": "custom:dpi", "Value": d}],
    )
    return {"mensaje": "Perfil actualizado"}


# ---------- Usuarios y amistades ----------
@app.get("/api/usuarios/no-amigos")
def no_amigos(user=Depends(auth)):
    return q(dbw, """
        SELECT u.id, u.username, u.nombre_completo, u.foto_perfil_url,
          CASE WHEN EXISTS (SELECT 1 FROM solicitudes_amistad s WHERE s.de_usuario=%(u)s AND s.para_usuario=u.id AND s.estado='pendiente') THEN 'enviada'
               WHEN EXISTS (SELECT 1 FROM solicitudes_amistad s WHERE s.de_usuario=u.id AND s.para_usuario=%(u)s AND s.estado='pendiente') THEN 'recibida'
          END AS solicitud
        FROM usuarios u
        WHERE u.id<>%(u)s AND NOT EXISTS (SELECT 1 FROM amigos a WHERE a.usuario_id=%(u)s AND a.amigo_id=u.id)
        ORDER BY u.nombre_completo""", {"u": user["id"]})


@app.get("/api/amigos")
def amigos(user=Depends(auth)):
    return q(dbw, """SELECT u.id, u.username, u.nombre_completo, u.foto_perfil_url FROM amigos a
                     JOIN usuarios u ON u.id=a.amigo_id WHERE a.usuario_id=%s ORDER BY u.nombre_completo""", (user["id"],))


@app.post("/api/amigos/solicitudes", status_code=201)
def enviar_solicitud(b: dict = Body(...), user=Depends(auth)):
    a = user["id"]
    try:
        dest = int(b.get("paraId"))
    except (TypeError, ValueError):
        raise HTTPException(400, "Destino invalido")
    if not dest or a == dest:
        raise HTTPException(400, "Destino invalido")
    if q(dbw, """SELECT 1 FROM solicitudes_amistad WHERE estado IN ('pendiente','aceptada')
                 AND ((de_usuario=%(a)s AND para_usuario=%(b)s) OR (de_usuario=%(b)s AND para_usuario=%(a)s))""",
         {"a": a, "b": dest}, one=True):
        raise HTTPException(409, "Ya existe una solicitud o amistad")
    q(dbw, """INSERT INTO solicitudes_amistad(de_usuario,para_usuario) VALUES(%s,%s)
              ON CONFLICT (de_usuario,para_usuario) DO UPDATE SET estado='pendiente', creado_en=NOW()""", (a, dest))
    return {"mensaje": "Solicitud enviada"}


@app.get("/api/amigos/solicitudes")
def solicitudes(user=Depends(auth)):
    return q(dbw, """SELECT s.id, u.id AS usuario_id, u.nombre_completo, u.foto_perfil_url, s.creado_en
                     FROM solicitudes_amistad s JOIN usuarios u ON u.id=s.de_usuario
                     WHERE s.para_usuario=%s AND s.estado='pendiente' ORDER BY s.creado_en DESC""", (user["id"],))


@app.post("/api/amigos/solicitudes/{sid}/responder")
def responder(sid: int, b: dict = Body(...), user=Depends(auth)):
    accion = b.get("accion")
    if accion not in ("aceptar", "rechazar"):
        raise HTTPException(400, "accion invalida")
    r = q(dbw, """UPDATE solicitudes_amistad SET estado=%s WHERE id=%s AND para_usuario=%s AND estado='pendiente'
                  RETURNING id""", ("aceptada" if accion == "aceptar" else "rechazada", sid, user["id"]))
    if not r:
        raise HTTPException(404, "Solicitud no encontrada")
    return {"mensaje": "Ahora son amigos" if accion == "aceptar" else "Solicitud rechazada"}


# ---------- Publicaciones ----------
VISIBLE = "(p.usuario_id=%(u)s OR p.usuario_id IN (SELECT amigo_id FROM amigos WHERE usuario_id=%(u)s))"


@app.post("/api/publicaciones", status_code=201)
def crear_publicacion(b: dict = Body(...), user=Depends(auth)):
    if not ok_img_url(b.get("imagenUrl"), "Fotos_Publicadas"):
        raise HTTPException(400, "Imagen invalida (subela por /upload)")
    with tx(dbw) as c, c.cursor() as cur:
        cur.execute("INSERT INTO publicaciones(usuario_id,imagen_url,descripcion) VALUES(%s,%s,%s) RETURNING id",
                    (user["id"], b["imagenUrl"], b.get("descripcion") or None))
        pid = cur.fetchone()["id"]
        for e in (b.get("etiquetas") or [])[:15]:
            cur.execute("""INSERT INTO etiquetas_publicacion(publicacion_id,etiqueta,confianza) VALUES(%s,%s,%s)
                           ON CONFLICT DO NOTHING""", (pid, str(e.get("name"))[:100], e.get("confidence")))
    return {"id": pid}


@app.get("/api/publicaciones")
def listar_publicaciones(etiqueta: str = None, buscar: str = None, fresh: str = None, user=Depends(auth)):
    db = dbw if fresh else dbr
    posts = q(db, f"""
        SELECT p.id, p.imagen_url, p.descripcion, p.creado_en, u.id AS usuario_id, u.nombre_completo, u.foto_perfil_url,
          COALESCE((SELECT json_agg(json_build_object('name', e.etiqueta, 'confidence', e.confianza))
                    FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id), '[]') AS etiquetas,
          (SELECT COUNT(*) FROM likes l WHERE l.publicacion_id=p.id)::int AS likes,
          EXISTS (SELECT 1 FROM likes l WHERE l.publicacion_id=p.id AND l.usuario_id=%(u)s) AS me_gusta
        FROM publicaciones p JOIN usuarios u ON u.id=p.usuario_id
        WHERE {VISIBLE}
          AND (%(et)s::text IS NULL OR EXISTS (SELECT 1 FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id AND LOWER(e.etiqueta)=LOWER(%(et)s)))
          AND (%(bu)s::text IS NULL OR EXISTS (SELECT 1 FROM etiquetas_publicacion e WHERE e.publicacion_id=p.id AND LOWER(e.etiqueta) LIKE '%%' || LOWER(%(bu)s) || '%%'))
        ORDER BY p.creado_en DESC LIMIT 100""", {"u": user["id"], "et": etiqueta, "bu": buscar})
    ids = [p["id"] for p in posts]
    coms = q(db, """SELECT c.id, c.publicacion_id, c.texto, c.creado_en, u.nombre_completo
                    FROM comentarios c JOIN usuarios u ON u.id=c.usuario_id
                    WHERE c.publicacion_id = ANY(%s) ORDER BY c.creado_en""", (ids,)) if ids else []
    by = {}
    for c in coms:
        by.setdefault(c["publicacion_id"], []).append(c)
    return [{**p, "comentarios": by.get(p["id"], [])} for p in posts]


@app.get("/api/etiquetas")
def etiquetas(user=Depends(auth)):
    rows = q(dbr, f"""SELECT DISTINCT e.etiqueta FROM etiquetas_publicacion e JOIN publicaciones p ON p.id=e.publicacion_id
                      WHERE {VISIBLE} ORDER BY 1""", {"u": user["id"]})
    return ["Todos"] + [r["etiqueta"] for r in rows]


@app.post("/api/publicaciones/{pid}/comentarios", status_code=201)
def comentar(pid: int, b: dict = Body(...), user=Depends(auth)):
    texto = (b.get("texto") or "").strip()
    if not texto:
        raise HTTPException(400, "Comentario vacio")
    if not q(dbw, f"SELECT 1 FROM publicaciones p WHERE p.id=%(p)s AND {VISIBLE}", {"p": pid, "u": user["id"]}, one=True):
        raise HTTPException(403, "Solo puedes comentar publicaciones tuyas o de tus amigos")
    q(dbw, "INSERT INTO comentarios(publicacion_id,usuario_id,texto) VALUES(%s,%s,%s)", (pid, user["id"], texto))
    return {"mensaje": "Comentario agregado"}


@app.post("/api/publicaciones/{pid}/like")
def like(pid: int, user=Depends(auth)):
    """Me gusta (alterna): solo en publicaciones propias o de amigos."""
    if not q(dbw, f"SELECT 1 FROM publicaciones p WHERE p.id=%(p)s AND {VISIBLE}", {"p": pid, "u": user["id"]}, one=True):
        raise HTTPException(403, "Solo puedes dar me gusta a publicaciones tuyas o de tus amigos")
    borrados = q(dbw, "DELETE FROM likes WHERE publicacion_id=%s AND usuario_id=%s", (pid, user["id"]))
    if not borrados:
        q(dbw, "INSERT INTO likes(publicacion_id,usuario_id) VALUES(%s,%s) ON CONFLICT DO NOTHING", (pid, user["id"]))
    n = q(dbw, "SELECT COUNT(*)::int AS n FROM likes WHERE publicacion_id=%s", (pid,), one=True)["n"]
    return {"meGusta": not borrados, "likes": n}


# ---------- Translate + Polly ----------
IDIOMAS = {"es": ("Mia", "es-MX"), "en": ("Joanna", "en-US"), "fr": ("Lea", "fr-FR"), "pt": ("Camila", "pt-BR")}


@app.post("/api/traducir")
def traducir(b: dict = Body(...), user=Depends(auth)):
    texto, destino, origen = b.get("texto"), b.get("destino"), b.get("origen")
    if not texto or destino not in IDIOMAS:
        raise HTTPException(400, "Datos invalidos (destino: es, en, fr, pt)")
    # Si el cliente indica el idioma de origen se usa tal cual; "auto" requiere Comprehend (suscripcion aparte)
    src = origen if origen in IDIOMAS else "auto"
    if src == destino:
        return {"texto": texto, "origen": src, "destino": destino}
    try:
        r = translate.translate_text(Text=texto[:4000], SourceLanguageCode=src, TargetLanguageCode=destino)
    except ClientError as e:
        if e.response["Error"]["Code"] == "UnsupportedLanguagePairException":
            return {"texto": texto, "origen": destino, "destino": destino}
        raise
    return {"texto": r["TranslatedText"], "origen": r["SourceLanguageCode"], "destino": destino}


def polly_url(texto, voz, codigo):
    """URL prefirmada (GET) directa a Polly SynthesizeSpeech: no se guarda ningun mp3 en S3."""
    params = {"OutputFormat": "mp3", "Text": texto, "VoiceId": voz, "Engine": "standard", "LanguageCode": codigo}
    base = f"https://polly.{REGION}.amazonaws.com/v1/speech?{urlencode(params, quote_via=quote)}"
    req = AWSRequest(method="GET", url=base)
    SigV4QueryAuth(session.get_credentials().get_frozen_credentials(), "polly", REGION, expires=300).add_auth(req)
    return req.url


@app.post("/api/escuchar")
def escuchar(b: dict = Body(...), user=Depends(auth)):
    texto, idioma = b.get("texto"), b.get("idioma", "es")
    if not texto or idioma not in IDIOMAS:
        raise HTTPException(400, "Datos invalidos")
    voz, codigo = IDIOMAS[idioma]
    return {"url": polly_url(texto[:1000], voz, codigo)}


# ---------- Chat (persistido en RDS; el cliente hace polling con ?desde=<ultimo id>) ----------
@app.get("/api/chat/{amigo}")
def chat_get(amigo: int, desde: int = 0, user=Depends(auth)):
    if not are_friends(user["id"], amigo):
        raise HTTPException(403, "No son amigos")
    return q(dbw, """SELECT id, de_usuario, para_usuario, texto, creado_en FROM mensajes
                     WHERE id > %(d)s AND ((de_usuario=%(a)s AND para_usuario=%(b)s) OR (de_usuario=%(b)s AND para_usuario=%(a)s))
                     ORDER BY id LIMIT 200""", {"a": user["id"], "b": amigo, "d": desde})


@app.post("/api/chat/{amigo}", status_code=201)
def chat_post(amigo: int, b: dict = Body(...), user=Depends(auth)):
    texto = (b.get("texto") or "").strip()
    if not texto:
        raise HTTPException(400, "Mensaje vacio")
    if not are_friends(user["id"], amigo):
        raise HTTPException(403, "No son amigos")
    return q(dbw, "INSERT INTO mensajes(de_usuario,para_usuario,texto) VALUES(%s,%s,%s) RETURNING id,creado_en",
             (user["id"], amigo, texto[:2000]), one=True)


# ---------- Bot Lex ----------
_bot = {}


def bot_cfg():
    if not _bot:
        get = lambda n: ssm.get_parameter(Name=f"{SSM_PREFIX}/{n}")["Parameter"]["Value"]
        _bot.update(id=get("bot_id"), alias=get("bot_alias_id"))
    return _bot


@app.post("/api/bot")
def bot(b: dict = Body(...), user=Depends(auth)):
    texto = (b.get("texto") or "").strip()
    if not texto:
        raise HTTPException(400, "Mensaje vacio")
    cfg = bot_cfg()
    r = lex.recognize_text(botId=cfg["id"], botAliasId=cfg["alias"], localeId="es_419",
                           sessionId=f"u{user['id']}", text=texto)
    return {"respuesta": " ".join(m["content"] for m in r.get("messages", [])) or "No entendi, intenta de otra forma."}
