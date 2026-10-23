-- Semi-Social | Grupo 6 | PostgreSQL (RDS)
-- Ejecutar SOLO contra la instancia primaria; la réplica se sincroniza sola.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE usuarios (
    id             SERIAL PRIMARY KEY,
    cognito_sub    VARCHAR(64) UNIQUE NOT NULL,      -- relación con el User Pool
    username       VARCHAR(50) UNIQUE NOT NULL,
    nombre_completo VARCHAR(120) NOT NULL,
    correo         VARCHAR(120) UNIQUE NOT NULL,
    dpi            VARCHAR(13) UNIQUE NOT NULL,
    password_md5   CHAR(32) NOT NULL,                -- MD5 exigido por la rúbrica (1.5)
    foto_perfil_url TEXT NOT NULL,                   -- s3://semi1proyecto-g6/Fotos_Perfil/...
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE solicitudes_amistad (
    id            SERIAL PRIMARY KEY,
    de_usuario    INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    para_usuario  INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    estado        VARCHAR(10) NOT NULL DEFAULT 'pendiente'
                  CHECK (estado IN ('pendiente','aceptada','rechazada')),
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (de_usuario <> para_usuario),
    UNIQUE (de_usuario, para_usuario)
);

CREATE TABLE publicaciones (
    id          SERIAL PRIMARY KEY,
    usuario_id  INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    imagen_url  TEXT NOT NULL,                       -- Fotos_Publicadas/...
    descripcion TEXT,
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_pub_fecha ON publicaciones (creado_en DESC);

CREATE TABLE etiquetas_publicacion (                 -- labels de Rekognition
    id             SERIAL PRIMARY KEY,
    publicacion_id INT NOT NULL REFERENCES publicaciones(id) ON DELETE CASCADE,
    etiqueta       VARCHAR(100) NOT NULL,
    confianza      NUMERIC(5,2),
    UNIQUE (publicacion_id, etiqueta)
);
CREATE INDEX idx_etiqueta ON etiquetas_publicacion (LOWER(etiqueta));

CREATE TABLE comentarios (
    id             SERIAL PRIMARY KEY,
    publicacion_id INT NOT NULL REFERENCES publicaciones(id) ON DELETE CASCADE,
    usuario_id     INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    texto          TEXT NOT NULL,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE mensajes (
    id           BIGSERIAL PRIMARY KEY,
    de_usuario   INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    para_usuario INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    texto        TEXT NOT NULL,
    creado_en    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_chat ON mensajes (de_usuario, para_usuario, creado_en);

-- Amigos = solicitudes aceptadas (en cualquier sentido)
CREATE VIEW amigos AS
SELECT de_usuario AS usuario_id, para_usuario AS amigo_id FROM solicitudes_amistad WHERE estado='aceptada'
UNION
SELECT para_usuario, de_usuario FROM solicitudes_amistad WHERE estado='aceptada';

-- Me gusta (estilo Instagram/Facebook): una fila por usuario y publicacion
CREATE TABLE IF NOT EXISTS likes (
    publicacion_id INT NOT NULL REFERENCES publicaciones(id) ON DELETE CASCADE,
    usuario_id     INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (publicacion_id, usuario_id)
);
CREATE INDEX IF NOT EXISTS idx_likes_pub ON likes (publicacion_id);
