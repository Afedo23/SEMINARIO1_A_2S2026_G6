-- Migracion 001: me gusta. Seguro de correr varias veces.
-- Me gusta (estilo Instagram/Facebook): una fila por usuario y publicacion
CREATE TABLE IF NOT EXISTS likes (
    publicacion_id INT NOT NULL REFERENCES publicaciones(id) ON DELETE CASCADE,
    usuario_id     INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (publicacion_id, usuario_id)
);
CREATE INDEX IF NOT EXISTS idx_likes_pub ON likes (publicacion_id);
